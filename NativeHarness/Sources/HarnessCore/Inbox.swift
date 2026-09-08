import Foundation

public enum DeliveryMode: String, Codable, Sendable { case queue, steer }
public enum CommandState: String, Codable, Sendable { case pending, consumed, cancelled }
public struct PendingCommand: Codable, Sendable {
    public let id: String
    public let prompt: String
    public let mode: DeliveryMode
}
public struct CommandReceipt: Codable, Sendable {
    public let id: String
    public let state: CommandState
    public let duplicate: Bool
}
