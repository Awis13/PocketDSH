import Foundation
import ImageIO

@main struct ProtocolChecks {
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
    static func main() async throws {
        let unicode = try JSON.decodeWire(Data(#"{"high":"x\uD83D","low":"\ude00y","pair":"\uD83D\uDE00","literal":"\\uD83D","mixed":"\uD83D\uD83D\uDE00"}"#.utf8))
        assert(unicode["high"].string == "x�" && unicode["low"].string == "�y")
        assert(unicode["pair"].string == "😀" && unicode["literal"].string == #"\uD83D"#)
        assert(unicode["mixed"].string == "�😀")
        do {
            _ = try JSON.decodeWire(Data(#"{"bad":"\uXYZ1"}"#.utf8))
            assertionFailure("Malformed JSON must still be rejected")
        } catch {}
        print("PASS: lone UTF-16 surrogate repair, valid emoji, literal escapes and invalid JSON rejection")
        var transcript = Transcript()
        let records = json("""
        [
          {"event":{"type":"user/message","seq":0,"data":{"source":{"kind":"user"},"content":[{"type":"text","text":"Hello"}]}}},
          {"event":{"type":"chunkrow/text-chunks","seq":1,"data":{"turn":1,"step":1,"index":0,"texts":["Hel","lo"],"dt":[2]}}}
        ]
        """).array
        transcript.replace(records, cursor: 2)
        assert(transcript.rows.count == 2 && transcript.rows[1].text == "Hello")
        assert(transcript.append(json("""
        {"type":"assistant/message","seq":3,"data":{"turn":1,"step":1,"message":{"content":[{"type":"text","text":"Hello!"}]}}}
        """)))
        assert(transcript.rows.count == 2 && transcript.rows[1].text == "Hello!")
        assert(transcript.append(json("""
        {"type":"assistant/message","seq":3,"data":{}}
        """)))
        assert(transcript.rows.count == 2, "duplicate delivery must not duplicate transcript")
        assert(!transcript.append(json("""
        {"type":"turn/end","seq":5,"data":{}}
        """)), "gap must request recovery")
        assert(transcript.append(json("""
        {"type":"user/message","seq":4,"data":{"source":{"kind":"context"},"content":[{"type":"text","text":"internal"}]}}
        """)))
        assert(transcript.rows.count == 2, "internal injected context must not impersonate the user")
        // Command lifecycle rows settle in place by commandId, not by a
        // positional index: the final assistant message prunes the streamed
        // delta row, so an index captured at the run would rename the wrong row.
        var lifecycle = Transcript()
        lifecycle.replace(json("""
        [{"event":{"type":"assistant/chunk","seq":0,"data":{"turn":1,"step":1,"chunk":{"type":"text-delta","index":0,"text":"Wor"}}}}]
        """).array, cursor: 0)
        assert(lifecycle.rows.map(\.id) == ["a-1-1-0"])
        assert(lifecycle.append(json(#"{"type":"command/run","seq":1,"data":{"commandId":"c1","name":"goal","args":" clear","source":{"kind":"user"}}}"#)))
        assert(lifecycle.rows.map(\.id) == ["a-1-1-0", "command-c1"], "the run opens a row after the delta")
        assert(!lifecycle.rows[1].complete && lifecycle.rows[1].text == "/goal clear - running")
        assert(lifecycle.append(json("""
        {"type":"assistant/message","seq":2,"data":{"turn":1,"step":1,"message":{"content":[{"type":"text","text":"Working"}]}}}
        """)))
        assert(lifecycle.rows.map(\.id) == ["command-c1", "a-1-1-0"], "the pruned delta returns as the final message")
        assert(lifecycle.append(json(#"{"type":"command/done","seq":3,"data":{"commandId":"c1","kind":"success","text":"goal cleared"}}"#)))
        assert(lifecycle.rows.map(\.id) == ["command-c1", "a-1-1-0"], "the done settles the run's row in place")
        assert(lifecycle.rows[0].text == "/goal clear - goal cleared" && lifecycle.rows[0].complete && !lifecycle.rows[0].failed)
        assert(lifecycle.rows[1].text == "Working" && lifecycle.rows[1].kind == .assistant, "the done must not overwrite the assistant row")
        // A duplicate done and a re-delivered run are idempotent.
        assert(lifecycle.append(json(#"{"type":"command/done","seq":4,"data":{"commandId":"c1","kind":"success","text":"goal cleared"}}"#)))
        assert(lifecycle.append(json(#"{"type":"command/run","seq":5,"data":{"commandId":"c1","name":"other"}}"#)))
        assert(lifecycle.rows.count == 2 && lifecycle.rows[0].text.hasPrefix("/goal clear"), "a re-delivered run never reopens a settled command")
        // A done whose run sits outside the loaded window still renders, and the
        // late run names the row it could not open.
        var orphan = Transcript()
        orphan.replace(json("""
        [{"event":{"type":"command/done","seq":0,"data":{"commandId":"c9","kind":"error","text":"no such command"}}},
         {"event":{"type":"command/run","seq":1,"data":{"commandId":"c9","name":"goal"}}}]
        """).array, cursor: 1)
        assert(orphan.rows.count == 1 && orphan.rows[0].id == "command-c9")
        assert(orphan.rows[0].failed && orphan.rows[0].complete && orphan.rows[0].text == "/goal - no such command")
        print("PASS: command lifecycle rows settle in place across pruning, duplicates and an orphan done")
        var changes = Transcript()
        changes.replace(json("""
        [{"event":{"type":"tool/result","seq":0,"data":{"meta":{"diffs":[{"path":"sample.swift","oldText":"let value = 1","newText":"let value = 2"}]},"message":{"source":{"callId":"edit-1"},"content":[{"type":"tool-result","content":[{"type":"text","text":"edited"}]}]}}}}]
        """).array, cursor: 0)
        assert(changes.rows.first?.diffs.first?["oldText"].string == "let value = 1")
        assert(changes.rows.first?.diffs.first?["newText"].string == "let value = 2")
        var tools = Transcript()
        tools.replace(json("""
        [
        {"event":{"type":"tool/call","seq":0,"data":{"callId":"call-1","name":"bash","arguments":"{}"}}},
        {"event":{"type":"tool/result","seq":1,"data":{"message":{"source":{"kind":"tool","callId":"call-1"},"content":[{"type":"tool-result","toolCallId":"call-1","isError":true,"content":[{"type":"text","text":"denied"}]}]}}}}
        ]
        """).array, cursor: 1)
        assert(tools.rows.count == 1 && tools.rows[0].complete && tools.rows[0].failed && tools.rows[0].detail.contains("denied"))
        var pictures = Transcript()
        pictures.replace(json("""
        [{"event":{"type":"user/message","seq":0,"data":{"source":{"kind":"user"},"content":[{"type":"image","attachment":{"attachmentId":"test-image","mediaType":"image/png"}}]}}}]
        """).array, cursor: 0)
        assert(pictures.rows.count == 1 && pictures.rows[0].images.count == 1 && pictures.rows[0].text.isEmpty)
        var outputs = Transcript()
        outputs.replace(json("""
        [{"event":{"type":"tool/result","seq":1,"data":{"message":{"source":{"callId":"image-call"},"content":[{"type":"tool-result","content":[{"type":"text","text":"Attached"},{"type":"image","attachment":{"attachmentId":"one"}},{"type":"image"}]},{"type":"tool-result","content":[{"type":"image","attachment":{"attachmentId":"two"}}]}]}}}},
        {"event":{"type":"assistant/message","seq":2,"data":{"turn":1,"step":1,"message":{"content":[{"type":"text","text":"Here"},{"type":"image","attachment":{"attachmentId":"three"}}]}}}}]
        """).array, cursor: 2)
        assert(outputs.rows.count == 3)
        assert(outputs.rows[0].images.map { $0["attachmentId"].string } == ["one", "two"])
        assert(outputs.rows[0].complete && outputs.rows[0].detail.contains("Attached"))
        assert(outputs.rows[2].kind == .assistant && outputs.rows[2].images.count == 1)
        print("PASS: tool image output, partial history, multiple results, malformed reference, assistant image")
        var live = AssistantLiveStream()
        assert(live.receive(json(#"{"type":"start","attemptId":"a","turn":1,"step":1}"#)))
        let delta = json(#"{"type":"chunk","attemptId":"a","index":0,"chunk":{"type":"text-delta","index":0,"text":"Hi"}}"#)
        assert(live.receive(delta)); assert(live.receive(delta))
        assert(live.rows.count == 1 && live.rows[0].text == "Hi" && !live.rows[0].complete)
        assert(!live.receive(json(#"{"type":"chunk","attemptId":"a","index":2}"#)))
        var committed = Transcript()
        committed.replace(json(#"[{"event":{"type":"assistant/message","seq":0,"data":{"turn":1,"step":1,"message":{"content":[{"type":"text","text":"Hi there"}]}}}}]"#).array, cursor: 0)
        assert(live.merged(with: committed.rows).count == 1)
        assert(live.merged(with: committed.rows)[0].text == "Hi there")
        live.baseline(json(#"{"activeAttempt":{"attemptId":"b","turn":2,"step":1,"nextIndex":3,"stream":[{"type":"text-chunks","index":0,"texts":["one","two"]}]}}"#))
        assert(live.rows[0].text == "onetwo")
        assert(live.receive(json(#"{"type":"chunk","attemptId":"b","index":3,"chunk":{"type":"text-delta","index":0,"text":"three"}}"#)))
        assert(live.rows[0].text == "onetwothree")
        assert(live.receive(json(#"{"type":"end","attemptId":"b"}"#))); assert(live.rows.isEmpty)
        print("PASS: live assistant stream, duplicate suppression, gap recovery, committed replacement and snapshot continuation")
        let limits = ImageLimits(json("{\"maxImageDimension\":64,\"maxImagesPerMessage\":1}"))
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/image.png"))
        let prepared = try ImagePreparation.prepare(fixture, name: "fixture.png", limits: limits)
        let source = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        assert((properties[kCGImagePropertyPixelWidth] as! Int) <= 64)
        assert((properties[kCGImagePropertyPixelHeight] as! Int) <= 64)
        try limits.validate([prepared])
        do { try limits.validate([prepared, prepared]); fatalError("Count limit ignored") } catch {}
        do { _ = try ImagePreparation.prepare(Data("invalid".utf8), name: "bad", limits: limits); fatalError("Invalid image accepted") } catch {}
        print("PASS: image-only transcript, bounded image conversion, count limits, corrupt image rejection")
        let data = try JSONEncoder().encode(json("{\"unknown\":[null,4,true,\"x\"]}"))
        let decoded = try JSONDecoder().decode(JSON.self, from: data)
        assert(decoded == json("{\"unknown\":[null,4,true,\"x\"]}"))
        let (base, token) = try HarnessAPI.parse("https://mac.ts.net:3080/?token=secret")
        assert(base.absoluteString == "https://mac.ts.net:3080" && token == "secret")
        for invalid in ["http://example.com", "https://u:p@mac.ts.net", "file:///tmp", "https://mac.ts.net/path"] {
            do { _ = try HarnessAPI.parse(invalid); fatalError("Accepted invalid endpoint") } catch {}
        }

        // ------------------------------------------------------------------
        // DSH RPC error contract (PARITY-2B B1).
        // server-response.result.error carries a ConnectionRpcFailure
        // {code, message, details}. The production rpc() must preserve all
        // three on the thrown LocalizedError while the display stays the
        // plain message. The scenarios drive the real rpc() against a canned
        // local HTTP server keyed by request path, so the wire envelope,
        // status handling and decodeWire run unchanged.
        // ------------------------------------------------------------------
        struct CannedWire { let status: Int; let contentType: String; let body: Data }
        final class CannedHTTP: @unchecked Sendable {
            let port: Int
            private let listenFD: Int32
            private let queue = DispatchQueue(label: "pocket.checks.canned-http")
            private let canned: [String: CannedWire]
            init(_ canned: [String: CannedWire]) throws {
                self.canned = canned
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw HarnessError(message: "canned HTTP: socket() failed") }
                var reuse: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = 0
                addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard bound == 0 else { throw HarnessError(message: "canned HTTP: bind() failed") }
                var actual = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &actual) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
                }
                guard named == 0 else { throw HarnessError(message: "canned HTTP: getsockname() failed") }
                port = Int(UInt16(bigEndian: actual.sin_port))
                guard listen(fd, 8) == 0 else { throw HarnessError(message: "canned HTTP: listen() failed") }
                listenFD = fd
                queue.async { self.acceptLoop() }
            }
            private func acceptLoop() {
                while true {
                    let client = accept(listenFD, nil, nil)
                    guard client >= 0 else { break }
                    serve(client)
                }
            }
            private func serve(_ client: Int32) {
                defer { close(client) }
                var buf = Data()
                var chunk = [UInt8](repeating: 0, count: 8192)
                var headerEnd: Int?
                var bodyLength = 0
                while true {
                    let n = recv(client, &chunk, chunk.count, 0)
                    guard n > 0 else { return }
                    buf.append(contentsOf: chunk[0..<Int(n)])
                    if headerEnd == nil, let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                        headerEnd = r.upperBound
                        bodyLength = String(decoding: buf[0..<r.upperBound], as: UTF8.self)
                            .components(separatedBy: "\r\n")
                            .compactMap { line -> Int? in
                                let parts = line.components(separatedBy: ":")
                                guard parts.count >= 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                                return Int(parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces))
                            }.first ?? 0
                    }
                    if let end = headerEnd, buf.count >= end + bodyLength { break }
                }
                let head = String(decoding: buf[0..<(headerEnd ?? 0)], as: UTF8.self)
                let path = head.split(separator: "\n").first.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").dropFirst().first
                }.map(String.init) ?? ""
                let wire = canned[path] ?? CannedWire(status: 500, contentType: "application/json", body: Data("{}".utf8))
                let reason: String
                switch wire.status { case 200: reason = "OK"; case 401: reason = "Unauthorized"; default: reason = "Internal Server Error" }
                var out = Data()
                out += Data("HTTP/1.1 \(wire.status) \(reason)\r\n".utf8)
                out += Data("Content-Type: \(wire.contentType)\r\n".utf8)
                out += Data("Content-Length: \(wire.body.count)\r\n".utf8)
                out += Data("Connection: close\r\n\r\n".utf8)
                out += wire.body
                out.withUnsafeBytes { _ = send(client, $0.baseAddress, $0.count, 0) }
            }
        }
        struct ScenarioFailure: Error { let step: String }
        func expectRPCFailure(_ error: HarnessError, scenario: String, code: String?, message: String, details: JSON) throws {
            guard error.code == code else { throw ScenarioFailure(step: "\(scenario): code is \(String(describing: error.code)), want \(String(describing: code))") }
            guard error.message == message else { throw ScenarioFailure(step: "\(scenario): message is \(error.message.debugDescription)") }
            guard error.details == details else { throw ScenarioFailure(step: "\(scenario): details are \(error.details.pretty)") }
            // Existing presentation: the UI sees exactly the plain server
            // message, or the previous empty text when the server sends none.
            guard error.errorDescription == message, error.localizedDescription == message else { throw ScenarioFailure(step: "\(scenario): display drifted from the plain message") }
        }
        let server = try CannedHTTP([
            "/api/session/create": CannedWire(status: 200, contentType: "application/json", body: Data(#"{"type":"server-response","rpcId":"r1","result":{"ok":true,"value":{"sessionId":"s-1"}}}"#.utf8)),
            "/api/agentPresets/select": CannedWire(status: 200, contentType: "application/json", body: Data(#"{"type":"server-response","rpcId":"r2","result":{"ok":false,"error":{"code":"agent-preset/locked","message":"The agent preset cannot be switched after the first turn.","details":{"sessionId":"s-1","agentPreset":"ptc"}}}}"#.utf8)),
            "/api/agentPresets/list": CannedWire(status: 200, contentType: "application/json", body: Data(#"{"type":"server-response","rpcId":"r3","result":{"ok":false,"error":{"code":"parity/tests/unknown-code","message":"Unexpected server shape.","details":{"depth":2}}}}"#.utf8)),
            "/api/agentPresets/refresh": CannedWire(status: 200, contentType: "application/json", body: Data(#"{"type":"server-response","rpcId":"r4","result":{"ok":false,"error":{"code":"agent-preset/not-found","details":{"agentPreset":"ptc","available":["default"]}}}}"#.utf8)),
            "/api/agentPresets/validate": CannedWire(status: 200, contentType: "application/json", body: Data(#"{"type":"server-response","rpcId":"r5","result":{"ok":false,"error":{"code":"agent-preset/invalid","message":"The agent preset is not a string."}}}"#.utf8)),
            "/api/agentPresets/expired": CannedWire(status: 401, contentType: "application/json", body: Data(#"{"result":{"ok":false}}"#.utf8)),
            "/api/agentPresets/down": CannedWire(status: 500, contentType: "text/html", body: Data("<html>boom</html>".utf8)),
            "/api/agentPresets/malformed": CannedWire(status: 200, contentType: "text/plain", body: Data("not json".utf8)),
        ])
        let wireAPI = HarnessAPI(base: URL(string: "http://127.0.0.1:\(server.port)")!)
        // 1 · success: result.value passes through unchanged.
        let created = try await wireAPI.rpc("session/create")
        assert(created["sessionId"].string == "s-1", "success must return result.value")
        // 2 · known code: code, message and the raw JSON details survive.
        do { _ = try await wireAPI.rpc("agentPresets/select"); fatalError("locked error must throw") }
        catch let e as HarnessError {
            try expectRPCFailure(e, scenario: "known code", code: "agent-preset/locked",
                                 message: "The agent preset cannot be switched after the first turn.",
                                 details: json(#"{"sessionId":"s-1","agentPreset":"ptc"}"#))
        }
        // 3 · unknown code: preserved verbatim; the client keeps no registry.
        do { _ = try await wireAPI.rpc("agentPresets/list"); fatalError("unknown-code error must throw") }
        catch let e as HarnessError {
            try expectRPCFailure(e, scenario: "unknown code", code: "parity/tests/unknown-code",
                                 message: "Unexpected server shape.",
                                 details: json(#"{"depth":2}"#))
        }
        // 4 · missing message: the existing display stays the previous empty text.
        do { _ = try await wireAPI.rpc("agentPresets/refresh"); fatalError("missing-message error must throw") }
        catch let e as HarnessError {
            try expectRPCFailure(e, scenario: "missing message", code: "agent-preset/not-found",
                                 message: "",
                                 details: json(#"{"agentPreset":"ptc","available":["default"]}"#))
        }
        // 5 · missing details: raw JSON .null, message display unchanged.
        do { _ = try await wireAPI.rpc("agentPresets/validate"); fatalError("missing-details error must throw") }
        catch let e as HarnessError {
            try expectRPCFailure(e, scenario: "missing details", code: "agent-preset/invalid",
                                 message: "The agent preset is not a string.",
                                 details: .null)
        }
        // 6 · 401: the existing auth text is unchanged.
        do { _ = try await wireAPI.rpc("agentPresets/expired"); fatalError("401 must throw") }
        catch let e as HarnessError { assert(e.message == "Sign in again with a fresh DSH launch URL in Connection settings.", "401 text drifted") }
        // 7 · non-200: the existing generic HTTP text is unchanged and untyped.
        do { _ = try await wireAPI.rpc("agentPresets/down"); fatalError("500 must throw") }
        catch let e as HarnessError { assert(e.message == "DSH: HTTP 500" && e.code == nil && e.details == .null, "500 text or shape drifted") }
        // 8 · malformed body: the existing invalid-response text is unchanged.
        do { _ = try await wireAPI.rpc("agentPresets/malformed"); fatalError("malformed body must throw") }
        catch let e as HarnessError { assert(e.message == "Invalid DSH response for agentPresets/malformed: text/plain, 8 bytes (HTTP 200).", "malformed text drifted") }
        // 9 · broken variant: the pre-B1 decoder kept only the message (the
        // old rpc() line). It compiles and the same battery must reject it,
        // so the scenarios above fail on the regression instead of passing.
        let oldEnvelope = json(#"{"type":"server-response","rpcId":"r2","result":{"ok":false,"error":{"code":"agent-preset/locked","message":"The agent preset cannot be switched after the first turn.","details":{"sessionId":"s-1","agentPreset":"ptc"}}}}"#)
        let broken = HarnessError(message: oldEnvelope["result"]["error"]["message"].string)
        do {
            try expectRPCFailure(broken, scenario: "pre-fix decoder", code: "agent-preset/locked",
                                 message: "The agent preset cannot be switched after the first turn.",
                                 details: json(#"{"sessionId":"s-1","agentPreset":"ptc"}"#))
            fatalError("the pre-fix decoder passed the preserved-field battery")
        } catch is ScenarioFailure {
            // expected: the battery discriminates the old decoder
        }
        print("PASS: DSH RPC error contract - success value, known/unknown code, missing message/details, plain-message display, transport text, pre-fix decoder sensitivity")

        print("PASS: packed chunks, final settlement, duplicate suppression, sequence gap, human-source filtering, extensible JSON, login parsing and endpoint constraints")
    }
}
