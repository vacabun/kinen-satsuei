using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Media.Imaging;
using Kinen.Windows.Core;

namespace Kinen.Windows;

public partial class MediaImportWindow : Window
{
    private readonly string root;
    private List<MediaSource> pending;
    private bool loaded;
    private bool busy;
    private string? previewPath;

    public bool ImportedAnything { get; private set; }

    public MediaImportWindow(LibrarySnapshot library, List<MediaSource> sources)
    {
        root = library.Root;
        pending = sources;
        InitializeComponent();
        Kind.ItemsSource = new[] { "photo", "portrait", "cheki" }
            .Select(id => new KindChoice(id, Display.Kind(id))).ToArray();
        Kind.SelectedIndex = 0;
        UpdateSubjects(library, null);
        UpdateSelection();
        loaded = true;
    }

    private void KindChanged(object sender, RoutedEventArgs e)
    {
        if (loaded) UpdateSelection();
    }

    private void UpdateSelection()
    {
        SelectionCount.Text = $"已选择 {pending.Count} 项";
        SaveButton.IsEnabled = pending.Count != 0 && !busy;
        var images = pending.Where(item => !item.IsVideo).ToArray();
        KindSection.Visibility = images.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        SubjectsSection.Visibility = images.Length > 0 && (Kind.SelectedItem as KindChoice)?.Id == "cheki"
            ? Visibility.Visible : Visibility.Collapsed;
        var first = images.FirstOrDefault();
        if (previewPath == first?.Path && first is not null) return;
        previewPath = first?.Path;
        Preview.Source = null;
        if (first is not null)
        {
            try
            {
                var preview = new BitmapImage();
                preview.BeginInit();
                preview.CacheOption = BitmapCacheOption.OnLoad;
                preview.DecodePixelWidth = 720;
                preview.UriSource = new Uri(first.Path);
                preview.EndInit();
                Preview.Source = preview;
            }
            catch (Exception error) when (error is System.IO.IOException or NotSupportedException or FormatException or ArgumentException) { }
        }
        Preview.Visibility = Preview.Source is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateSubjects(LibrarySnapshot library, Attribution? selected)
    {
        var choices = new SubjectChoice[] { new(null, "请选择") }
            .Concat(library.Members.Select(item => new SubjectChoice(new Attribution(item.Id, false), item.Name + " · 成员")))
            .Concat(library.Groups.Select(item => new SubjectChoice(new Attribution(item.Id, true), item.Name + " · 团体")))
            .ToArray();
        Subjects.ItemsSource = choices;
        Subjects.SelectedItem = choices.FirstOrDefault(item => item.Attribution == selected) ?? choices[0];
    }

    private void AddMember(object sender, RoutedEventArgs e) => AddAttribution(isGroup: false);
    private void AddGroup(object sender, RoutedEventArgs e) => AddAttribution(isGroup: true);

    private void AddAttribution(bool isGroup)
    {
        if (busy) return;
        try
        {
            var selection = LibraryStore.AddSubject(root, SubjectName.Text, isGroup);
            SubjectName.Text = "";
            UpdateSubjects(LibraryStore.Load(root), selection);
            Status.Text = "已新增并选中。";
        }
        catch (Exception error) { Status.Text = error.Message; }
    }

    private async void SaveClicked(object sender, RoutedEventArgs e)
    {
        if (busy || pending.Count == 0) return;
        var imageKind = (Kind.SelectedItem as KindChoice)?.Id ?? "photo";
        var attribution = (Subjects.SelectedItem as SubjectChoice)?.Attribution;
        var day = CaptureDate.SelectedDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (pending.Any(item => !item.IsVideo) && imageKind == "cheki" && (attribution is null || day is null))
        {
            Status.Text = "请选择拍立得成员或团体，并填写拍摄日期。";
            return;
        }
        var files = pending.ToArray();
        var note = MemoryNote.Text;
        busy = true;
        Fields.IsEnabled = SaveButton.IsEnabled = CancelButton.IsEnabled = false;
        Status.Text = "正在保存…";
        try
        {
            var result = await Task.Run(() =>
            {
                var failed = new List<MediaSource>();
                string? message = null;
                foreach (var file in files)
                {
                    var kind = file.IsVideo ? "video" : imageKind;
                    try { LibraryStore.ImportMedia(root, file, kind, day, kind == "cheki" ? attribution : null, note); }
                    catch (Exception error)
                    {
                        failed.Add(file);
                        message = error.Message;
                    }
                }
                return (failed, message);
            });
            pending = result.failed;
            ImportedAnything |= pending.Count < files.Length;
            Status.Text = result.message ?? "";
        }
        finally
        {
            busy = false;
            Fields.IsEnabled = CancelButton.IsEnabled = true;
            UpdateSelection();
        }
        if (pending.Count == 0) DialogResult = true;
    }

    private void CancelClicked(object sender, RoutedEventArgs e) => Close();
    private void WindowClosing(object? sender, CancelEventArgs e) => e.Cancel = busy;

    private sealed record KindChoice(string Id, string Label);
    private sealed record SubjectChoice(Attribution? Attribution, string Label);
}
