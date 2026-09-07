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
