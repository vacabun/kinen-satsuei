using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace Kinen.Windows.Core;

public sealed record MediaSource(string Path, string Extension, string MimeType, bool IsVideo)
{
    public static MediaSource? FromPath(string path)
    {
        var extension = System.IO.Path.GetExtension(path).ToLowerInvariant();
        var mime = extension switch
        {
            ".jpg" or ".jpeg" => "image/jpeg",
            ".png" => "image/png",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".heic" => "image/heic",
            ".tif" or ".tiff" => "image/tiff",
            ".mp4" or ".m4v" => "video/mp4",
            ".mov" => "video/quicktime",
            ".mkv" => "video/x-matroska",
            ".webm" => "video/webm",
            ".avi" => "video/x-msvideo",
            _ => null
        };
        return mime is null ? null : new MediaSource(path, extension, mime, mime.StartsWith("video/", StringComparison.Ordinal));
    }
}

public sealed record Attribution(Guid Id, bool IsGroup);

public static partial class LibraryStore
{
    public static Attribution AddSubject(string root, string name, bool isGroup)
    {
        lock (NoteGate)
        {
            var title = name.Trim();
            if (title.Length == 0 || title.Length > 200)
                throw new InvalidDataException("请输入有效的成员或团体名称。");
            var id = Guid.NewGuid();
            var created = Timestamp();
            object record = isGroup
                ? new { id, name = title, createdAt = created }
                : new { id, name = title, createdAt = created, updatedAt = created, aliases = Array.Empty<string>(), archived = false };
            SaveNewRecord(root, isGroup ? "groups" : "members", id, record);
            return new Attribution(id, isGroup);
        }
    }

    public static Medium ImportMedia(string root, MediaSource source, string kind, string? day,
                                     Attribution? attribution, string note, CancellationToken cancellation = default)
    {
        lock (NoteGate)
        {
            var actual = MediaSource.FromPath(source.Path);
            if (source != actual || (source.IsVideo ? kind != "video" : kind is not ("photo" or "portrait" or "cheki")))
                throw new InvalidDataException("无法识别所选媒体。");
            if ((day is not null && !DateOnly.TryParseExact(day, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                           DateTimeStyles.None, out _)) || (kind == "cheki" && (day is null || attribution is null)))
                throw new InvalidDataException("请填写有效日期，并为拍立得选择成员或团体。");

            if (attribution is not null)
            {
                var subjectRoot = Path.Combine(root, attribution.IsGroup ? "groups" : "members");
                _ = SafeFile(Path.Combine(subjectRoot, attribution.Id + ".json"), MetadataLimit);
            }
            var id = Guid.NewGuid();
            var name = kind == "cheki" ? $"{attribution!.Id}_{day}_{id}{source.Extension}" : null;
            var staging = Path.Combine(root, $".media-{id:N}.tmp");
            string? installed = null;
            try
            {
                long size = 0;
                string sha256;
                using (var input = new FileStream(SafeFile(source.Path, long.MaxValue), FileMode.Open, FileAccess.Read))
                using (var output = new FileStream(staging, FileMode.CreateNew, FileAccess.Write))
                using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
                {
                    var buffer = new byte[128 * 1024];
                    int read;
                    while ((read = input.Read(buffer)) > 0)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        size += read;
                        hash.AppendData(buffer.AsSpan(0, read));
                        output.Write(buffer, 0, read);
                    }
                    sha256 = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                }
                if (size == 0) throw new InvalidDataException("媒体文件为空。");
                var asset = new Asset(sha256, size, source.MimeType, "media" + source.Extension, name);
                var relative = asset.RelativePath();
                var target = Path.Combine(root, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                if (!File.Exists(target))
                {
                    File.Move(staging, target);
                    installed = target;
                }
                else if (new FileInfo(SafeFile(target, size)).Length != size)
                    throw new InvalidDataException("现有媒体大小与内容摘要不一致。");

                var members = attribution is { IsGroup: false } ? new[] { attribution.Id } : [];
                var group = attribution is { IsGroup: true } ? attribution.Id : (Guid?)null;
                var time = Timestamp();
                SaveNewRecord(root, "media", id, new
                {
                    id, kind, captureDate = day, memberIds = members, groupId = group,
                    note, original = asset, createdAt = time, updatedAt = time
                });
                return new Medium(id, kind, day, members, group, note, null, asset, null);
            }
            catch
            {
                if (installed is not null && name is not null) File.Delete(installed);
                throw;
            }
            finally { if (File.Exists(staging)) File.Delete(staging); }
        }
    }

    private static void SaveNewRecord(string root, string directory, Guid id, object record)
    {
        var folder = Path.Combine(root, directory);
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, id + ".json");
        var staged = Path.Combine(root, $".json-{id:N}.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
            if (bytes.Length > MetadataLimit) throw new InvalidDataException("资料记录内容过大。");
            File.WriteAllBytes(staged, bytes);
            File.Move(staged, target, overwrite: false);
        }
        finally { if (File.Exists(staged)) File.Delete(staged); }
    }
}
