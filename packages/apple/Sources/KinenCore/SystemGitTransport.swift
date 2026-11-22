#if os(macOS)
import Foundation

public actor SystemGitTransport: JournaledGitTransport {
    private let remote: URL
    private let branch: String
    private let repository: URL
    private let files = FileManager.default

    private var remoteRef: String { "refs/heads/\(branch)" }

    public init(remote: URL, branch: String, repository: URL) throws {
        if !remote.isFileURL {
            guard remote.scheme?.lowercased() == "ssh", let host = remote.host, !host.isEmpty,
                  remote.password == nil, remote.query == nil, remote.fragment == nil,
                  !remote.path.isEmpty else { throw GitTransportError.invalidRemote }
        }
        self.remote = remote
        self.branch = branch
        self.repository = repository
    }

    public func fetch() throws -> GitRevision? {
        try prepare()
        let result = try run(["ls-remote", "--exit-code", "--heads", remote.absoluteString, remoteRef],
                             accepted: [0, 2])
        guard result.status == 0 else { return nil }
        _ = try run(["fetch", "--no-tags", "--no-recurse-submodules", remote.absoluteString, remoteRef])
        return try revision(run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"]).output)
    }

    public func isAncestor(_ ancestor: GitRevision, of revision: GitRevision) throws -> Bool {
        try prepare()
        return try run(["merge-base", "--is-ancestor", ancestor.value, revision.value],
                       accepted: [0, 1]).status == 0
    }

    public func materialize(_ revision: GitRevision, to destination: URL) async throws {
        try prepare()
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appending(path: ".kinen-git-tree-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: temporary) }
        try withIndex { index in
            _ = try run(["read-tree", revision.value], index: index)
            _ = try run(["--work-tree", temporary.path, "checkout-index", "--all", "--prefix=\(temporary.path)/"], index: index)
        }
        // The same validation is used for File app backups and fetched trees.
        _ = try await LibraryBackup.restore(from: temporary, to: destination)
    }

    public func publish(snapshot: URL, basedOn expected: GitRevision?) async throws -> GitRevision {
        try await publish(snapshot: snapshot, basedOn: expected, beforePush: { _ in })
    }

    public func publish(snapshot: URL, basedOn expected: GitRevision?,
                        beforePush: @escaping @Sendable (GitRevision) throws -> Void) async throws -> GitRevision {
        let verified = URL.temporaryDirectory.appending(path: "KinenGitSnapshot-\(UUID().uuidString)")
        defer { try? files.removeItem(at: verified) }
        _ = try await LibraryBackup.restore(from: snapshot, to: verified)
        let actual = try fetch()
        guard actual == expected else { throw GitTransportError.remoteChanged(expected: expected, actual: actual) }
        let roots = ["library.json", "members", "groups", "entries", "media", "assets"]
        let present = roots.filter { files.fileExists(atPath: verified.appending(path: $0).path) }
        guard present.contains("library.json") else { throw GitTransportError.invalidSnapshot }

        let tree = try withIndex { index in
            _ = try run(["read-tree", "--empty"], index: index)
            _ = try run(["--work-tree", verified.path, "add", "--all", "--force", "--"] + present,
                        index: index)
            return try revision(run(["write-tree"], index: index).output)
        }
        if let expected, try revision(run(["rev-parse", "\(expected.value)^{tree}"]).output) == tree {
            try beforePush(expected)
            return expected
        }
        var args = ["-c", "user.name=記念撮影", "-c", "user.email=kinensatsuei@localhost",
                    "commit-tree", tree.value, "-m", "Sync 記念撮影 library"]
        if let expected { args += ["-p", expected.value] }
        let desired = try revision(run(args).output)
        _ = try run(["update-ref", "refs/kinen/proposed", desired.value])
        try beforePush(desired)
        do {
            _ = try run(["push", "--porcelain", remote.absoluteString, "\(desired.value):\(remoteRef)"])
        } catch {
            let pushError = error
            let latest: GitRevision?
            do { latest = try fetch() }
            catch { throw pushError }
            if latest == desired { return desired }
            if latest != actual { throw GitTransportError.remoteChanged(expected: actual, actual: latest) }
            throw pushError
        }
        return desired
    }

    private func prepare() throws {
        let check = try run(["check-ref-format", remoteRef], inRepository: false, accepted: [0, 1])
        guard check.status == 0 else { throw GitTransportError.invalidBranch }
        if !files.fileExists(atPath: repository.appending(path: "HEAD").path) {
            try files.createDirectory(at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try run(["init", "--bare", "--template=", repository.path], inRepository: false)
        }
    }

    private func withIndex<Value>(_ operation: (URL) throws -> Value) throws -> Value {
        let index = repository.appending(path: "kinen-index-\(UUID().uuidString)")
        defer {
            for path in [index, index.appendingPathExtension("lock")] where files.fileExists(atPath: path.path) {
                try? files.removeItem(at: path)
            }
        }
        return try operation(index)
    }

    private func revision(_ string: String) throws -> GitRevision {
        guard let value = GitRevision(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitTransportError.invalidRevision
        }
        return value
    }

    private func run(_ args: [String], inRepository: Bool = true, index: URL? = nil,
                     accepted: Set<Int32> = [0]) throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        let scratch = URL.temporaryDirectory.appending(path: "KinenGit-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: scratch) }
        let stdout = scratch.appending(path: "out")
        let stderr = scratch.appending(path: "err")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = scratch
        var config = ["-c", "core.hooksPath=/dev/null", "-c", "core.protectHFS=true",
                      "-c", "core.protectNTFS=true", "-c", "protocol.allow=never",
                      "-c", "protocol.ssh.allow=always", "-c", "protocol.file.allow=always",
                      "-c", "transfer.fsckObjects=true"]
        if inRepository { config += ["--git-dir", repository.path] }
        process.arguments = config + args
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15"
        environment["LC_ALL"] = "C"
        if let index { environment["GIT_INDEX_FILE"] = index.path }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        try Task.checkCancellation()
        if !accepted.contains(process.terminationStatus) {
            throw GitTransportError.commandFailed(process.terminationStatus,
                                                   try readOutput(stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (process.terminationStatus, try readOutput(stdout))
    }

    private func readOutput(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8_192) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
