import Foundation
import Darwin

public struct DiagnosticReport: Codable, Sendable {
    public let schemaVersion: Int
    public let engineVersion: String
    public let operatingSystem: String
    public let processID: Int32
    public var updatedAt: Date
    public var events: [DiagnosticEvent]
    public var droppedEvents: Int
    public var requests: [RequestTiming]?
}

/// Replaces a bounded snapshot atomically. This is disposable diagnostics, not
/// the durable session journal. Refuses to overwrite a preexisting report.
public final class DiagnosticArchive: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var report: DiagnosticReport
    public init(url: URL) throws {
        self.url = url
        self.report = DiagnosticReport(schemaVersion: 1, engineVersion: "0.3-dev",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processID: ProcessInfo.processInfo.processIdentifier, updatedAt: Date(), events: [], droppedEvents: 0, requests: [])
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HarnessError.invalid("Diagnostic path must be a new file in an existing directory") }
        Darwin.close(fd)
        try publish()
    }
    public func append(_ event: DiagnosticEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if report.events.count == 256 { report.events.removeFirst(); report.droppedEvents += 1 }
        report.events.append(event); report.updatedAt = Date()
        report.requests = RequestTiming.summarize(report.events)
        try publish()
    }
    private func publish() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".trace-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HarnessError.storage("Cannot write diagnostic snapshot") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw HarnessError.storage("Cannot publish diagnostic snapshot") }
    }
    public static func read(url: URL) throws -> DiagnosticReport {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw HarnessError.invalid("Diagnostic report exceeds 1 MiB") }
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        guard report.schemaVersion == 1 else { throw HarnessError.invalid("Unsupported diagnostic schema") }
        return report
    }
}
