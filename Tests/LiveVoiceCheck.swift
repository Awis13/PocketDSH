import Foundation

@main struct LiveVoiceCheck {
    @MainActor static func main() async throws {
        guard let logPath = ProcessInfo.processInfo.environment["DSH_LIVE_LOG"], let audioPath = ProcessInfo.processInfo.environment["DSH_VOICE_AUDIO"] else { fatalError("Set DSH_LIVE_LOG and DSH_VOICE_AUDIO to opt in") }
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: "http://127\\.0\\.0\\.1:3080/\\?token=[^\\s\\u001b]+")
        guard let match = expression.matches(in: log, range: NSRange(log.startIndex..., in: log)).last, let range = Range(match.range, in: log) else { throw HarnessError(message: "No current launch URL") }
        let (base, token) = try HarnessAPI.parse(String(log[range]))
        let api = HarnessAPI(base: base); try await api.login(token: token!)
        let text = try await api.transcribeVoice(Data(contentsOf: URL(fileURLWithPath: audioPath)))
        guard text.lowercased().contains("latest changes") else { throw HarnessError(message: "Unexpected transcription: \(text)") }
        print("PASS native URLSession authentication, M4A audio upload, Whisper transcript decoding")
    }
}
