using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text;

namespace Kinen.Windows.Core;

public sealed record LibraryManifest(int FormatVersion, Guid LibraryId, string Title);
public sealed record Subject(Guid Id, string Name);
public sealed record Stop(Guid Id, string Date, string? Time, string Title, string Location, string Note);
public sealed record Note(Guid Id, string Kind, string Title, string StartDate, string? EndDate, Guid? ParentId,
                          Guid[] MediaIds, Stop[]? Itinerary)
{
    public string Body { get; init; } = "";
    public string Caption => $"{Display.Kind(Kind)} · {StartDate}";
}
public sealed record Asset(string Sha256, long ByteLength, string MimeType, string OriginalFilename, string? StoredFilename)
{
    internal string RelativePath()
    {
        if (Sha256.Length != 64 || Sha256.Any(c => !Uri.IsHexDigit(c) || char.IsUpper(c)) || ByteLength <= 0)
            throw new InvalidDataException("媒体文件摘要或大小无效。");
        if (StoredFilename is null)
            return Path.Combine("assets", "sha256", Sha256[..2], Sha256);
        var basename = StoredFilename.Split('.', 2);
        var parts = basename[0].Split('_');
        if (parts.Length != 3 || !Guid.TryParseExact(parts[0], "D", out _) ||
            !DateOnly.TryParseExact(parts[1], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _) ||
            !Guid.TryParseExact(parts[2], "D", out _) ||
            (basename.Length == 2 && (basename[1].Length is < 1 or > 12 || basename[1].Any(c => !char.IsAsciiLetterOrDigit(c)))))
            throw new InvalidDataException("媒体文件路径无效。");
        return Path.Combine("assets", "cheki", StoredFilename);
    }
}
public sealed record Medium(Guid Id, string Kind, string? CaptureDate, Guid[] MemberIds, Guid? GroupId,
                            string Note, int? QuarterTurns, Asset Original, Asset? Corrected)
{
    public IEnumerable<Asset> Assets => Corrected is null ? [Original] : [Original, Corrected];
}
public sealed record LibrarySnapshot(string Root, LibraryManifest Manifest, IReadOnlyList<Note> Notes,
                                     IReadOnlyList<Medium> Media, IReadOnlyList<Subject> Members,
                                     IReadOnlyList<Subject> Groups)
{
    public IReadOnlyList<Note> Drafts { get; init; } = [];
    public IEnumerable<string> Names(Medium item) =>
        Members.Where(s => item.MemberIds.Contains(s.Id)).Select(s => s.Name)
            .Concat(Groups.Where(s => s.Id == item.GroupId).Select(s => s.Name));

    public string? Attachment(Medium item)
    {
        foreach (var asset in item.Assets.Reverse())
        {
            var path = LibraryStore.FindAsset(Root, asset);
            if (path is not null) return path;
        }
        return null;
    }

    public int MissingAssets => Media.SelectMany(item => item.Assets)
        .Count(asset => LibraryStore.FindAsset(Root, asset) is null);

    public IEnumerable<(string Month, int Count)> Months(IEnumerable<Medium> media) =>
        media.Select(item => item.CaptureDate)
            .Where(day => DateOnly.TryParseExact(day, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                                DateTimeStyles.None, out _))
            .GroupBy(day => day![..7])
            .OrderByDescending(group => group.Key)
            .Select(group => (group.Key, group.Count()));
}

public static class Display
{
    public static string Kind(string kind) => kind switch
    {
        "cheki" => "拍立得", "portrait" => "合影", "photo" => "照片", "video" => "视频",
        "trip" => "旅行", "live" => "Live", "memory" => "合影回忆", _ => "笔记"
    };
}

