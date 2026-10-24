import Foundation
import Testing
@testable import VigilCore

@Suite("Syntax highlighter")
struct SyntaxHighlighterTests {
    /// The highlighted pieces of each line as (text, kind), for readable expectations.
    private func tokens(_ lines: [String], _ language: SyntaxLanguage) -> [[(String, SyntaxTokenKind)]] {
        let spans = SyntaxHighlighter.highlight(lines: lines, language: language)
        return zip(lines, spans).map { line, spans in
            let characters = Array(line)
            return spans.map { (String(characters[$0.range]), $0.kind) }
        }
    }

    private func tokens(_ line: String, _ language: SyntaxLanguage) -> [(String, SyntaxTokenKind)] {
        tokens([line], language)[0]
    }

    private func has(_ found: [(String, SyntaxTokenKind)], _ text: String, _ kind: SyntaxTokenKind) -> Bool {
        found.contains { $0.0 == text && $0.1 == kind }
    }

    @Test func detectsLanguagesByNameAndExtension() {
        #expect(SyntaxLanguage.forPath("Sources/App/View.swift")?.name == "Swift")
        #expect(SyntaxLanguage.forPath("web/app.TSX")?.name == "TypeScript")
        #expect(SyntaxLanguage.forPath("Dockerfile")?.name == "Dockerfile")
        #expect(SyntaxLanguage.forPath("docker/Dockerfile.dev")?.name == "Dockerfile")
        #expect(SyntaxLanguage.forPath(".env.local")?.name == "TOML")
        #expect(SyntaxLanguage.forPath(".gitignore")?.name == "Ignore file")
        #expect(SyntaxLanguage.forPath("LICENSE") == nil)
        #expect(SyntaxLanguage.forPath("data.bin") == nil)
    }

