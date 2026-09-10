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

/// Rejections that only a running session can distinguish. Kept separate from
/// `HarnessError` so hosts can map them to their own protocol error names.
public enum QueueControlError: Error, Equatable, Sendable, CustomStringConvertible {
    case steerUnavailable
    public var description: String {
        switch self {
        case .steerUnavailable: "Steering is only available while a turn is running"
        }
    }
}
