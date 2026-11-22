import Foundation

public struct GitRevision: Hashable, Codable, Sendable {
    public let value: String

    public init?(_ value: String) {
        guard value.count == 40 || value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let revision = Self(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Git revision")
        }
        self = revision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public protocol GitTransport: Sendable {
    func fetch() async throws -> GitRevision?
    func materialize(_ revision: GitRevision, to destination: URL) async throws
    func isAncestor(_ ancestor: GitRevision, of revision: GitRevision) async throws -> Bool
    func publish(snapshot: URL, basedOn expected: GitRevision?) async throws -> GitRevision
}

public protocol JournaledGitTransport: GitTransport {
    func publish(snapshot: URL, basedOn expected: GitRevision?,
                 beforePush: @escaping @Sendable (GitRevision) throws -> Void) async throws -> GitRevision
}

public enum GitTransportError: Error, LocalizedError {
    case invalidRemote, invalidBranch, invalidRevision, invalidSnapshot
    case remoteChanged(expected: GitRevision?, actual: GitRevision?)
    case commandFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidRemote: "请输入有效的 SSH 仓库地址。"
        case .invalidBranch: "请输入有效的 Git 分支名。"
        case .invalidRevision: "Git 返回了无法识别的提交。"
        case .invalidSnapshot: "资料库快照无效。"
        case .remoteChanged: "远程分支已更新，请重新获取后再同步。"
        case .commandFailed(_, let detail): detail.isEmpty ? "Git 命令执行失败。" : detail
        }
    }
}
