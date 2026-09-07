import Foundation

// Explicit opt-in integration check. Creates one named session and sends one harmless prompt.
@main struct LiveHarnessCheck {
 @MainActor static func main() async throws {
  let path = ProcessInfo.processInfo.environment["DSH_LIVE_LOG"] ?? ""
  guard !path.isEmpty else { fatalError("Set DSH_LIVE_LOG to opt in") }
  let log = try String(contentsOfFile: path, encoding: .utf8)
  let line = log.components(separatedBy: .newlines).first { $0.hasPrefix("dsh web: ") }!
  let input = String(line.dropFirst(9))
  let store = PocketStore()
  await store.connect(input: input)
  for _ in 0..<100 { if store.connected { break }; try await Task.sleep(nanoseconds: 100_000_000) }
  guard store.connected else { throw HarnessError(message: store.error ?? "Not connected") }
  print("CONNECTED sessions=\(store.sessions.count) workspaces=\(store.workspaces.count)")
  await store.create(workspaceID: nil)
  guard let id = store.selectedID else { throw HarnessError(message: store.error ?? "Create failed") }
  let (base, _) = try HarnessAPI.parse(input), api = HarnessAPI(base: base)
  _ = try await api.rpc("session/rename", args:["request":.object(["sessionId":.string(id),"title":.string("Pocket DSH · client check")])])
  try id.write(toFile:"/tmp/pocket-dsh-live-session-id", atomically:true, encoding:.utf8)
  store.draft = "Reply exactly POCKET_OK. This is a mobile client connection test. Do not use tools or change any files."
  await store.submit()
  guard store.draft.isEmpty else { throw HarnessError(message: store.error ?? "Prompt failed") }
  for _ in 0..<1200 {
   if store.rows.contains(where: { $0.kind == .assistant && $0.complete && $0.text.contains("POCKET_OK") }) { break }
   try await Task.sleep(nanoseconds: 100_000_000)
  }
  guard store.rows.contains(where: { $0.kind == .assistant && $0.complete && $0.text.contains("POCKET_OK") }) else { throw HarnessError(message: store.error ?? "No final reply") }
  let before = store.rows.filter { $0.kind == .user }.count
  store.disconnect(); await store.connect()
  for _ in 0..<100 { if store.connected && !store.loadingHistory && store.rows.contains(where: { $0.kind == .assistant }) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
  guard store.connected, store.rows.filter({ $0.kind == .user }).count == before else { throw HarnessError(message: "Reconnect history mismatch") }
  store.disconnect()
  print("PASS create, prompt admission, streamed final reply, reconnect and transcript reconciliation; session=\(id)")
 }
}
