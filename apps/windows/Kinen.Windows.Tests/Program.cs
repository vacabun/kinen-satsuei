using Kinen.Windows.Core;

if (args.Length is < 1 or > 2) throw new ArgumentException("Pass the portable backup folder, and optionally a round-trip output folder.");
var source = Path.GetFullPath(args[0]);
var temp = Path.Combine(Path.GetTempPath(), $"KinenWindowsTests-{Guid.NewGuid():N}");
Directory.CreateDirectory(temp);
try
{
    var defaultStore = LibraryStore.CreateDefault(Path.Combine(temp, "default"));
    Check(defaultStore.Notes.Count == 0 && defaultStore.Media.Count == 0, "Expected an empty new library");

    var recovered = await LibraryStore.RestoreAsync(source, Path.Combine(temp, "recovered"));
    var trip = recovered.Notes.Single(note => note.Kind == "trip");
    var live = recovered.Notes.Single(note => note.Kind == "live");
    var photo = recovered.Media.Single();
    Check(live.ParentId == trip.Id && live.MediaIds.Single() == photo.Id, "Travel relationship or attachment was lost");
    Check(trip.Itinerary?.Single().Time == "18:00", "Travel itinerary was lost");
    Check(recovered.Names(photo).Single() == "测试成员", "Member attribution was lost");
    Check(recovered.Months(recovered.Media).Single() == ("2026-11", 1), "Month totals differ");
    Check(recovered.MissingAssets == 0, "Fixture unexpectedly missing an asset");

    var image = recovered.Attachment(photo) ?? throw new Exception("Photo not restored");
    var bytes = File.ReadAllBytes(image);
    bytes[^1] ^= 1;
    File.WriteAllBytes(image, bytes);
    var rejected = Path.Combine(temp, "rejected");
    try
    {
        await LibraryStore.RestoreAsync(recovered.Root, rejected);
        throw new Exception("Corrupted asset accepted");
    }
    catch (InvalidDataException)
    {
        Check(!Directory.Exists(rejected), "A failed restore left an installed library");
    }
    File.Delete(image);
    var missing = await LibraryStore.RestoreAsync(recovered.Root, Path.Combine(temp, "missing"));
    Check(missing.Notes.Count == 2 && missing.MissingAssets == 1, "Missing asset prevented reading the library");

    var newNote = new Note(Guid.NewGuid(), "memory", "Windows 回忆", "2026-11-21", null, live.Id, [photo.Id], null)
        { Body = "**Windows**" };
    LibraryStore.SaveDraft(recovered.Root, newNote);
    var draftSnapshot = LibraryStore.Load(recovered.Root);
    Check(draftSnapshot.Drafts.Single().Body == newNote.Body && draftSnapshot.Notes.Count == 2,
        "Draft was lost or published too early");
    var published = LibraryStore.PublishNote(recovered.Root, newNote);
    Check(published.Drafts.Count == 0 && published.Notes.Single(note => note.Id == newNote.Id).Body == newNote.Body,
        "Publishing did not install the body and clear the draft");
    LibraryStore.SaveDraft(recovered.Root, newNote with { Body = "未完成修改" });
    const string connectionFilename = ".git-connection.dpapi";
    File.WriteAllBytes(Path.Combine(recovered.Root, connectionFilename), [1, 2, 3]);
    var exported = await LibraryStore.RestoreAsync(recovered.Root, Path.Combine(temp, "exported"));
    Check(!File.Exists(Path.Combine(exported.Root, connectionFilename)),
        "Portable export included local Git credentials");
    Check(exported.Drafts.Count == 0 && exported.Notes.Single(note => note.Id == newNote.Id).Body == newNote.Body,
        "Export should contain only the published note");
    LibraryStore.DiscardDraft(recovered.Root, newNote.Id);
    Check(LibraryStore.Load(recovered.Root).Drafts.Count == 0, "Discard did not remove the draft");

    var entry = Path.Combine(recovered.Root, "entries", newNote.Id.ToString());
    var journal = Path.Combine(recovered.Root, ".note-writes", newNote.Id.ToString());
    Directory.CreateDirectory(Path.Combine(journal, "incoming"));
    Directory.Move(entry, Path.Combine(journal, "previous"));
    var repaired = LibraryStore.Load(recovered.Root);
    Check(repaired.Notes.Any(note => note.Id == newNote.Id) && !Directory.Exists(journal),
        "Interrupted replacement did not recover the previous note");

    var fixture = LibraryStore.Load(source);
    var input = MediaSource.FromPath(fixture.Attachment(fixture.Media.Single())!)!;
    var subject = LibraryStore.AddSubject(recovered.Root, "Windows 团体", isGroup: true);
    var imported = LibraryStore.ImportMedia(recovered.Root, input, "cheki", "2026-11-22", subject, "Windows 导入");
    Check(imported.GroupId == subject.Id && imported.MemberIds.Length == 0, "Group attribution not saved");
    Check(imported.Original.StoredFilename == $"{subject.Id}_2026-11-22_{imported.Id}.png", "Noncanonical cheki filename");
    var importedLibrary = LibraryStore.Load(recovered.Root);
    Check(importedLibrary.Names(imported).Single() == "Windows 团体" &&
          File.Exists(importedLibrary.Attachment(imported)), "Imported photo is unreadable");
    var ordinary = LibraryStore.ImportMedia(recovered.Root, input, "photo", null, null, "");
    Check(ordinary.Original.StoredFilename is null && ordinary.Original.Sha256 == imported.Original.Sha256,
        "The hashing and cheki naming rules must refer to the actual original bytes");
    try
    {
        _ = LibraryStore.ImportMedia(recovered.Root, input, "cheki", null, null, "");
        throw new Exception("Missing attribution and date accepted");
    }
    catch (InvalidDataException) { }

    if (args.Length == 2)
        _ = await LibraryStore.RestoreAsync(recovered.Root, Path.GetFullPath(args[1]));

    Console.WriteLine("Windows portable library: restore, hierarchy, media, statistics, draft recovery, publishing, portable export, media import and integrity checks passed.");
}
finally { Directory.Delete(temp, recursive: true); }

static void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
