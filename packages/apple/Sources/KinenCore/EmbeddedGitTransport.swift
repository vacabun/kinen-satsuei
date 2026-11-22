import Foundation
import KinenGitBridge

public enum EmbeddedGitError: Error, LocalizedError {
    case untrustedHost(GitSSHHostPin)
    case changedHost(GitSSHHostPin)
    case authentication

    public var errorDescription: String? {
        switch self {
        case .untrustedHost(let pin): "请先核对服务器指纹：\(pin.fingerprint)"
        case .changedHost(let pin): "SSH 服务器指纹已变更：\(pin.fingerprint)"
        case .authentication: "SSH 鉴权失败，请检查密钥、口令和仓库访问权限。"
        }
    }
}

public actor EmbeddedGitTransport: JournaledGitTransport {
    private let remote: URL
    private let branch: String
    private let repository: URL
    private let credentials: GitSSHCredentials?
    private let files = FileManager.default

    public init(remote: URL, branch: String, repository: URL, credentials: GitSSHCredentials?) throws {
        if !remote.isFileURL {
            guard remote.scheme?.lowercased() == "ssh", let host = remote.host, !host.isEmpty,
                  remote.password == nil, remote.query == nil, remote.fragment == nil,
                  !remote.path.isEmpty else { throw GitTransportError.invalidRemote }
        }
        guard !branch.isEmpty, !branch.hasPrefix("-"), branch.utf8.count < 1000,
              !branch.utf8.contains(0) else { throw GitTransportError.invalidBranch }
        self.remote = remote
        self.branch = branch
        self.repository = repository
        self.credentials = credentials
    }

    public func fetch() throws -> GitRevision? {
        try prepare()
        var result = kg_result()
        let status = withConnection { kg_fetch(repository.path, $0, &result) }
        if status == KG_MISSING { return nil }
        try check(status, result)
        return try revision(result)
    }

    public func isAncestor(_ ancestor: GitRevision, of revision: GitRevision) throws -> Bool {
        try prepare()
        var result = kg_result()
        let status = kg_is_ancestor(repository.path, ancestor.value, revision.value, &result)
        if status == KG_NOT_ANCESTOR { return false }
        try check(status, result)
        return true
    }

    public func materialize(_ revision: GitRevision, to destination: URL) async throws {
        try prepare()
        let scratch = URL.temporaryDirectory.appending(path: "KinenGitCheckout-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: scratch) }
        var result = kg_result()
        try check(kg_checkout(repository.path, revision.value, scratch.path, &result), result)
        _ = try await LibraryBackup.restore(from: scratch, to: destination)
    }

    public func publish(snapshot: URL, basedOn expected: GitRevision?) async throws -> GitRevision {
        try await publish(snapshot: snapshot, basedOn: expected, beforePush: { _ in })
    }

    public func publish(snapshot: URL, basedOn expected: GitRevision?,
                        beforePush: @escaping @Sendable (GitRevision) throws -> Void) async throws -> GitRevision {
        try prepare()
        let verified = URL.temporaryDirectory.appending(path: "KinenGitVerified-\(UUID().uuidString)")
        defer { if files.fileExists(atPath: verified.path) { try? files.removeItem(at: verified) } }
        _ = try await LibraryBackup.restore(from: snapshot, to: verified)
        let actual = try fetch()
        guard expected == actual else { throw GitTransportError.remoteChanged(expected: expected, actual: actual) }

        var result = kg_result()
        let callback = PushJournalCallback(beforePush)
        let status = withConnection { connection in
            optionalCString(expected?.value) { old in
                kg_publish(repository.path, connection, verified.path, old, { oid, pointer in
                    guard let oid, let pointer, let revision = GitRevision(String(cString: oid)) else { return -1 }
                    let callback = Unmanaged<PushJournalCallback>.fromOpaque(pointer).takeUnretainedValue()
                    do {
                        try callback.action(revision)
                        return 0
                    } catch {
                        callback.error = error
                        return -1
                    }
                }, Unmanaged.passUnretained(callback).toOpaque(), &result)
            }
        }
        if let error = callback.error { throw error }
        if status == KG_REMOTE_CHANGED {
            let latest = try fetch()
            throw GitTransportError.remoteChanged(expected: expected, actual: latest)
        }
        try check(status, result)
        return try revision(result)
    }

    private func prepare() throws {
        try Task.checkCancellation()
        try files.createDirectory(at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func check(_ status: Int32, _ result: kg_result) throws {
        guard status != KG_OK else { return }
        if status == KG_AUTH { throw EmbeddedGitError.authentication }
        if result.has_host_hash != 0 {
            let digest = withUnsafeBytes(of: result.host_hash) { Data($0) }
            let value = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
            if let pin = try? GitSSHHostPin("SHA256:" + value) {
                if status == KG_HOST_UNTRUSTED { throw EmbeddedGitError.untrustedHost(pin) }
                if status == KG_HOST_CHANGED { throw EmbeddedGitError.changedHost(pin) }
            }
        }
        throw GitTransportError.commandFailed(status, cString(result.detail))
    }

    private func revision(_ result: kg_result) throws -> GitRevision {
        guard let revision = GitRevision(cString(result.oid)) else { throw GitTransportError.invalidRevision }
        return revision
    }

    private func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func withConnection<T>(_ body: (UnsafePointer<kg_remote>) -> T) -> T {
        let encoded = credentials?.hostPin?.fingerprint.dropFirst("SHA256:".count)
        let hash = encoded.flatMap { Data(base64Encoded: String($0) + "=") } ?? Data()
        return remote.absoluteString.withCString { address in
            branch.withCString { branch in
                optionalCString(credentials?.identity.publicKey) { publicKey in
                    optionalCString(credentials?.identity.privateKey) { privateKey in
                        optionalCString(credentials?.identity.passphrase) { passphrase in
                            hash.withUnsafeBytes { bytes in
                                let pin = hash.isEmpty ? nil : bytes.bindMemory(to: UInt8.self).baseAddress
                                var connection = kg_remote(url: address, branch: branch, public_key: publicKey,
                                                           private_key: privateKey, passphrase: passphrase, host_hash: pin)
                                return body(&connection)
                            }
                        }
                    }
                }
            }
        }
    }

    private func optionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        if let value { return value.withCString { body($0) } }
        return body(nil)
    }
}

private final class PushJournalCallback {
    let action: @Sendable (GitRevision) throws -> Void
    var error: Error?

    init(_ action: @escaping @Sendable (GitRevision) throws -> Void) { self.action = action }
}
