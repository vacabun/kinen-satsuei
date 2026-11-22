import Foundation
import KinenCore
import XCTest

final class GitSSHIdentityTests: XCTestCase {
    func testNormalizesAndRejectsInvalidHostFingerprints() throws {
        let pin = GitSSHHostPin(hostKey: Data())
        XCTAssertEqual(pin.fingerprint, "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
        XCTAssertEqual(try GitSSHHostPin(pin.fingerprint + "="), pin)
        XCTAssertThrowsError(try GitSSHHostPin("SHA256:invalid"))
        XCTAssertThrowsError(try GitSSHHostPin("MD5:00"))
    }

    #if os(macOS)
    func testGeneratedIdentityCanBeReadByOpenSSH() throws {
        let identity = try GitSSHIdentity.generate()
        let workspace = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: workspace.path) { try? FileManager.default.removeItem(at: workspace) } }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let key = workspace.appending(path: "private")
        XCTAssertTrue(FileManager.default.createFile(atPath: key.path, contents: Data(identity.privateKey.utf8),
                                                     attributes: [.posixPermissions: 0o600]))

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", key.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let generatedFields = identity.publicKey.split(whereSeparator: \.isWhitespace).prefix(2)
        let actualFields = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).prefix(2)
        XCTAssertEqual(actualFields, generatedFields)
        XCTAssertThrowsError(try GitSSHIdentity(publicKey: "ssh-ed25519 aA==", privateKey: identity.privateKey))
        let another = try GitSSHIdentity.generate()
        XCTAssertThrowsError(try GitSSHIdentity(publicKey: another.publicKey, privateKey: identity.privateKey))
    }
    #endif
}
