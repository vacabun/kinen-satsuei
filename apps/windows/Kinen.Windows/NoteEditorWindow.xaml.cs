using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Threading;
using Kinen.Windows.Core;

namespace Kinen.Windows;

public partial class NoteEditorWindow : Window
{
    private readonly LibrarySnapshot snapshot;
    private readonly Note original;
    private readonly DispatcherTimer debounce = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private bool loaded;
    private bool edited;
    private bool finished;

    public NoteEditorWindow(LibrarySnapshot snapshot, Note note)
    {
        this.snapshot = snapshot;
        original = note;
        InitializeComponent();

        TitleField.Text = note.Title;
        BodyField.Text = note.Body;
        KindField.ItemsSource = new[] { "journal", "memory", "live", "trip" }
            .Select(kind => new KindOption(kind, Display.Kind(kind))).ToArray();
        KindField.SelectedItem = ((IEnumerable<KindOption>)KindField.ItemsSource)
            .FirstOrDefault(option => option.Id == note.Kind);
        KindField.IsEnabled = note.Itinerary is not { Length: > 0 };
        StartDate.SelectedDate = Parse(note.StartDate);
        EndDate.SelectedDate = Parse(note.EndDate);
        UpdateParents(note.Kind, note.ParentId);
        var media = snapshot.Media.Select(item =>
            new PickerOption(item.Id, $"{Display.Kind(item.Kind)} · {item.CaptureDate ?? "日期未知"}")).ToArray();
        MediaField.ItemsSource = media;
        foreach (var item in media.Where(item => item.Id is Guid id && note.MediaIds.Contains(id)))
            MediaField.SelectedItems.Add(item);
        Discard.Visibility = snapshot.Drafts.Any(item => item.Id == note.Id) ? Visibility.Visible : Visibility.Collapsed;
        debounce.Tick += (_, _) =>
        {
            debounce.Stop();
            TrySaveDraft();
        };
        loaded = true;
    }

    private void KindChanged(object sender, RoutedEventArgs e)
    {
        if (!loaded || KindField.SelectedItem is not KindOption kind) return;
        UpdateParents(kind.Id, (ParentField.SelectedItem as PickerOption)?.Id);
        EditChanged(sender, e);
    }

    private void UpdateParents(string kind, Guid? selected)
    {
        EndDateRow.Visibility = kind == "trip" ? Visibility.Visible : Visibility.Collapsed;
        var parents = new PickerOption[] { new(null, "独立笔记") }.Concat(snapshot.Notes
            .Where(note => note.Id != original.Id && LibraryStore.AllowsChild(note.Kind, kind))
            .Select(note => new PickerOption(note.Id, note.Title))).ToArray();
        ParentField.ItemsSource = parents;
        ParentField.SelectedItem = parents.FirstOrDefault(option => option.Id == selected) ?? parents[0];
    }

    private void EditChanged(object sender, RoutedEventArgs e)
    {
        if (!loaded) return;
        edited = true;
        Discard.Visibility = Visibility.Visible;
        SaveStatus.Text = "正在编辑…";
        debounce.Stop();
        debounce.Start();
    }

    private Note Candidate()
    {
        var kind = (KindField.SelectedItem as KindOption)?.Id ?? original.Kind;
        var selected = MediaField.SelectedItems.OfType<PickerOption>().Select(item => item.Id!.Value).ToHashSet();
        var media = original.MediaIds.Where(selected.Contains)
            .Concat(snapshot.Media.Select(item => item.Id).Where(selected.Contains).Except(original.MediaIds)).ToArray();
        return original with
        {
            Kind = kind, Title = TitleField.Text, Body = BodyField.Text,
            StartDate = StartDate.SelectedDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) ?? "",
            EndDate = kind == "trip" ? EndDate.SelectedDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : null,
            ParentId = (ParentField.SelectedItem as PickerOption)?.Id,
            MediaIds = media
        };
    }

    private bool TrySaveDraft()
    {
        try
        {
            LibraryStore.SaveDraft(snapshot.Root, Candidate());
            SaveStatus.Text = "草稿已保存";
            return true;
        }
        catch (Exception error)
        {
            SaveStatus.Text = error.Message;
            return false;
        }
    }

    private void PublishClicked(object sender, RoutedEventArgs e)
    {
        debounce.Stop();
        try
        {
            var note = Candidate();
            LibraryStore.SaveDraft(snapshot.Root, note);
            LibraryStore.PublishNote(snapshot.Root, note);
            finished = true;
            DialogResult = true;
        }
        catch (Exception error) { SaveStatus.Text = error.Message; }
    }

    private void DiscardClicked(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "丢弃这份草稿？已完成的笔记会保留。", "丢弃草稿",
                            MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        debounce.Stop();
        try
        {
            LibraryStore.DiscardDraft(snapshot.Root, original.Id);
            finished = true;
            Close();
        }
        catch (Exception error) { SaveStatus.Text = error.Message; }
    }

    private void CloseClicked(object sender, RoutedEventArgs e) => Close();

    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        debounce.Stop();
        if (!finished && edited && !TrySaveDraft()) e.Cancel = true;
    }

    private static DateTime? Parse(string? value) =>
        DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;

    private sealed record KindOption(string Id, string Label);
    private sealed record PickerOption(Guid? Id, string Label);
}
