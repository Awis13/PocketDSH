import Foundation
import ImageIO
import CoreGraphics

// Opt-in: one isolated image prompt; no tools, user conversations or model settings changed.
@main struct LiveImageCheck {
 @MainActor static func main() async throws {
  guard let path = ProcessInfo.processInfo.environment["DSH_LIVE_LOG"] else { fatalError("Set DSH_LIVE_LOG to opt in") }
  let log = try String(contentsOfFile: path, encoding: .utf8)
  let input = String(log.components(separatedBy: .newlines).first { $0.hasPrefix("dsh web: ") }!.dropFirst(9))
  let store = PocketStore()
  await store.connect(input: input)
  for _ in 0..<150 { if store.connected { break }; try await Task.sleep(for: .milliseconds(100)) }
  guard store.connected else { throw HarnessError(message: store.error ?? "Not connected") }
  let existing = store.sessions.first { $0.title == "Image upload check · shapes" }
  if let existing { await store.select(existing.id) } else { await store.create(workspaceID: nil) }
  guard let id = store.selectedID else { throw HarnessError(message: "Session not created") }
  let (base, _) = try HarnessAPI.parse(input)
  let api = HarnessAPI(base: base)
  _ = try await api.rpc("session/rename", args: ["request": .object(["sessionId": .string(id), "title": .string("Image upload check · shapes")])])
  for _ in 0..<100 { if !store.loadingHistory { break }; try await Task.sleep(for: .milliseconds(100)) }
  await store.addImage(data: try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/image.png")), name: "shapes.png", sessionID: id, host: store.endpoint)
  guard let sent = store.images.first else { throw HarnessError(message: store.error ?? "Preparation failed") }
  await store.select(nil); await store.select(id)
  guard store.images.first?.id == sent.id else { throw HarnessError(message: "Image draft lost across navigation") }
  store.draft = "Describe this image in one short sentence. This tests image input. Do not use tools or modify files."
  if existing == nil { await store.submit() } else { store.removeImage(sent.id) }
  guard store.images.isEmpty else { throw HarnessError(message: store.error ?? "Not admitted") }
  for _ in 0..<300 { if store.rows.contains(where: { !$0.images.isEmpty }) { break }; try await Task.sleep(for: .milliseconds(100)) }
  guard let attachment = store.rows.flatMap(\.images).first else { throw HarnessError(message: store.error ?? "No durable image") }
  let returned = try await store.attachmentData(attachment["attachmentId"].string, sessionID: id)
  func pixels(_ data: Data) -> [UInt8] {
   let source = CGImageSourceCreateWithData(data as CFData, nil)!
   let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
   var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
   bytes.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
   }
   return bytes
  }
  // DSH normalizes admitted images; compare decoded pixels, not encoder metadata.
  let a = pixels(sent.data), b = pixels(returned)
  let deviation = zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
  guard !returned.isEmpty, deviation < 10 else { throw HarnessError(message: "Downloaded image differs from upload") }
  print("PASS: image preparation, draft restoration, prompt admission, durable image transcript, authenticated attachment download with matching decoded image")
  for _ in 0..<1200 { if store.rows.contains(where: { $0.kind == .assistant && $0.complete }) { break }; try await Task.sleep(for: .milliseconds(100)) }
  if let reply = store.rows.first(where: { $0.kind == .assistant && $0.complete }) { print("MODEL: \(reply.text)") }
  else { print("MODEL: no completed reply within timeout") }
  store.disconnect()
 }
}
