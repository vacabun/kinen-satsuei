using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using Microsoft.Win32;

namespace Kinen.Windows;

public partial class GitRestoreWindow : Window
{
    private readonly string operation;
    private GitConnection? savedConnection;
    private string? selectedKeyPath;

    public GitRestoreWindow() : this("restore") { }

    internal GitRestoreWindow(string operation)
    {
        this.operation = operation;
        InitializeComponent();
        if (operation != "restore")
        {
            Title = operation == "initialize" ? "首次 Git 备份" : "更新 Git 备份";
            Confirm.Content = "继续";
            Attachments.Visibility = Visibility.Visible;
            Feedback.Text = operation == "initialize"
                ? "默认仅上传笔记与元数据。请使用空分支，建议将仓库设为私有。"
                : "远端分支自上次备份或恢复后发生变化时，将停止上传。";
        }
    }

    internal bool IncludeAttachments => Attachments.IsChecked == true;

    internal sealed record GitResult(string Revision, int Omitted, bool Unchanged, GitConnection? Connection);

    internal void UseSavedConnection(GitConnection connection)
    {
        savedConnection = connection;
        Endpoint.Text = connection.Endpoint;
        Branch.Text = connection.Branch;
        KeyPath.Text = "已保存的 SSH 私钥";
        Remember.IsChecked = true;
        Attachments.IsChecked = connection.Attachments;
        if (operation == "update")
        {
            Endpoint.IsReadOnly = true;
            Branch.IsReadOnly = true;
            Remember.IsEnabled = false;
        }
    }

    private bool MatchesSavedHost(Uri uri)
    {
        return savedConnection is not null &&
            Uri.TryCreate(savedConnection.Endpoint, UriKind.Absolute, out var saved) &&
            string.Equals(uri.IdnHost, saved.IdnHost, StringComparison.OrdinalIgnoreCase) &&
            (uri.Port < 0 ? 22 : uri.Port) == (saved.Port < 0 ? 22 : saved.Port);
    }

    private void ChooseKey(object sender, RoutedEventArgs args)
    {
        var dialog = new OpenFileDialog { Title = "选择 SSH 私钥" };
        if (dialog.ShowDialog(this) != true) return;
        selectedKeyPath = dialog.FileName;
        KeyPath.Text = dialog.FileName;
    }

    private void Accept(object sender, RoutedEventArgs args)
    {
        if (!Uri.TryCreate(Endpoint.Text.Trim(), UriKind.Absolute, out var uri) ||
            uri.Scheme != "ssh" || string.IsNullOrWhiteSpace(Branch.Text) ||
            (selectedKeyPath is null && !MatchesSavedHost(uri)))
        {
            Feedback.Text = "请填写 ssh:// 仓库地址和分支，并选择 SSH 私钥。";
            return;
        }
        DialogResult = true;
    }

    internal async Task<GitResult?> Transfer(string snapshotPath, Window owner)
    {
        var endpoint = Endpoint.Text.Trim();
        var branch = Branch.Text.Trim();
        var matchesSavedHost = MatchesSavedHost(new Uri(endpoint));
        var passphrase = Passphrase.Password;
        string key;
        if (selectedKeyPath is { } keyPath)
        {
            var info = new FileInfo(keyPath);
            if (info.Length > 128 * 1024) throw new IOException("SSH 私钥文件太大。");
            key = await File.ReadAllTextAsync(info.FullName);
        }
        else
        {
            if (!matchesSavedHost || savedConnection is null) throw new IOException("请选择 SSH 私钥。");
            key = savedConnection.Key;
            if (passphrase.Length == 0) passphrase = savedConnection.Passphrase;
        }
        var fingerprint = matchesSavedHost ? savedConnection!.Fingerprint : "";
        while (true)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3.5));
            using var helper = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(AppContext.BaseDirectory, "kinen-git.exe"),
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                StandardInputEncoding = new System.Text.UTF8Encoding(false),
                StandardOutputEncoding = System.Text.Encoding.UTF8,
            }) ?? throw new IOException("无法启动 Git 组件。");
            string output;
            try
            {
                var request = JsonSerializer.Serialize(new
                {
                    Endpoint = endpoint, Branch = branch, Key = key,
                    Passphrase = passphrase, Fingerprint = fingerprint,
                    Operation = operation,
                    Source = operation == "restore" ? null : snapshotPath,
                    Destination = operation == "restore" ? snapshotPath : null,
                    Expected = operation == "update" ? savedConnection?.Revision : null,
                    Attachments = IncludeAttachments,
                });
                await helper.StandardInput.WriteLineAsync(request.AsMemory(), timeout.Token);
                helper.StandardInput.Close();
                output = await helper.StandardOutput.ReadToEndAsync(timeout.Token);
                await helper.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                if (!helper.HasExited) helper.Kill(entireProcessTree: true);
                await helper.WaitForExitAsync();
                throw new IOException("连接 Git 服务器超时。");
            }
            if (helper.ExitCode != 0) throw new IOException("Git 组件执行失败。");
            using var document = JsonDocument.Parse(output);
            var result = document.RootElement;
            if (result.TryGetProperty("error", out var error)) throw new IOException(error.GetString());
            if (result.TryGetProperty("fingerprint", out var host))
            {
                if (fingerprint.Length > 0) throw new IOException("SSH 主机指纹发生变化，操作已停止。");
                fingerprint = host.GetString() ?? throw new IOException("无法识别 SSH 主机指纹。");
                var verified = MessageBox.Show(owner,
                    $"请与 Git 服务公布的指纹核对。\n\n{Endpoint.Text.Trim()}\n{fingerprint}\n\n是否确认指纹一致？",
                    "核对 SSH 主机指纹", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
                if (verified != MessageBoxResult.Yes) return null;
                continue;
            }
            var revision = result.GetProperty("revision").GetString() ?? throw new IOException("未取得 Git 提交。");
            var connection = Remember.IsChecked == true
                ? new GitConnection(endpoint, branch, key, passphrase, fingerprint, IncludeAttachments, revision)
                : null;
            return new GitResult(revision,
                result.TryGetProperty("omitted", out var omitted) ? omitted.GetInt32() : 0,
                result.TryGetProperty("unchanged", out var unchanged) && unchanged.GetBoolean(), connection);
        }
    }
}
