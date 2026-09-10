import Foundation

@main struct ShellBlockChecks {
    static func main() throws {
        let suggestionHistory = [
            ShellHistoryEntry(command: "git status --short", directory: "/project"),
            ShellHistoryEntry(command: "git stash list", directory: "/other"),
            ShellHistoryEntry(command: "git status --branch", directory: "/project"),
            ShellHistoryEntry(command: "git status --porcelain", directory: "/other")
        ]
        precondition(ShellHistorySuggestion.suffix(for: "git st", directory: "/project", history: suggestionHistory) == "atus --branch")
        precondition(ShellHistorySuggestion.suffix(for: "git st", directory: "/unknown", history: suggestionHistory) == "atus --porcelain")
        precondition(ShellHistorySuggestion.suffix(for: "git status --branch", directory: "/project", history: suggestionHistory) == nil)
        for prefix in ["", " git", "git\n", "GIT"] {
            precondition(ShellHistorySuggestion.suffix(for: prefix, directory: "/project", history: suggestionHistory) == nil)
        }
        let unsafeDisplay = ["echo one\necho two", "echo\u{1b}[31mred", "echo\tother", "echo" + String(repeating: "x", count: 4097)]
        precondition(ShellHistorySuggestion.suffix(for: "echo", directory: "/", history: unsafeDisplay.map { ShellHistoryEntry(command: $0, directory: "/") }) == nil)
        precondition(ShellHistorySuggestion.nextWord(prefix: "git ch", suffix: "eckout feature") == "eckout")
        precondition(ShellHistorySuggestion.nextWord(prefix: "git", suffix: " checkout feature") == " checkout")
        precondition(ShellHistorySuggestion.nextWord(prefix: "cat", suffix: " 'My File.txt' --flag") == " 'My File.txt'")
        precondition(ShellHistorySuggestion.nextWord(prefix: "cat 'My", suffix: " File.txt' --flag") == " File.txt'")
        precondition(ShellHistorySuggestion.nextWord(prefix: "cat My\\", suffix: " File.txt tail") == " File.txt")
        precondition(ShellHistorySuggestion.nextWord(prefix: "echo", suffix: " 👨‍👩‍👧‍👦 next") == " 👨‍👩‍👧‍👦")
        let cyrillic = [ShellHistoryEntry(command: "echo Привет 😀", directory: "/")]
        precondition(ShellHistorySuggestion.suffix(for: "echo Пр", directory: "/", history: cyrillic) == "ивет 😀")
        let retained = [ShellHistoryEntry(command: "forgotten command", directory: "/")] + (0..<500).map { ShellHistoryEntry(command: "echo \($0)", directory: "/") }
        precondition(ShellHistorySuggestion.suffix(for: "forgotten", directory: "/", history: retained) == nil)
        precondition(ShellHistorySuggestion.suffix(for: "cat file", directory: "/", history: [ShellHistoryEntry(command: "cat file  ", directory: "/")]) == nil)
        print("PASS: history suggestion ranking, exact prefixes, single-line bounds, Unicode and quoted word acceptance")
        func input(_ text: String, at cursor: Int? = nil) -> ShellCompletionInput {
            ShellCompletionInput(text, selection: NSRange(location: cursor ?? text.utf16.count, length: 0))!
        }
        precondition(input("prin").kind == "command")
        precondition(input("echo hi | gr").kind == "command")
        precondition(input("MODE=1 prin").kind == "command")
        precondition(input("cd My").kind == "directory")
        precondition(input("echo hi > My").kind == "path")
        precondition(input("cat My\\ Fi").token == "My Fi")
        precondition(input("cat \"My Fi").replacing(with: "My File.txt").text == "cat 'My File.txt' ")
        precondition(input("cat 'O").replacing(with: "O'Brien").text == "cat 'O'\\''Brien' ")
        precondition(input("cat ~/My").replacing(with: "~/My File").text == "cat ~/'My File' ")
        precondition(input("cat $HOME/My").replacing(with: "$HOME/My File").text == "cat $HOME/'My File' ")
        let middle = input("cat foobar --flag", at: 6).replacing(with: "folder/")
        precondition(middle.text == "cat folder/ --flag" && middle.cursor == 11)
        precondition(input("cat 😀/ф").replacing(with: "😀/файл").cursor == "cat '😀/файл' ".utf16.count)
        precondition(ShellCompletionInput("cat $(date)", selection: NSRange(location: 11, length: 0)) == nil)
        var history = ShellCommandHistory()
        let old = ["one", "two"]
        let a = history.move(-1, text: "my draft", selection: NSRange(location: 3, length: 0), history: old)!
        precondition(a.text == "two")
        let b = history.move(-1, text: a.text, selection: NSRange(location: 3, length: 0), history: old)!
        precondition(b.text == "one")
        precondition(history.move(-1, text: b.text, selection: NSRange(location: 3, length: 0), history: old)!.text == "one")
        precondition(history.move(1, text: b.text, selection: NSRange(location: 3, length: 0), history: old)!.text == "two")
        let restored = history.move(1, text: "two", selection: NSRange(location: 3, length: 0), history: old)!
        precondition(restored.text == "my draft" && restored.cursor == 3)
        precondition(history.move(1, text: "edited command", selection: NSRange(location: 4, length: 0), history: old) == nil)
        print("PASS: completion token context, Unicode caret, quoting, argument preservation and history draft restoration")
        let ids = ["first", "second", "third"]
        precondition(ShellBlockNavigation.next(in: ids, selected: nil, direction: -1) == "third")
        precondition(ShellBlockNavigation.next(in: ids, selected: "removed", direction: 1) == "first")
        precondition(ShellBlockNavigation.next(in: ids, selected: "first", direction: -1) == "first")
        precondition(ShellBlockNavigation.next(in: ids, selected: "second", direction: 1) == "third")
        precondition(ShellBlockNavigation.next(in: [], selected: "gone", direction: -1) == nil)

        let unicode = ShellBlockSearch(output: "😀 Ошибка: foo\nFOO and foo\n.* literal", query: "foo")
        precondition(unicode.matches.map(\.line) == [0, 1, 1])
        precondition(unicode.index(after: 2, direction: 1) == 0)
        precondition(unicode.index(after: 0, direction: -1) == 2)
        for match in unicode.matches {
            let line = unicode.lines[match.line]
            let range = Range(match.range, in: line)!
            precondition(line[range].lowercased() == "foo")
        }
        precondition(ShellBlockSearch(output: "ошибка ОШИБКА", query: "Ошибка").matches.count == 2)
        precondition(ShellBlockSearch(output: "a .* b", query: ".*").matches.count == 1)
        precondition(ShellBlockSearch(output: "abc", query: "").matches.isEmpty)
        precondition(ShellBlockSearch(output: "abc", query: "missing").match(at: 0) == nil)
        let many = ShellBlockSearch(output: String(repeating: "x\n", count: 510), query: "x")
        precondition(many.matches.count == 500 && many.limited)

        var block = NativeBlock(id: "build-1", command: "make check", directory: "/tmp/build", preview: "BUILD FAILED\nerror: missing file", exitCode: 2, finished: true)
        precondition(ShellBlockCopy.both.text(block) == "$ make check\nBUILD FAILED\nerror: missing file")
        let attachment = ShellContextAttachment(block: block)
        let prompt = ShellPromptContent(question: "Explain the failure", attachments: [attachment])
        block.preview = "later output"
        precondition(attachment.output.contains("BUILD FAILED"))
        let decoded = try JSONDecoder().decode(ShellContextAttachment.self, from: JSONEncoder().encode(attachment))
        precondition(decoded == attachment)
        precondition(ShellPromptContent(question: prompt.question, attachments: [decoded]).text == prompt.text, "Retry context and identity must be stable")
        let parsed = ShellPromptContent.parse(prompt.text)
        precondition(parsed.question == prompt.question && parsed.attachments == [attachment])
        precondition(parsed.readableContext.contains("Exit 2") && !parsed.readableContext.contains("later output"))
        let malformed = "question" + ShellPromptContent.delimiter + "not JSON"
        precondition(ShellPromptContent.parse(malformed).question == malformed)
        precondition(ShellPromptContent(question: "plain", attachments: []).text == "plain")

        let large = NativeBlock(id: "large", command: String(repeating: "😀", count: 2000), directory: String(repeating: "Я", count: 1000), preview: String(repeating: "👨‍👩‍👧‍👦", count: 400) + "LAST", finished: false)
        let clipped = ShellContextAttachment(block: large)
        precondition(clipped.command.utf8.count <= 2048 && clipped.directory.utf8.count <= 1024 && clipped.output.utf8.count <= 4096)
        precondition(clipped.clipped && clipped.running && clipped.output.hasSuffix("LAST"))
        precondition(!clipped.output.contains("�"), "UTF-8 clipping must not split characters")
        print("PASS: block navigation, literal Unicode find, match limits, copy, immutable bounded context and replay formatting")

        let diff = ShellDiffAttachment(path: "PocketDSH/A.swift", header: "@@ -1 +1 @@", oldText: "let a = 1", newText: "let a = 2", base: "HEAD")
        let mixed = ShellPromptContent(question: "Review this hunk", attachments: [attachment], diffs: [diff])
        let mixedParsed = ShellPromptContent.parse(mixed.text)
        precondition(mixedParsed.question == mixed.question)
        precondition(mixedParsed.attachments == [attachment] && mixedParsed.diffs == [diff])
        precondition(mixedParsed.readableContext.contains("let a = 2") && mixedParsed.readableContext.contains("PocketDSH/A.swift"))
        precondition(ShellPromptContent(question: mixed.question, attachments: [attachment], diffs: [diff]).text == mixed.text,
                     "Diff context and identity must be stable for retries")
        let diffOnly = ShellPromptContent(question: "Just the hunk", attachments: [], diffs: [diff])
        precondition(ShellPromptContent.parse(diffOnly.text).diffs == [diff])
        precondition(ShellPromptContent(question: "plain", attachments: [], diffs: []).text == "plain")

        let hugeDiff = ShellDiffAttachment(path: String(repeating: "p", count: 2000), header: "", oldText: "", newText: String(repeating: "x", count: 20_000), base: "HEAD")
        precondition(hugeDiff.path.utf8.count <= 1024 && hugeDiff.newText.utf8.count <= 8192 && hugeDiff.clipped)
        precondition(!hugeDiff.newText.contains("�"), "Diff clipping must not split characters")

        let legacy = "Explain" + ShellPromptContent.delimiter + #"[{"blockID":"b1","command":"make","directory":"/tmp","output":"boom","exitCode":1,"running":false,"clipped":false,"id":"fixed"}]"#
        let legacyParsed = ShellPromptContent.parse(legacy)
        precondition(legacyParsed.question == "Explain" && legacyParsed.attachments.count == 1 && legacyParsed.diffs.isEmpty,
                     "A terminal-block-only payload without a kind must still parse")
        let unknown = "Question" + ShellPromptContent.delimiter + #"[{"kind":"future","payload":"x"},{"kind":"terminal","blockID":"b2","command":"ls","directory":"/","output":"ok","exitCode":0,"running":false,"clipped":false,"id":"t2"}]"#
        let unknownParsed = ShellPromptContent.parse(unknown)
        precondition(unknownParsed.attachments.count == 1 && unknownParsed.attachments.first?.command == "ls" && unknownParsed.diffs.isEmpty,
                     "An unknown attachment kind is skipped, not fatal")
        print("PASS diff hunk attachment: round-trip, diff-only, bounds, unknown kinds and legacy prompt back-compat")
    }
}
