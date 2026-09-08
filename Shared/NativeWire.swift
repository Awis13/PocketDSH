import Foundation

struct NativeCommand: Codable, Sendable {
    var op: String
    var session: String?
    var id: String?
    var text: String?
    var bytes: Data?
    var rows: Int?
    var columns: Int?
    var allow: Bool?
    var withTerminal: Bool?
    var completionKind: String?
}
struct NativeChat: Codable, Sendable, Identifiable {
    var id: String
    var role: String
    var text: String
}
struct NativeApproval: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var workspace: String
}
struct NativeSessionInfo: Codable, Sendable {
    var id: String
    var title: String
    var workspace: String
    var model: String
    var running: Bool
    var updatedAt: Double
}
struct NativeEvent: Codable, Sendable {
    var op: String
    var session: String?
    var id: String?
    var text: String?
    var bytes: Data?
    var stage: String?
    var model: String?
    var workspace: String?
    var ptyID: String?
    var chats: [NativeChat]?
    var approval: NativeApproval?
    var running: Bool?
    var gap: Bool?
    var sequence: Int?
    var exitCode: Int?
    var arguments: String?
    var failed: Bool?
    var sessions: [NativeSessionInfo]?
    var rows: Int?
    var columns: Int?
    var candidates: [String]?
    var limited: Bool?
}
