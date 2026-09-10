import Foundation

public enum SSEError: Error, Equatable {
    case lineTooLong
    case eventTooLong
    case invalidUTF8
}

public struct SSEDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var dataLines: [String] = []
    private var eventBytes: Int = 0
    private var suppressLF = false

    public init() {}

    public mutating func feed(_ byte: UInt8) throws -> [String] {
        if suppressLF {
            suppressLF = false
            if byte == 0x0A { return [] }
        }

        if byte == 0x0D {
            suppressLF = true
            return try processLine()
        }
        if byte == 0x0A {
            return try processLine()
        }

        buffer.append(byte)
        if buffer.count > 1048576 { throw SSEError.lineTooLong }
        return []
    }

    public mutating func finish() throws -> [String] {
        defer {
            buffer.removeAll(keepingCapacity: true)
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            suppressLF = false
        }
        if !buffer.isEmpty {
            let bytes = buffer
            guard let _ = String(bytes: bytes, encoding: .utf8) else {
                throw SSEError.invalidUTF8
            }
            buffer.removeAll(keepingCapacity: true)
        }
        return []
    }

    private mutating func processLine() throws -> [String] {
        let bytes = buffer
        buffer.removeAll(keepingCapacity: true)

        guard let str = String(bytes: bytes, encoding: .utf8) else {
            throw SSEError.invalidUTF8
        }

        if str == "data" || str.hasPrefix("data:") {
            var value = str == "data" ? "" : String(str.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
            eventBytes += bytes.count + 1
        } else if str.hasPrefix("event:") || str.hasPrefix("id:") || str.hasPrefix("retry:") {
            eventBytes += bytes.count + 1
        }

        if eventBytes > 1048576 { throw SSEError.eventTooLong }

        if str.isEmpty {
            let result: [String]
            if !dataLines.isEmpty {
                result = [dataLines.joined(separator: "\n")]
            } else {
                result = []
            }
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            return result
        }
        return []
    }
}
