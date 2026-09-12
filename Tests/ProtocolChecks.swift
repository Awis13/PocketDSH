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
        print("PASS: packed chunks, final settlement, duplicate suppression, sequence gap, human-source filtering, extensible JSON, login parsing and endpoint constraints")
    }
}