    @Test func swiftKeywordsStringsCommentsNumbersAndAttributes() {
        let found = tokens(#"@MainActor let url = "https://x.dev" // 42 "quoted""#, .swift)
        #expect(has(found, "@MainActor", .attribute))
        #expect(has(found, "let", .keyword))
        #expect(has(found, "\"https://x.dev\"", .string))   // the // inside is not a comment
        #expect(has(found, "// 42 \"quoted\"", .comment))
        #expect(!found.contains { $0.0 == "url" })

        let types = tokens("var count: Int = item2 + 0x1F + 3.5e-2 + Foo.bar(MAX_SIZE)", .swift)
        #expect(has(types, "Int", .type))
        #expect(has(types, "Foo", .type))
        #expect(has(types, "0x1F", .number))
        #expect(has(types, "3.5e-2", .number))
        #expect(!types.contains { $0.0 == "2" })          // the digit in item2
        #expect(!types.contains { $0.0 == "MAX_SIZE" })   // a constant, not a type

        let closure = tokens("items.reduce(0) { $0 + $1.price }", .swift)
        #expect(closure.map(\.0) == ["0"])   // only the literal, not the 0 in $0
    }

    @Test func escapedQuotesStayInsideTheString() {
        let found = tokens(#"let s = "say \"hi\"" + x"#, .swift)
        #expect(has(found, #""say \"hi\"""#, .string))
    }

    @Test func blockCommentsAndMultilineStringsSpanLines() {
        let lines = ["let a = 1 /* start", "still comment", "end */ let b = 2"]
        let found = tokens(lines, .swift)
        #expect(has(found[0], "/* start", .comment))
        #expect(has(found[1], "still comment", .comment))
        #expect(has(found[2], "end */", .comment))
        #expect(has(found[2], "let", .keyword))

        let python = tokens(["doc = \"\"\"First", "middle", "end\"\"\" + x"], .python)
        #expect(has(python[0], "\"\"\"First", .string))
        #expect(has(python[1], "middle", .string))
        #expect(has(python[2], "end\"\"\"", .string))
    }

    @Test func jsonKeysDifferFromValues() {
        let found = tokens(#"  "name": "vigil", "count": 3, "ok": true"#, .json)
        #expect(has(found, "\"name\"", .key))
        #expect(has(found, "\"vigil\"", .string))
        #expect(has(found, "3", .number))
        #expect(has(found, "true", .keyword))
    }

    @Test func yamlKeysCommentsAndAnchors() {
        let found = tokens(["- name: build   # step", "  on: &trigger push", "---"], .yaml)
        #expect(has(found[0], "name", .key))
        #expect(has(found[0], "# step", .comment))
        #expect(has(found[1], "on", .key))
        #expect(has(found[1], "&trigger", .attribute))
        #expect(has(found[2], "---", .keyword))
    }

    @Test func keyValueFiles() {
        let found = tokens(["[server]", "port = 8080 # default", "export API_URL=\"https://x\""], .toml)
        #expect(has(found[0], "[server]", .type))
        #expect(has(found[1], "port", .key))
        #expect(has(found[1], "8080", .number))
        #expect(has(found[1], "# default", .comment))
        #expect(has(found[2], "export", .keyword))
        #expect(has(found[2], "API_URL", .key))
    }

    @Test func markupTagsAttributesAndComments() {
        let found = tokens([#"<a href="/x" class='y'>Hi &amp; bye</a> <!-- note"#, "still -->"], .markup)
        #expect(has(found[0], "<a", .tag))
        #expect(has(found[0], "href", .attribute))
        #expect(has(found[0], "\"/x\"", .string))
        #expect(has(found[0], "'y'", .string))
        #expect(has(found[0], "&amp;", .attribute))
        #expect(has(found[0], "</a", .tag))
        #expect(has(found[0], "<!-- note", .comment))
        #expect(has(found[1], "still -->", .comment))
        #expect(!found[0].contains { $0.0 == "Hi" })
    }

    @Test func shellVariablesAndComments() {
        let found = tokens(#"if [ -n "$HOME" ]; then echo ${#items[@]} $1; fi # done"#, .shell)
        #expect(has(found, "if", .keyword))
        #expect(has(found, "\"$HOME\"", .string))
        #expect(has(found, "${#items[@]}", .attribute))   // not a comment
        #expect(has(found, "$1", .attribute))
        #expect(has(found, "# done", .comment))
    }

    @Test func rustLifetimesAndCharacters() {
        let found = tokens("fn first<'a>(s: &'a str) -> char { 'x' } #[derive(Debug)]", .rust)
        #expect(has(found, "'a", .attribute))
        #expect(has(found, "'x'", .string))
        #expect(has(found, "str", .type))
        #expect(has(found, "#[derive(Debug)]", .attribute))
    }

    @Test func sqlIsCaseInsensitive() {
        let found = tokens("SELECT id FROM users WHERE name ILIKE 'k%' -- recent", .sql)
        #expect(has(found, "SELECT", .keyword))
        #expect(has(found, "ILIKE", .keyword))
        #expect(has(found, "'k%'", .string))
        #expect(has(found, "-- recent", .comment))
    }

    @Test func cDirectivesAndIncludes() {
        let found = tokens(["#include <stdio.h>", "#define MAX 10"], .cFamily)
        #expect(has(found[0], "#include", .attribute))
        #expect(has(found[0], "<stdio.h>", .string))
        #expect(has(found[1], "#define", .attribute))
        #expect(has(found[1], "10", .number))
    }

    @Test func markdownStructure() {
        let found = tokens(["# Title", "- item with `code`", "```swift", "let x = 1", "```", "> quote"], .markdown)
        #expect(has(found[0], "# Title", .keyword))
        #expect(has(found[1], "-", .keyword))
        #expect(has(found[1], "`code`", .string))
        #expect(has(found[2], "```swift", .attribute))
        #expect(found[3].isEmpty)
        #expect(has(found[4], "```", .attribute))
        #expect(has(found[5], "> quote", .comment))
    }

    @Test func cssPropertiesColorsAndAtRules() {
        let found = tokens("@media screen { .a { color: #fff !important; margin: 4px; } }", .css)
        #expect(has(found, "@media", .attribute))
        #expect(has(found, "color", .key))
        #expect(has(found, "#fff", .number))
        #expect(has(found, "!important", .keyword))
        #expect(has(found, "4px", .number))
    }

    @Test func veryLongLinesAreLeftPlain() {
        let line = String(repeating: "let x = 1; ", count: 300)
        #expect(tokens(line, .swift).isEmpty)
    }
}

@Suite("Side-by-side layout")
struct SideBySideTests {
    private func hunk(_ text: String) throws -> DiffHunk {
        let patch = "diff --git a/f b/f\n--- a/f\n+++ b/f\n" + text
        return try #require(DiffParser.parse(patch).first?.hunks.first)
    }

    private func describe(_ rows: [SplitRow]) -> [String] {
        rows.map { "\($0.left?.text ?? "_")|\($0.right?.text ?? "_")" }
    }

    @Test func pairsDeletionsWithTheAdditionsAfterThem() throws {
        let rows = SideBySide.rows(for: try hunk("@@ -1,5 +1,4 @@\n a\n-b\n-c\n-d\n+B\n+C\n e\n"))
        #expect(describe(rows) == ["a|a", "b|B", "c|C", "d|_", "e|e"])
    }

    @Test func extraAdditionsLeaveTheLeftBlank() throws {
        let rows = SideBySide.rows(for: try hunk("@@ -1,2 +1,4 @@\n a\n-b\n+B\n+new\n+more\n"))
        #expect(describe(rows) == ["a|a", "b|B", "_|new", "_|more"])
    }

    @Test func separateChangeRunsDoNotMix() throws {
        let rows = SideBySide.rows(for: try hunk("@@ -1,3 +1,3 @@\n-x\n+X\n a\n-y\n+Y\n"))
        #expect(describe(rows) == ["x|X", "a|a", "y|Y"])
    }

    @Test func rowIdsFollowTheNewSideAndStayUnique() throws {
        let rows = SideBySide.rows(for: try hunk("@@ -1,3 +1,3 @@\n a\n-b\n+B\n-c\n"))
        let ids = rows.map(\.id)
        #expect(Set(ids).count == ids.count)
        let paired = try #require(rows.first { $0.left?.text == "b" })
        #expect(paired.id == paired.right?.id)
    }

    @Test func noNewlineMarkerFollowsItsSide() throws {
        let rows = SideBySide.rows(for: try hunk("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n"))
        #expect(rows.count == 3)
        #expect(rows[1].left?.kind == .noNewline && rows[1].right == nil)
        #expect(rows[2].right?.text == "new")
    }
}
