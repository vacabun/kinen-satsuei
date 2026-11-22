import CryptoKit
import Foundation
import Security

public struct GitSSHIdentity: Codable, Sendable {
    public let publicKey: String
    public let privateKey: String
    public let passphrase: String?

    public init(publicKey: String, privateKey: String, passphrase: String? = nil) throws {
        let line = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(whereSeparator: \.isWhitespace)
        let pem = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let publicBlob = Self.publicBlob(fields),
              Self.privateKeyPublicBlob(pem) == publicBlob,
              !pem.utf8.contains(0), passphrase?.utf8.contains(0) != true else {
            throw GitSSHError.invalidIdentity
        }
        self.publicKey = line
        self.privateKey = pem + "\n"
        self.passphrase = passphrase?.isEmpty == false ? passphrase : nil
    }

    public static func generate() throws -> GitSSHIdentity {
        let key = Curve25519.Signing.PrivateKey()
        let kind = Data("ssh-ed25519".utf8)
        let name = Data("kinensatsuei".utf8)
        var publicBlob = SSHWire()
        publicBlob.appendField(kind)
        publicBlob.appendField(key.publicKey.rawRepresentation)

        var secretBlob = SSHWire()
        let check = UInt32.random(in: .min ... .max)
        secretBlob.appendInteger(check)
        secretBlob.appendInteger(check)
        secretBlob.appendField(kind)
        secretBlob.appendField(key.publicKey.rawRepresentation)
        secretBlob.appendField(key.rawRepresentation + key.publicKey.rawRepresentation)
        secretBlob.appendField(name)
        let padding = 8 - secretBlob.data.count % 8
        secretBlob.data.append(contentsOf: (1...padding).map(UInt8.init))

        var file = SSHWire()
        file.data.append(Data("openssh-key-v1\0".utf8))
        file.appendField(Data("none".utf8))
        file.appendField(Data("none".utf8))
        file.appendField(Data())
        file.appendInteger(1)
        file.appendField(publicBlob.data)
        file.appendField(secretBlob.data)

        let encoded = file.data.base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 70).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            return String(encoded[start...].prefix(70))
        }
        return try GitSSHIdentity(
            publicKey: "ssh-ed25519 \(publicBlob.data.base64EncodedString()) kinensatsuei",
            privateKey: (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"]).joined(separator: "\n")
        )
    }

    private static func publicBlob(_ fields: [Substring]) -> Data? {
        guard fields.count >= 2, fields[0] == "ssh-ed25519",
              let data = Data(base64Encoded: String(fields[1])) else { return nil }
        let kind = Data("ssh-ed25519".utf8)
        var prefix = SSHWire()
        prefix.appendField(kind)
        prefix.appendInteger(32)
        return data.starts(with: prefix.data) && data.count == prefix.data.count + 32 ? data : nil
    }

    private static func privateKeyPublicBlob(_ pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline)
        guard lines.count >= 3, lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let decoded = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else { return nil }
        let signature = Data("openssh-key-v1\0".utf8)
        guard decoded.starts(with: signature) else { return nil }
        var reader = SSHReader(bytes: decoded, offset: signature.count)
        guard let cipher = reader.field(), !cipher.isEmpty,
              let kdf = reader.field(), !kdf.isEmpty, reader.field() != nil,
              reader.integer() == 1, let publicBlob = reader.field(),
              let key = reader.field(), !key.isEmpty, reader.offset == decoded.count else { return nil }
        return publicBlob
    }
}

private struct SSHReader {
    let bytes: Data
    var offset: Int

    mutating func integer() -> Int? {
        guard bytes.count - offset >= 4 else { return nil }
        let limit = offset + 4
        let value = bytes[offset..<limit].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset = limit
        return Int(value)
    }

    mutating func field() -> Data? {
        guard let size = integer(), size <= bytes.count - offset else { return nil }
        let limit = offset + size
        let field = Data(bytes[offset..<limit])
        offset = limit
        return field
    }
}

private struct SSHWire {
    var data = Data()

    mutating func appendInteger(_ value: UInt32) {
        var order = value.bigEndian
        withUnsafeBytes(of: &order) { data.append(contentsOf: $0) }
    }

    mutating func appendField(_ value: Data) {
        appendInteger(UInt32(value.count))
        data.append(value)
    }
}

public struct GitSSHHostPin: Codable, Hashable, Sendable {
    public let fingerprint: String

    public init(_ fingerprint: String) throws {
        let text = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("SHA256:") else { throw GitSSHError.invalidFingerprint }
        let raw = String(text.dropFirst("SHA256:".count))
        let unpadded = raw.hasSuffix("=") ? String(raw.dropLast()) : raw
        guard unpadded.count == 43,
              let digest = Data(base64Encoded: unpadded + "="), digest.count == 32,
              digest.base64EncodedString() == unpadded + "=" else { throw GitSSHError.invalidFingerprint }
        self.fingerprint = "SHA256:" + unpadded
    }

    public init(hostKey: Data) {
        let digest = Data(SHA256.hash(data: hostKey)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        fingerprint = "SHA256:" + digest
    }
}

public enum GitSSHError: Error, LocalizedError {
    case invalidIdentity, invalidFingerprint, credentialStore(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "请选择配对的 OpenSSH Ed25519 公钥与私钥。"
        case .invalidFingerprint: "SSH 主机指纹应为 SHA256 格式。"
        case .credentialStore(let status): "无法访问系统钥匙串（\(status)）。"
        }
    }
}

public struct GitSSHCredentials: Codable, Sendable {
    public let identity: GitSSHIdentity
    public let hostPin: GitSSHHostPin?

    public init(identity: GitSSHIdentity, hostPin: GitSSHHostPin?) {
        self.identity = identity
        self.hostPin = hostPin
    }
}

public struct GitSSHCredentialStore: Sendable {
    private let service: String

    public init(service: String = "com.vacabun.kinensatsuei.git-ssh") {
        self.service = service
    }

    public func load(for connectionID: String) throws -> GitSSHCredentials? {
        var query = baseQuery(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw GitSSHError.credentialStore(status) }
        return try JSONDecoder().decode(GitSSHCredentials.self, from: data)
    }

    public func save(_ credentials: GitSSHCredentials, for connectionID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(connectionID)
        let fields = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, fields)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GitSSHError.credentialStore(status) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(item as CFDictionary, nil)
        if inserted == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, fields)
            guard retry == errSecSuccess else { throw GitSSHError.credentialStore(retry) }
        } else if inserted != errSecSuccess {
            throw GitSSHError.credentialStore(inserted)
        }
    }

    public func remove(for connectionID: String) throws {
        let status = SecItemDelete(baseQuery(connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitSSHError.credentialStore(status) }
    }

    private func baseQuery(_ connectionID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
            kSecAttrSynchronizable as String: false
        ]
    }
}