public static partial class LibraryStore
{
    private const int MetadataLimit = 16 * 1024 * 1024;
    private const int RecordLimit = 100_000;
    private static readonly object NoteGate = new();
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public static LibrarySnapshot CreateDefault(string root)
    {
        Directory.CreateDirectory(root);
        var manifest = Path.Combine(root, "library.json");
        if (!File.Exists(manifest))
        {
            var temporary = Path.Combine(root, $".manifest-{Guid.NewGuid():N}");
            try
            {
                File.WriteAllText(temporary, JsonSerializer.Serialize(new LibraryManifest(1, Guid.NewGuid(), "記念撮影"), JsonOptions));
                File.Move(temporary, manifest, overwrite: false);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        return Load(root);
    }

    public static LibrarySnapshot Load(string root)
    {
        lock (NoteGate) return LoadNotesAndLibrary(root);
    }

    private static LibrarySnapshot LoadNotesAndLibrary(string root)
    {
        RecoverNoteWrites(root);
        var manifest = Read<LibraryManifest>(SafeFile(Path.Combine(root, "library.json"), MetadataLimit));
        if (manifest.FormatVersion != 1 || manifest.LibraryId == Guid.Empty)
            throw new InvalidDataException("此资料库格式暂不受支持。");
        var members = ReadRecords<Subject>(root, "members", item => item.Id);
        var groups = ReadRecords<Subject>(root, "groups", item => item.Id);
        var media = ReadRecords<Medium>(root, "media", item => item.Id);
        foreach (var asset in media.SelectMany(item => item.Assets)) _ = asset.RelativePath();
        var notes = Entries(root).Select(path =>
        {
            var note = Read<Note>(SafeFile(Path.Combine(path, "entry.json"), MetadataLimit));
            if (!Guid.TryParseExact(Path.GetFileName(path), "D", out var id) || id != note.Id)
                throw new InvalidDataException("笔记标识与目录名不一致。");
            return note with { Body = File.ReadAllText(SafeFile(Path.Combine(path, "body.md"), MetadataLimit)) };
        }).OrderByDescending(note => note.StartDate, StringComparer.Ordinal).ToArray();
        return new LibrarySnapshot(root, manifest, notes, media.OrderByDescending(item => item.CaptureDate).ToArray(),
            members.OrderBy(subject => subject.Name).ToArray(), groups.OrderBy(subject => subject.Name).ToArray())
        {
            Drafts = ReadRecords<Note>(root, ".drafts", item => item.Id)
                .OrderByDescending(note => File.GetLastWriteTimeUtc(DraftPath(root, note.Id))).ToArray()
        };
    }

    public static void SaveDraft(string root, Note note)
    {
        lock (NoteGate)
        {
            if (note.Id == Guid.Empty) throw new InvalidDataException("无效笔记记录。");
            var destination = DraftPath(root, note.Id);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var temporary = destination + $".{Guid.NewGuid():N}.tmp";
            try
            {
                var bytes = JsonSerializer.SerializeToUtf8Bytes(note, JsonOptions);
                if (bytes.Length > MetadataLimit) throw new InvalidDataException("草稿内容过大。");
                File.WriteAllBytes(temporary, bytes);
                File.Move(temporary, destination, overwrite: true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }

    public static void DiscardDraft(string root, Guid id)
    {
        lock (NoteGate) File.Delete(DraftPath(root, id));
    }

    public static LibrarySnapshot PublishNote(string root, Note note)
    {
        lock (NoteGate)
        {
            var snapshot = LoadNotesAndLibrary(root);
            ValidateNote(note, snapshot);
            var target = Path.Combine(root, "entries", note.Id.ToString());
            var journal = Path.Combine(root, ".note-writes", note.Id.ToString());
            var incoming = Path.Combine(journal, "incoming");
            var previous = Path.Combine(journal, "previous");
            Directory.CreateDirectory(incoming);
            var metadata = new JsonObject();
            var original = Path.Combine(target, "entry.json");
            if (File.Exists(original))
                metadata = JsonNode.Parse(File.ReadAllText(SafeFile(original, MetadataLimit)))?.AsObject()
                    ?? throw new InvalidDataException("笔记元数据无效。");

            metadata["id"] = note.Id;
            metadata["kind"] = note.Kind;
            metadata["title"] = note.Title;
            metadata["startDate"] = note.StartDate;
            metadata["endDate"] = note.EndDate;
            metadata["parentId"] = JsonSerializer.SerializeToNode(note.ParentId, JsonOptions);
            metadata["mediaIds"] = JsonSerializer.SerializeToNode(note.MediaIds, JsonOptions);
            metadata["itinerary"] = JsonSerializer.SerializeToNode(note.Itinerary, JsonOptions);
            metadata["timeZone"] ??= LocalTimeZone();
            metadata["createdAt"] ??= Timestamp();
            metadata["updatedAt"] = Timestamp();

            File.WriteAllText(Path.Combine(incoming, "entry.json"), metadata.ToJsonString(JsonOptions) + "\n");
            File.WriteAllText(Path.Combine(incoming, "body.md"), note.Body);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (Directory.Exists(target)) Directory.Move(target, previous);
            Directory.Move(incoming, target);
            DiscardDraft(root, note.Id);
            Directory.Delete(journal, recursive: true);
            return LoadNotesAndLibrary(root);
        }
    }

    public static bool AllowsChild(string parent, string kind) =>
        (parent == "trip" && kind is "live" or "memory") || (parent == "live" && kind == "memory");

    private static string DraftPath(string root, Guid id) => Path.Combine(root, ".drafts", id + ".json");
    private static string LocalTimeZone()
    {
        var local = TimeZoneInfo.Local.Id;
        if (!OperatingSystem.IsWindows()) return local;
        return TimeZoneInfo.TryConvertWindowsIdToIanaId(local, out var iana) ? iana : "Etc/UTC";
    }

    private static string Timestamp() => DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private static void ValidateNote(Note note, LibrarySnapshot snapshot)
    {
        static bool Day(string? value) => DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                                               DateTimeStyles.None, out _);
        if (note.Id == Guid.Empty || string.IsNullOrWhiteSpace(note.Title) ||
            note.Kind is not ("trip" or "live" or "memory" or "journal") || !Day(note.StartDate) ||
            (note.EndDate is not null && (!Day(note.EndDate) || string.CompareOrdinal(note.EndDate, note.StartDate) < 0)) ||
            Encoding.UTF8.GetByteCount(note.Body) > MetadataLimit)
            throw new InvalidDataException("请检查笔记标题、日期和正文大小。");
        if (note.ParentId is Guid parent &&
            snapshot.Notes.All(item => item.Id != parent || item.Id == note.Id || !AllowsChild(item.Kind, note.Kind)) ||
            snapshot.Notes.Any(child => child.ParentId == note.Id && !AllowsChild(note.Kind, child.Kind)))
            throw new InvalidDataException("笔记类型或归属与现有关联不一致。");
        if (note.MediaIds.Except(snapshot.Media.Select(item => item.Id)).Any())
            throw new InvalidDataException("存在不可用的关联媒体。");
        if (note.Itinerary is { Length: > 0 } stops &&
            (note.Kind != "trip" || stops.Any(stop => string.IsNullOrWhiteSpace(stop.Title) || !Day(stop.Date))))
            throw new InvalidDataException("请检查旅行行程。");
    }

    private static void RecoverNoteWrites(string root)
    {
        var directory = Path.Combine(root, ".note-writes");
        if (!Directory.Exists(directory)) return;
        SafeDirectory(directory);
        foreach (var transaction in Directory.EnumerateDirectories(directory))
        {
            SafeDirectory(transaction);
            if (!Guid.TryParseExact(Path.GetFileName(transaction), "D", out var id))
                throw new InvalidDataException("笔记事务目录无效。");
            var target = Path.Combine(root, "entries", id.ToString());
            var previous = Path.Combine(transaction, "previous");
            if (!Directory.Exists(target) && Directory.Exists(previous))
            {
                SafeDirectory(previous);
                Directory.Move(previous, target);
            }
            Directory.Delete(transaction, recursive: true);
        }
    }

    public static async Task<LibrarySnapshot> RestoreAsync(string source, string destination,
                                                            CancellationToken cancellation = default,
                                                            bool includeAttachments = true)
    {
        SafeDirectory(source);
        if (File.Exists(destination) || Directory.Exists(destination))
            throw new IOException("目标位置已有资料库。");
        var parent = Path.GetDirectoryName(Path.GetFullPath(destination))!;
        Directory.CreateDirectory(parent);
        var staged = Path.Combine(parent, $".restore-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staged);
        try
        {
            File.Copy(SafeFile(Path.Combine(source, "library.json"), MetadataLimit), Path.Combine(staged, "library.json"));
            foreach (var directory in new[] { "members", "groups", "media" })
            {
                var target = Directory.CreateDirectory(Path.Combine(staged, directory));
                foreach (var path in RecordFiles(source, directory))
                {
                    cancellation.ThrowIfCancellationRequested();
                    File.Copy(SafeFile(path, MetadataLimit), Path.Combine(target.FullName, Path.GetFileName(path)));
                }
            }
            foreach (var path in Entries(source))
            {
                cancellation.ThrowIfCancellationRequested();
                var target = Directory.CreateDirectory(Path.Combine(staged, "entries", Path.GetFileName(path)));
                foreach (var name in new[] { "entry.json", "body.md" })
                    File.Copy(SafeFile(Path.Combine(path, name), MetadataLimit), Path.Combine(target.FullName, name));
            }

            var snapshot = Load(staged);
            var seen = new Dictionary<string, Asset>(StringComparer.OrdinalIgnoreCase);
            foreach (var asset in snapshot.Media.SelectMany(item => item.Assets))
            {
                cancellation.ThrowIfCancellationRequested();
                var relative = asset.RelativePath();
                if (seen.TryGetValue(relative, out var existing))
                {
                    if (existing.Sha256 != asset.Sha256 || existing.ByteLength != asset.ByteLength)
                        throw new InvalidDataException("共享媒体的摘要不一致。");
                    continue;
                }
                seen.Add(relative, asset);
                if (!includeAttachments) continue;
                var path = FindAsset(source, asset);
                if (path is null) continue;
                var target = Path.Combine(staged, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                await using var input = new FileStream(SafeFile(path, asset.ByteLength), FileMode.Open, FileAccess.Read, FileShare.Read);
                await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[128 * 1024];
                long size = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, cancellation)) > 0)
                {
                    size += read;
                    if (size > asset.ByteLength) throw new InvalidDataException("媒体大小与资料记录不一致。");
                    hash.AppendData(buffer.AsSpan(0, read));
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellation);
                }
                if (size != asset.ByteLength || !Convert.ToHexString(hash.GetHashAndReset()).Equals(asset.Sha256,
                        StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("媒体文件校验失败。");
            }
            Directory.Move(staged, destination);
            return snapshot with { Root = destination };
        }
        finally { if (Directory.Exists(staged)) Directory.Delete(staged, recursive: true); }
    }

    internal static string? FindAsset(string root, Asset asset)
    {
        var relative = asset.RelativePath().Split(Path.DirectorySeparatorChar);
        var current = root;
        for (var index = 0; index < relative.Length; index++)
        {
            current = Path.Combine(current, relative[index]);
            if (!Exists(current)) return null;
            if (index + 1 < relative.Length) SafeDirectory(current);
            else SafeFile(current, asset.ByteLength);
        }
        return current;
    }

    private static IEnumerable<string> Entries(string root)
    {
        var folder = Path.Combine(root, "entries");
        if (!Exists(folder)) yield break;
        SafeDirectory(folder);
        foreach (var path in Directory.EnumerateFileSystemEntries(folder).Where(path => Path.GetFileName(path) != ".DS_Store")
                     .Take(RecordLimit + 1).Select((path, index) => (path, index)))
        {
            if (path.index >= RecordLimit || !Guid.TryParseExact(Path.GetFileName(path.path), "D", out _))
                throw new InvalidDataException("笔记目录无效。");
            SafeDirectory(path.path);
            yield return path.path;
        }
    }

    private static IEnumerable<string> RecordFiles(string root, string directory)
    {
        var folder = Path.Combine(root, directory);
        if (!Exists(folder)) yield break;
        SafeDirectory(folder);
        foreach (var path in Directory.EnumerateFileSystemEntries(folder).Where(path => Path.GetFileName(path) != ".DS_Store" &&
                         (directory != ".drafts" || Path.GetExtension(path) == ".json"))
                     .Take(RecordLimit + 1).Select((path, index) => (path, index)))
        {
            if (path.index >= RecordLimit || Path.GetExtension(path.path) != ".json" ||
                !Guid.TryParseExact(Path.GetFileNameWithoutExtension(path.path), "D", out _))
                throw new InvalidDataException("资料记录目录无效。");
            yield return path.path;
        }
    }

    private static IReadOnlyList<T> ReadRecords<T>(string root, string dir, Func<T, Guid> key) =>
        RecordFiles(root, dir).Select(path =>
        {
            var item = Read<T>(SafeFile(path, MetadataLimit));
            if (key(item) != Guid.Parse(Path.GetFileNameWithoutExtension(path)))
                throw new InvalidDataException("资料记录标识与文件名不一致。");
            return item;
        }).ToArray();

    private static T Read<T>(string path) =>
        JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), JsonOptions)
        ?? throw new InvalidDataException("资料记录无效。");

    private static bool Exists(string path)
    {
        try { _ = File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    private static void SafeDirectory(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("资料库目录不能是链接。");
    }

    private static string SafeFile(string path, long maximum)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 ||
            new FileInfo(path).Length > maximum)
            throw new InvalidDataException("资料库文件类型或大小无效。");
        return path;
    }
}
