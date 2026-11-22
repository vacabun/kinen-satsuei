#if os(macOS)
import Foundation
import KinenCore
import XCTest

final class EmbeddedGitTransportTests: XCTestCase {
    func testSSHWithExplicitHostPinAndInMemoryKey() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["KINEN_TEST_SSH_URL"], let url = URL(string: rawURL),
              let keyFolder = environment["KINEN_TEST_SSH_KEY_FOLDER"] else {
            throw XCTSkip("Loopback SSH fixture is opt-in")
        }
        let folder = URL(fileURLWithPath: keyFolder)
        let privateKey = try String(contentsOf: folder.appending(path: "client"), encoding: .utf8)
        let publicKey = try String(contentsOf: folder.appending(path: "client.pub"), encoding: .utf8)
        let hostKey = try String(contentsOf: folder.appending(path: "host.pub"), encoding: .utf8)
        let blob = try XCTUnwrap(hostKey.split(whereSeparator: \.isWhitespace).dropFirst().first)
        let pin = GitSSHHostPin(hostKey: try XCTUnwrap(Data(base64Encoded: String(blob))))
        let identity = try GitSSHIdentity(publicKey: publicKey, privateKey: privateKey)
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let repository = root.appending(path: "client.git")
        let unknown = try EmbeddedGitTransport(remote: url, branch: "main", repository: repository,
                                               credentials: GitSSHCredentials(identity: identity, hostPin: nil))
        do {
            _ = try await unknown.fetch()
            XCTFail("A host without a pin must be rejected before authentication")
        } catch EmbeddedGitError.untrustedHost(let reported) {
            XCTAssertEqual(reported, pin)
        }

        let wrong = try EmbeddedGitTransport(remote: url, branch: "main", repository: repository,
                                             credentials: GitSSHCredentials(identity: identity,
                                                                             hostPin: GitSSHHostPin(hostKey: Data())))
        do {
            _ = try await wrong.fetch()
            XCTFail("An unexpected host key must be rejected")
        } catch EmbeddedGitError.changedHost(let reported) {
            XCTAssertEqual(reported, pin)
        }

        let trusted = try EmbeddedGitTransport(remote: url, branch: "main", repository: repository,
                                               credentials: GitSSHCredentials(identity: identity, hostPin: pin))
        let initial = try await trusted.fetch()
        XCTAssertNil(initial)
        let store = LibraryStore(root: root.appending(path: "library"))
        try await store.save(LibraryEntry(title: "SSH", body: "公钥验证"))
        let snapshot = root.appending(path: "snapshot")
        _ = try await store.exportBackup(to: snapshot)
        let revision = try await trusted.publish(snapshot: snapshot, basedOn: initial)
        let fetched = try await trusted.fetch()
        XCTAssertEqual(revision, fetched)
    }

    func testEmbeddedTransportRoundTripsLibraryAndRejectsStaleBase() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        setup.arguments = ["init", "--bare", "--template=", remote.path]
        setup.standardOutput = FileHandle.nullDevice
        setup.standardError = FileHandle.nullDevice
        try setup.run()
        setup.waitUntilExit()
        XCTAssertEqual(setup.terminationStatus, 0)

        let a = try EmbeddedGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"),
                                         credentials: nil)
        let b = try EmbeddedGitTransport(remote: remote, branch: "main", repository: root.appending(path: "b.git"),
                                         credentials: nil)
        let store = LibraryStore(root: root.appending(path: "library"))
        var note = LibraryEntry(title: "旅行", body: "初稿")
        try await store.save(note)
        let backup = root.appending(path: "backup")
        _ = try await store.exportBackup(to: backup)
        let empty = try await a.fetch()
        XCTAssertNil(empty)
        let first = try await a.publish(snapshot: backup, basedOn: nil)
        let observed = try await b.fetch()
        XCTAssertEqual(observed, first)

        let retrieved = root.appending(path: "retrieved")
        try await b.materialize(first, to: retrieved)
        let retrievedEntries = try await LibraryStore(root: retrieved).load().entries
        XCTAssertEqual(retrievedEntries.first?.body, note.body)
        let unchanged = try await b.publish(snapshot: retrieved, basedOn: first)
        XCTAssertEqual(unchanged, first)

        note.body = "第二次"
        try await store.save(note)
        let update = root.appending(path: "update")
        _ = try await store.exportBackup(to: update)
        let second = try await b.publish(snapshot: update, basedOn: first)
        let descended = try await b.isAncestor(first, of: second)
        XCTAssertTrue(descended)
        do {
            _ = try await a.publish(snapshot: backup, basedOn: first)
            XCTFail("A stale push must be rejected")
        } catch GitTransportError.remoteChanged(let expected, let actual) {
            XCTAssertEqual(expected, first)
            XCTAssertEqual(actual, second)
        }
    }
}
#endif
