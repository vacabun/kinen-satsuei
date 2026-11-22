using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Kinen.Windows.Core;
using Microsoft.Win32;

namespace Kinen.Windows;

public partial class MainWindow : Window
{
    private readonly string libraryHome = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KinenSatsuei", "libraries");
    private LibrarySnapshot? snapshot;
    private bool ready;
    private string page = "notes";
    private bool busy;
    private MediaElement? video;
    private string? temporaryVideo;

    public MainWindow() => InitializeComponent();

    private async void WindowLoaded(object sender, RoutedEventArgs e)
    {
        if (ready) return;
        ready = true;
        busy = true;
        Navigation.IsEnabled = false;
        try
        {
            snapshot = await Task.Run(() =>
            {
                var marker = Path.Combine(libraryHome, "active.txt");
                var selected = File.Exists(marker) ? File.ReadAllText(marker).Trim() : "";
                if (Guid.TryParseExact(selected, "D", out var id) && Directory.Exists(Path.Combine(libraryHome, id.ToString())))
                    return LibraryStore.Load(Path.Combine(libraryHome, id.ToString()));
                return LibraryStore.CreateDefault(Path.Combine(libraryHome, "default"));
            });
            RenderPage();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法读取资料库", MessageBoxButton.OK, MessageBoxImage.Warning);
            Navigation.SelectedIndex = 3;
        }
        finally
        {
            busy = false;
            Navigation.IsEnabled = true;
        }
    }

