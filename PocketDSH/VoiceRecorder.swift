import AVFoundation
import SwiftUI
import Combine

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase { case idle, permission, recording, transcribing, sending, retry }
    @Published var phase: Phase = .idle
    @Published var seconds = 0
    @Published var error: String?
    @Published var levels = Array(repeating: CGFloat(0.05), count: 22)
    var hasTranscript: Bool { transcript != nil }
    private var requestID = UUID().uuidString
    var discardRequested = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private var task: Task<Void, Never>?
    private var attempt = UUID()
    private var destination: (endpoint: String, session: String)?
    private var transcript: String?

    func start(store: PocketStore) {
        guard phase == .idle, let id = store.selectedID else { return }
        cancel(); requestID = UUID().uuidString; destination = (store.endpoint, id); phase = .permission
        let token = attempt
        task = Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard token == attempt, !Task.isCancelled else { return }
            guard allowed else { error = "Enable Microphone access for Pocket DSH in Settings."; phase = .idle; return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .default)
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
                recordingURL = url
                let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
                self.recorder = recorder; recorder.delegate = self; recorder.isMeteringEnabled = true
                guard recorder.record(forDuration: 120) else { throw HarnessError(message: "Could not start recording.") }
                phase = .recording; seconds = 0
                timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.phase == .recording, let recorder = self.recorder else { return }
                        self.seconds = Int(recorder.currentTime)
                        recorder.updateMeters()
                        let level = CGFloat(max(0.05, min(1, pow(10, recorder.averagePower(forChannel: 0) / 35))))
                        self.levels.removeFirst(); self.levels.append(level)
                    }
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            } catch { cancel(); self.error = error.localizedDescription }
        }
    }
    func stop(store: PocketStore) {
        guard phase == .recording else { if phase == .permission { cancel() }; return }
        guard !discardRequested, max(recorder?.currentTime ?? 0, Double(seconds)) >= 0.35 else { cancel(); return }
        recorder?.delegate = nil; recorder?.stop(); timer?.invalidate(); timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcribe(store: store)
    }
    private var onAutomaticStop: (() -> Void)?
    func bind(store: PocketStore) { onAutomaticStop = { [weak self, weak store] in if let store { self?.stop(store: store) } } }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.phase == .recording else { return }
            if flag { self.onAutomaticStop?() } else { self.cancel(); self.error = "Recording was interrupted. Please try again." }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.cancel(); self.error = "Recording failed. Please try again." }
    }
    func transcribe(store: PocketStore) {
        guard let url = recordingURL, let destination else { return }
        let token = attempt; phase = .transcribing; error = nil
        task = Task {
            do {
                let text: String
                if let transcript { text = transcript } else {
                    let data = try Data(contentsOf: url)
                    guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw HarnessError(message: "Recording is empty or exceeds 8 MB.") }
                    text = try await store.transcribeVoice(data, endpoint: destination.endpoint)
                }
                guard token == attempt, !Task.isCancelled else { return }
                transcript = text
                phase = .sending
                try await store.sendVoiceTranscript(text, endpoint: destination.endpoint, sessionID: destination.session, requestID: requestID)
                guard token == attempt, !Task.isCancelled else { return }
                cancel()
            } catch {
                guard token == attempt, !Task.isCancelled else { return }
                self.error = error.localizedDescription; phase = .retry
            }
        }
    }
    func cancel() {
        attempt = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil; transcript = nil; destination = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle; seconds = 0; error = nil; discardRequested = false; levels = Array(repeating: 0.05, count: 22)
    }
}

struct VoiceComposer: View {
    var compact = false
    @EnvironmentObject var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice = VoiceRecorder()
    @State private var holding = false
    @State private var gestureStarted = false
    @State private var discard = false
    @GestureState private var touching = false
    private var active: Bool { voice.phase == .recording || voice.phase == .permission }
    private var available: Bool { store.connected && store.selectedID != nil && !store.submitting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if active {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 3) {
                            ForEach(Array(voice.levels.indices.suffix(compact ? 18 : voice.levels.count)), id: \.self) { i in
                                Capsule().fill(discard ? Color.red : theme.accent)
                                    .frame(width: 3, height: max(3, 23 * voice.levels[i]))
                            }
                            Text(String(format: "%d:%02d", voice.seconds / 60, voice.seconds % 60))
                                .font(.caption.monospacedDigit()).padding(.leading, 4)
                        }.frame(height: 25).accessibilityLabel("Live microphone level").accessibilityIdentifier("voiceWaveform")
                        Text(discard ? "Release to delete" : "‹ Slide left to cancel")
                            .font(.caption2).foregroundStyle(discard ? .red : .secondary)
                    }
                } else if voice.phase == .transcribing || voice.phase == .sending {
                    ProgressView().controlSize(.small)
                    Text(voice.phase == .sending ? "Sending…" : "Transcribing…").font(.caption)
                } else if voice.phase == .retry {
                    Button(voice.hasTranscript ? "Retry sending" : "Retry transcription") { voice.transcribe(store: store) }.font(.caption)
                } else if !compact {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hold to talk").font(.caption.weight(.medium))
                        Text("Release to send").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !compact { Spacer(minLength: 0) }
                if voice.phase != .idle && voice.phase != .sending && !holding {
                    Button { voice.cancel() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                        .accessibilityLabel("Cancel voice message")
                }
                microphone
            }
            if let error = voice.error { Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("voiceError") }
        }.onAppear { voice.bind(store: store) }
            .onDisappear { reset() }
            .onChange(of: active) { _, recording in store.voiceRecording = recording }
        .onChange(of: store.selectedID) { _, _ in reset() }
            .onChange(of: store.endpoint) { _, _ in reset() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { reset() } }
            .onChange(of: touching) { _, down in
                if !down { Task { @MainActor in
                    await Task.yield()
                    if holding { reset() }
                } }
            }
            .onChange(of: voice.phase) { _, phase in
                if phase == .transcribing || phase == .idle { holding = false; discard = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began,
                      voice.phase == .recording else { return }
                reset(); voice.error = "Recording was interrupted. Please try again."
            }
    }
    private var microphone: some View {
        Image(systemName: discard ? "trash.fill" : "mic.fill")
            .font(.system(size: compact ? 16 : 19, weight: .semibold))
            .foregroundStyle(holding ? theme.canvas : theme.accent)
            .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
            .background(holding ? (discard ? Color.red : theme.accent) : theme.accent.opacity(0.12), in: Circle())
            .contentShape(Circle())
            .accessibilityElement().accessibilityAddTraits(.isButton)
            .accessibilityLabel(active ? "Finish voice message" : "Hold to record")
            .accessibilityHint("Hold to record. Release to send. Slide left to cancel. With VoiceOver, activate to start or finish.")
            .accessibilityIdentifier("voiceRecord")
            .accessibilityAction {
                if active { voice.stop(store: store) }
                else if voice.phase == .idle && available { voice.start(store: store) }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if !gestureStarted {
                        gestureStarted = true
                        guard voice.phase == .idle, available else { return }
                        holding = true; discard = false; voice.start(store: store)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    guard holding else { return }
                    if value.translation.width < -65 && !discard {
                        discard = true; voice.discardRequested = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
                .onEnded { _ in
                    gestureStarted = false
                    guard holding else { return }; holding = false
                    if discard { voice.cancel() } else { voice.stop(store: store) }
                    discard = false
                })
            .opacity(available || active ? 1 : 0.4)
    }
    private func reset() { holding = false; gestureStarted = false; discard = false; voice.cancel() }
}
