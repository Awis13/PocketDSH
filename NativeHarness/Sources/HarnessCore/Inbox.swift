import Foundation
import CryptoKit

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

/// The queue controls that carry a durable idempotency receipt. The read-only
/// `text` fetch is deliberately absent: it mutates nothing and is never stored.
public enum QueueControlAction: String, Codable, Sendable, Equatable, CaseIterable {
    case edit, remove, steer
}

/// Rejections a queue control can durably record. The raw values are the wire
/// codes the client already renders, so a replayed receipt stays wire-neutral.
public enum QueueControlRejection: String, Codable, Sendable, Equatable {
    case itemNotFound = "queue-item-not-found"
    case steerUnavailable = "steer-unavailable"
}

/// A persisted queue-control result. Only this short outcome is stored, never
/// the edit prompt, so the durable table cannot leak conversation text.
public enum QueueControlOutcome: Codable, Sendable, Equatable {
    case accepted
    case rejected(QueueControlRejection)

    public var rejection: QueueControlRejection? {
        guard case .rejected(let code) = self else { return nil }
        return code
    }
    public var durableValue: String {
        switch self {
        case .accepted: "accepted"
        case .rejected(let code): "rejected:" + code.rawValue
        }
    }
    public init?(durableValue: String) {
        if durableValue == "accepted" { self = .accepted; return }
        let prefix = "rejected:"
        guard durableValue.hasPrefix(prefix),
              let code = QueueControlRejection(rawValue: String(durableValue.dropFirst(prefix.count))) else { return nil }
        self = .rejected(code)
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let parsed = QueueControlOutcome(durableValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown queue control outcome")
        }
        self = parsed
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(durableValue)
    }
}

public struct QueueControlReceipt: Codable, Sendable, Equatable {
    public let requestID: String
    public let outcome: QueueControlOutcome
    public init(requestID: String, outcome: QueueControlOutcome) {
        self.requestID = requestID; self.outcome = outcome
    }
}

/// Whether this call applied the control or returned an already-persisted
/// receipt. Both carry the same wire event; the distinction only governs
/// one-time transcript reconciliation on the host.
public enum QueueControlResult: Sendable, Equatable {
    case fresh(QueueControlReceipt)
    case replayed(QueueControlReceipt)

    public var receipt: QueueControlReceipt {
        switch self {
        case .fresh(let receipt), .replayed(let receipt): return receipt
        }
    }
    public var replayed: Bool { if case .replayed = self { return true }; return false }
}

/// Canonical identity for one queue-control request. Every field is length
/// framed, so a delimiter inside a value cannot forge a field boundary, and the
/// digest is what reaches storage: an edit prompt is never persisted in clear.
public enum QueueControlFingerprint {
    public static func digest(action: QueueControlAction, itemID: String, text: String?) -> String {
        var payload = frame("nh.queue-control.receipt.v1")
        payload.append(frame(action.rawValue))
        payload.append(frame(itemID))
        if action == .edit, let text {
            payload.append(contentsOf: [1])
            payload.append(frame(text))
        } else {
            payload.append(contentsOf: [0])
        }
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func frame(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        var data = Data()
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
        return data
    }

    /// A persisted fingerprint must be exactly the digest representation: 64
    /// lowercase hexadecimal ASCII characters. Anything else is corruption, not
    /// a client conflict, so a caller can refuse it as a storage error.
    public static func isCanonical(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

/// Rejections that only a running session can distinguish. Kept separate from
/// HarnessError so hosts can map them to their own protocol error names.
public enum QueueControlError: Error, Equatable, Sendable, CustomStringConvertible {
    case steerUnavailable
    public var description: String {
        switch self {
        case .steerUnavailable: "Steering is only available while a turn is running"
        }
    }
}
