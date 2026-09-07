import Foundation

// Explicit opt-in: changes the host default through DSH's selectModel endpoint.
@main struct LiveModelCheck {
 @MainActor static func main() async throws {
  let env = ProcessInfo.processInfo.environment
  guard let path = env["DSH_LIVE_LOG"], let provider = env["DSH_TARGET_PROVIDER"], let model = env["DSH_TARGET_MODEL"] else { fatalError("Set DSH_LIVE_LOG, DSH_TARGET_PROVIDER and DSH_TARGET_MODEL to opt in") }
  let log = try String(contentsOfFile: path, encoding: .utf8)
  let input = String(log.components(separatedBy: .newlines).first { $0.hasPrefix("dsh web: ") }!.dropFirst(9))
  let store = PocketStore()
  await store.connect(input: input)
  for _ in 0..<150 { if store.connected { break }; try await Task.sleep(for: .milliseconds(100)) }
  guard store.connected else { throw HarnessError(message: store.error ?? "Not connected") }
  await store.create(workspaceID: nil)
  guard let id = store.selectedID else { throw HarnessError(message: "No session") }
  let (base, _) = try HarnessAPI.parse(input), api = HarnessAPI(base: base)
  _ = try await api.rpc("session/rename", args: ["request": .object(["sessionId": .string(id), "title": .string("Model selection check")])])
  await store.selectModel(provider: provider, model: model)
  for _ in 0..<100 { if !store.loadingHistory { break }; try await Task.sleep(for: .milliseconds(100)) }
  guard store.model["provider"].string == provider, store.model["model"].string == model, store.catalog["default"]["model"].string == model else { throw HarnessError(message: store.error ?? "Model or default mismatch") }
  store.disconnect(); await store.connect()
  for _ in 0..<150 { if store.connected && !store.loadingHistory { break }; try await Task.sleep(for: .milliseconds(100)) }
  guard store.model["model"].string == model, store.catalog["default"]["model"].string == model else { throw HarnessError(message: "Reconnection reset model") }
  // The prior image-only test has no explicit model selection: leave its history untouched.
  await store.select(nil)
  guard store.model["model"].string == model else { throw HarnessError(message: "New task fallback uses stale catalog") }
  let freshCatalog = try await api.rpc("session/modelCatalog")
  guard freshCatalog["default"]["provider"].string == provider, freshCatalog["default"]["model"].string == model else { throw HarnessError(message: "Host default did not persist") }
  store.disconnect()
  print("PASS: accepted selection, refreshed default, session reconnect, unconfigured task fallback and independent host read: \(provider)/\(model)")
 }
}
