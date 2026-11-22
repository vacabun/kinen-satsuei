using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace Kinen.Windows;

internal sealed record GitConnection(
    string Endpoint, string Branch, string Key, string Passphrase, string Fingerprint, bool Attachments, string? Revision = null);

internal static class GitConnectionStore
{
    private const string Filename = ".git-connection.dpapi";

    internal static bool Exists(string libraryRoot) => File.Exists(Path.Combine(libraryRoot, Filename));

    internal static GitConnection? Load(string libraryRoot)
    {
        var path = Path.Combine(libraryRoot, Filename);
        if (!File.Exists(path)) return null;

        var plaintext = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<GitConnection>(plaintext)
                ?? throw new InvalidDataException("无法读取已保存的 Git 连接。");
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    internal static void Save(string libraryRoot, GitConnection connection)
    {
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(connection);
        var temporary = Path.Combine(libraryRoot, $".git-connection-{Guid.NewGuid():N}.tmp");
        try
        {
            var encrypted = ProtectedData.Protect(plaintext, null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(temporary, encrypted);
            File.Move(temporary, Path.Combine(libraryRoot, Filename), overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            File.Delete(temporary);
        }
    }

    internal static void Remove(string libraryRoot) => File.Delete(Path.Combine(libraryRoot, Filename));
}