    private void Navigate(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || Navigation.SelectedItem is not ListBoxItem { Tag: string destination }) return;
        page = destination;
        Query.Text = "";
        RenderPage();
    }

    private void SearchChanged(object sender, TextChangedEventArgs e)
    {
        if (ready && page != "library") UpdateList();
    }

    private void SubjectChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ready && page == "collection") UpdateList();
    }

    private void RenderPage()
    {
        ListTitle.Text = (Navigation.SelectedItem as ListBoxItem)?.Content?.ToString();
        Query.Visibility = page == "library" ? Visibility.Collapsed : Visibility.Visible;
        Subjects.Visibility = page == "collection" ? Visibility.Visible : Visibility.Collapsed;
        NewNoteButton.Visibility = page == "notes" ? Visibility.Visible : Visibility.Collapsed;
        ImportButton.Visibility = page is "media" or "collection" ? Visibility.Visible : Visibility.Collapsed;
        if (page == "collection" && snapshot is { } library)
        {
            Subjects.ItemsSource = new SubjectChoice[] { new(null, false, "全部拍立得") }
                .Concat(library.Members.Select(member => new SubjectChoice(member.Id, false, member.Name + " · 成员")))
                .Concat(library.Groups.Select(group => new SubjectChoice(group.Id, true, group.Name + " · 团体")))
                .ToArray();
            Subjects.SelectedIndex = 0;
        }
        UpdateList();
        if (page == "library") ShowLibrary();
        else if (page == "collection") ShowStatistics();
        else
        {
            ClearDetail();
            Text(page == "notes" ? "选择一篇笔记" : "选择照片或视频", 21);
        }
    }

    private void UpdateList()
    {
        if (snapshot is not { } library) return;
        var terms = Query.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        bool Matches(params string?[] fields) =>
            terms.All(term => fields.Any(field => field?.Contains(term, StringComparison.CurrentCultureIgnoreCase) == true));

        var rows = page switch
        {
            "notes" => library.Drafts.Where(note => Matches(note.Title, note.Body, note.StartDate))
                .Select(note => new Row(string.IsNullOrWhiteSpace(note.Title) ? "未命名笔记" : note.Title,
                                        "草稿 · " + note.Caption, new DraftSelection(note)))
                .Concat(library.Notes.Where(note => Matches(note.Title, note.Body, note.StartDate,
                        string.Join(' ', (note.Itinerary ?? []).Select(stop => stop.Title + " " + stop.Location))))
                    .Select(note => new Row(note.Title, note.Caption, note))).ToArray(),
            "media" or "collection" => FilterMedia(library).Where(item =>
                    Matches(item.CaptureDate, item.Note, string.Join(' ', library.Names(item))))
                .Select(item =>
                {
                    var names = string.Join("、", library.Names(item));
                    return new Row(names.Length == 0 ? Display.Kind(item.Kind) : names,
                                   item.CaptureDate ?? "日期未知", item);
                }).ToArray(),
            _ => []
        };
        Items.ItemsSource = rows;
        ListSummary.Text = page == "library" ? "" :
            page == "notes" ? $"{rows.Length} 篇笔记" : $"{rows.Length} 项媒体";
        if (page == "collection") ShowStatistics();
    }

    private IEnumerable<Medium> FilterMedia(LibrarySnapshot library)
    {
        if (page != "collection") return library.Media;
        var selection = Subjects.SelectedItem as SubjectChoice;
        return library.Media.Where(item => item.Kind == "cheki" &&
            (selection?.Id is not Guid id || (selection.IsGroup ? item.GroupId == id : item.MemberIds.Contains(id))));
    }

    private void OpenItem(object sender, SelectionChangedEventArgs e)
    {
        if (Items.SelectedItem is not Row row) return;
        ClearDetail();
        if (row.Value is Note note) ShowNote(note);
        else if (row.Value is Medium item) ShowMedia(item);
        else if (row.Value is DraftSelection draft) EditNote(draft.Note);
    }

    private void ImportClicked(object sender, RoutedEventArgs e)
    {
        if (busy || snapshot is null) return;
        var picker = new OpenFileDialog
        {
            Title = "选择照片或视频",
            Filter = "媒体文件|*.jpg;*.jpeg;*.png;*.gif;*.webp;*.heic;*.tif;*.tiff;*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi",
            Multiselect = true
        };
        if (picker.ShowDialog(this) == true) ImportFiles(picker.FileNames);
    }

    private void FilesDragOver(object sender, DragEventArgs e)
    {
        e.Effects = !busy && snapshot is not null && e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void FilesDropped(object sender, DragEventArgs e)
    {
        if (!busy && e.Data.GetData(DataFormats.FileDrop) is string[] paths) ImportFiles(paths);
        e.Handled = true;
    }

    private async void ImportFiles(IEnumerable<string> paths)
    {
        if (busy || snapshot is not { } library) return;
        var files = paths.Distinct(StringComparer.OrdinalIgnoreCase).Select(MediaSource.FromPath)
            .OfType<MediaSource>().ToList();
        if (files.Count == 0)
        {
            MessageBox.Show(this, "请选择照片或视频。", "导入媒体", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        busy = true;
        try
        {
            var window = new MediaImportWindow(library, files) { Owner = this };
            window.ShowDialog();
            snapshot = await Task.Run(() => LibraryStore.Load(library.Root));
            if (window.ImportedAnything) Navigation.SelectedIndex = 1;
            RenderPage();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法导入媒体", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { busy = false; }
    }

    private void NewNoteClicked(object sender, RoutedEventArgs e) =>
        EditNote(new Note(Guid.NewGuid(), "journal", "", DateTime.Today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                          null, null, [], null));

    private async void EditNote(Note note)
    {
        if (busy || snapshot is not { } library) return;
        busy = true;
        try
        {
            var editor = new NoteEditorWindow(library, note) { Owner = this };
            var published = editor.ShowDialog() == true;
            snapshot = await Task.Run(() => LibraryStore.Load(library.Root));
            RenderPage();
            if (published && snapshot.Notes.FirstOrDefault(item => item.Id == note.Id) is { } current)
            {
                ClearDetail();
                ShowNote(current);
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法编辑笔记", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { busy = false; }
    }

    private void ShowNote(Note note)
    {
        if (snapshot is not { } library) return;
        Text(note.Title, 26);
        Button("编辑笔记", (_, _) => EditNote(library.Drafts.FirstOrDefault(draft => draft.Id == note.Id) ?? note));
        Text(note.EndDate is null ? note.Caption : note.Caption + " 至 " + note.EndDate);
        var blocks = Regex.Split(note.Body.Trim(), @"\r?\n\s*\r?\n");
        foreach (var block in blocks.Where(block => block.Length != 0))
        {
            var match = Regex.Match(block, @"^!?\[(.*?)\]\(media:([0-9a-fA-F-]{36})\)$");
            if (match.Success && Guid.TryParse(match.Groups[2].Value, out var id) &&
                library.Media.FirstOrDefault(item => item.Id == id) is { } media)
            {
                Button(match.Groups[1].Value, (_, _) => { ClearDetail(); ShowMedia(media); });
            }
            else if (block.StartsWith("# "))
                Text(block[2..], 21);
            else
                Text(block);
        }
        foreach (var stop in (note.Itinerary ?? []).OrderBy(stop => stop.Date).ThenBy(stop => stop.Time ?? "24:00"))
        {
            Text(stop.Title, 17);
            Text(string.Join(" · ", new[] { stop.Date, stop.Time, stop.Location, stop.Note }.Where(value => !string.IsNullOrEmpty(value))));
        }
        foreach (var child in library.Notes.Where(item => item.ParentId == note.Id))
            Button(child.Title, (_, _) => { ClearDetail(); ShowNote(child); });
        foreach (var related in library.Media.Where(item => note.MediaIds.Contains(item.Id)))
            Button($"{Display.Kind(related.Kind)} · {related.CaptureDate ?? "日期未知"}",
                   (_, _) => { ClearDetail(); ShowMedia(related); });
    }

    private void ShowMedia(Medium item)
    {
        if (snapshot is not { } library) return;
        Text(Display.Kind(item.Kind), 24);
        Text(string.Join(" · ", new[] { item.CaptureDate ?? "日期未知" }.Concat(library.Names(item))));
        if (!string.IsNullOrWhiteSpace(item.Note)) Text(item.Note);
        try
        {
            var path = library.Attachment(item);
            if (path is null)
            {
                Text("附件不可用");
                return;
            }
            if (item.Kind == "video")
            {
                var extension = Path.GetExtension(item.Original.OriginalFilename);
                if (extension.Length is < 2 or > 12 || extension.Skip(1).Any(c => !char.IsAsciiLetterOrDigit(c)))
                    extension = ".mp4";
                temporaryVideo = Path.Combine(Path.GetTempPath(), $"Kinen-{Guid.NewGuid():N}{extension}");
                File.Copy(path, temporaryVideo);
                video = new MediaElement { Source = new Uri(temporaryVideo), Height = 300,
                    LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Close, Stretch = Stretch.Uniform };
                video.MediaFailed += (_, args) => Text(args.ErrorException.Message);
                Detail.Children.Add(video);
                Button("播放", (_, _) => video?.Play());
                Button("暂停", (_, _) => video?.Pause());
            }
            else
            {
                using var stream = File.OpenRead(path);
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 1800;
                bitmap.StreamSource = stream;
                bitmap.EndInit();
                bitmap.Freeze();
                var image = new Image { Source = bitmap, MaxHeight = 430, Stretch = Stretch.Uniform,
                    LayoutTransform = new RotateTransform((item.QuarterTurns ?? 0) * 90) };
                Detail.Children.Add(image);
            }
        }
        catch (Exception error) { Text(error.Message); }
    }

    private void ShowStatistics()
    {
        if (snapshot is not { } library) return;
        ClearDetail();
        var photos = FilterMedia(library).ToArray();
        Text($"拍立得 · {photos.Length} 张", 24);
        Text("按拍摄月份统计");
        foreach (var (month, count) in library.Months(photos))
            Text($"{month}   {count} 张");
        var unknown = photos.Count(item => item.CaptureDate is null);
        if (unknown > 0) Text($"日期未知 · {unknown} 张");
    }

    private void ShowLibrary()
    {
        ClearDetail();
        Text("资料库", 25);
        if (snapshot is { } library)
        {
            Text(library.Root.EndsWith(Path.DirectorySeparatorChar + "default") ? "默认资料库" : library.Manifest.Title);
            Text($"{library.Notes.Count} 篇笔记 · {library.Media.Count} 项媒体");
        }
        Button("恢复备份文件夹…", async (_, _) => await RestoreBackup());
        Button("从 Git 恢复资料库…", async (_, _) => await RestoreGitBackup());
        if (snapshot is not null)
        {
            Button("导出备份…", async (_, _) => await ExportBackup());
            Button("首次备份到 Git…", async (_, _) => await UploadGitBackup(update: false));
            if (GitConnectionStore.Exists(snapshot.Root))
            {
                Button("更新 Git 备份…", async (_, _) => await UploadGitBackup(update: true));
                Button("移除此资料库的 Git 连接", (_, _) => RemoveGitConnection());
            }
        }
        if (Directory.Exists(libraryHome))
        {
            foreach (var directory in Directory.EnumerateDirectories(libraryHome).Order())
            {
                var id = Path.GetFileName(directory);
                if (id != "default" && !Guid.TryParseExact(id, "D", out _)) continue;
                if (snapshot?.Root == directory) continue;
                Button(id == "default" ? "切换到默认资料库" : $"打开已恢复资料库 · {Directory.GetCreationTime(directory):yyyy-MM-dd HH:mm}",
                       async (_, _) => await SwitchLibrary(directory, id));
            }
        }
    }

    private async Task ExportBackup()
    {
        if (busy || snapshot is not { } library) return;
        var dialog = new OpenFolderDialog { Title = "选择备份保存位置" };
        if (dialog.ShowDialog(this) != true) return;
        var suffix = Guid.NewGuid().ToString("N")[..6];
        var name = $"記念撮影-{DateTime.Today:yyyy-MM-dd}-{suffix}";
        busy = true;
        try
        {
            var exported = await Task.Run(() => LibraryStore.RestoreAsync(library.Root, Path.Combine(dialog.FolderName, name)));
            Text($"备份已保存。共 {exported.Notes.Count} 篇笔记、{exported.Media.Count} 项媒体。");
        }
        catch (Exception error) { Text(error.Message); }
        finally { busy = false; }
    }

    private async Task RestoreBackup()
    {
        if (busy) return;
        var dialog = new OpenFolderDialog { Title = "选择含有 library.json 的文件夹" };
        if (dialog.ShowDialog(this) != true) return;
        var id = Guid.NewGuid().ToString();
        busy = true;
        try
        {
            snapshot = await Task.Run(() => LibraryStore.RestoreAsync(dialog.FolderName, Path.Combine(libraryHome, id)));
            PersistActive(id);
            ShowLibrary();
            Text($"已恢复资料库。缺失附件 {snapshot.MissingAssets} 项。");
        }
        catch (Exception error) { Text(error.Message); }
        finally { busy = false; }
    }

    private async Task UploadGitBackup(bool update)
    {
        if (busy || snapshot is not { } library) return;
        var dialog = new GitRestoreWindow(update ? "update" : "initialize") { Owner = this };
        var connection = LoadGitConnection(dialog, library.Root);
        if (update && string.IsNullOrEmpty(connection?.Revision))
        {
            Text("此连接尚无备份版本。请先预览并恢复远端资料库。");
            return;
        }
        if (dialog.ShowDialog() != true) return;
        var scope = dialog.IncludeAttachments ? "笔记、元数据和符合大小限制的附件" : "笔记和元数据";
        var confirmed = MessageBox.Show(this, $"将上传「{library.Manifest.Title}」的{scope}。\n\n确认上传到目标 Git 分支？",
            update ? "确认更新备份" : "确认首次备份", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
        if (confirmed != MessageBoxResult.Yes) return;
        busy = true;
        using var workspace = new GitBackupWorkspace();
        try
        {
            var staged = workspace.CreateSnapshotPath();
            Text("正在准备资料库备份…");
            await Task.Run(() => LibraryStore.RestoreAsync(library.Root, staged, includeAttachments: dialog.IncludeAttachments));
            var result = await dialog.Transfer(staged, this);
            var saved = SaveGitConnection(library.Root, result?.Connection);
            ShowLibrary();
            if (result is not null)
            {
                Text(result.Unchanged ? "远端备份已是最新版本。" : $"已上传 Git 备份 · {result.Revision[..8]}");
                if (!saved) Text("无法保存 SSH 连接。");
                if (result.Omitted > 0) Text($"超过 95 MiB 的附件已跳过，共 {result.Omitted} 项。");
            }
        }
        catch (Exception error) { Text(error.Message); }
        finally { busy = false; }
    }

    private async Task RestoreGitBackup()
    {
        if (busy) return;
        var dialog = new GitRestoreWindow { Owner = this };
        if (snapshot is { } current) LoadGitConnection(dialog, current.Root);
        if (dialog.ShowDialog() != true) return;
        busy = true;
        using var workspace = new GitBackupWorkspace();
        try
        {
            var source = workspace.CreateSnapshotPath();
            Text("正在读取远端资料库…");
            var result = await dialog.Transfer(source, this);
            if (result is null)
            {
                ShowLibrary();
                return;
            }
            var preview = await Task.Run(() => LibraryStore.Load(source));
            var confirmed = MessageBox.Show(this,
                $"{preview.Manifest.Title}\n{preview.Notes.Count} 篇笔记 · {preview.Media.Count} 项媒体\n缺失附件 {preview.MissingAssets} 项\n\n恢复为独立资料库？",
                "远端资料库预览", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (confirmed != MessageBoxResult.Yes)
            {
                ShowLibrary();
                return;
            }
            var id = Guid.NewGuid().ToString();
            var restored = await Task.Run(() => LibraryStore.RestoreAsync(source, Path.Combine(libraryHome, id)));
            PersistActive(id);
            snapshot = restored;
            var saved = SaveGitConnection(restored.Root, result.Connection);
            ShowLibrary();
            Text($"已恢复资料库。缺失附件 {restored.MissingAssets} 项。");
            if (!saved) Text("无法保存 SSH 连接。");
        }
        catch (Exception error) { Text(error.Message); }
        finally { busy = false; }
    }

    private GitConnection? LoadGitConnection(GitRestoreWindow dialog, string libraryRoot)
    {
        try
        {
            var connection = GitConnectionStore.Load(libraryRoot);
            if (connection is not null) dialog.UseSavedConnection(connection);
            return connection;
        }
        catch (Exception)
        {
            Text("无法读取此资料库保存的 Git 连接。");
            return null;
        }
    }

    private static bool SaveGitConnection(string libraryRoot, GitConnection? connection)
    {
        if (connection is null) return true;
        try
        {
            GitConnectionStore.Save(libraryRoot, connection);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void RemoveGitConnection()
    {
        if (busy || snapshot is not { } library) return;
        if (MessageBox.Show(this, "移除此资料库保存在本机的 SSH 连接和密钥？",
                "移除 Git 连接", MessageBoxButton.YesNo, MessageBoxImage.Question,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        try
        {
            GitConnectionStore.Remove(library.Root);
            ShowLibrary();
        }
        catch (Exception error) { Text(error.Message); }
    }

    private sealed class GitBackupWorkspace : IDisposable
    {
        private string? folder;

        public string CreateSnapshotPath()
        {
            folder = Directory.CreateTempSubdirectory("kinen-git-").FullName;
            return Path.Combine(folder, "snapshot");
        }

        public void Dispose()
        {
            if (folder is null) return;
            try { Directory.Delete(folder, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private async Task SwitchLibrary(string folder, string id)
    {
        if (busy) return;
        busy = true;
        try
        {
            snapshot = await Task.Run(() => LibraryStore.Load(folder));
            PersistActive(id);
            ShowLibrary();
        }
        catch (Exception error) { Text(error.Message); }
        finally { busy = false; }
    }

    private void PersistActive(string id)
    {
        var marker = Path.Combine(libraryHome, "active.txt");
        var temporary = marker + ".new";
        File.WriteAllText(temporary, id);
        File.Move(temporary, marker, overwrite: true);
    }

    private void ClearDetail()
    {
        video?.Close();
        video = null;
        if (temporaryVideo is { } path)
        {
            try { File.Delete(path); }
            catch (IOException) { }
            temporaryVideo = null;
        }
        Detail.Children.Clear();
    }

    private void Text(string value, double size = 14) => Detail.Children.Add(new TextBlock
    {
        Text = value, FontSize = size, FontWeight = size >= 20 ? FontWeights.SemiBold : FontWeights.Normal,
        Margin = new Thickness(0, 0, 0, 10)
    });

    private void Button(string label, RoutedEventHandler click)
    {
        var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left };
        button.Click += click;
        Detail.Children.Add(button);
    }

    private void WindowClosed(object? sender, EventArgs e) => ClearDetail();

    private sealed record Row(string Title, string Subtitle, object Value);
    private sealed record DraftSelection(Note Note);
    private sealed record SubjectChoice(Guid? Id, bool IsGroup, string Label);
}
