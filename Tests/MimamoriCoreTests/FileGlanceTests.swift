import AppKit
import Testing
@testable import MimamoriCore

@Suite("Diff bars and file symbols")
struct FileGlanceTests {
    @Test func lightsMoreBlocksForBiggerChanges() {
        let lit = [1, 4, 12, 40, 120, 400, 5000].map { DiffBlocks(additions: $0, deletions: 0).added }
        #expect(lit == [1, 2, 2, 3, 4, 5, 5])
        #expect(lit == lit.sorted())
        let none = DiffBlocks(additions: 0, deletions: 0)
        #expect(none.added == 0 && none.removed == 0 && none.empty == DiffBlocks.count)
    }

    @Test func splitsTheLitBlocksBetweenAddedAndRemoved() {
        let mostlyAdded = DiffBlocks(additions: 300, deletions: 10)
        #expect(mostlyAdded.added == 5 && mostlyAdded.removed == 0 && mostlyAdded.empty == 0)
        let mixed = DiffBlocks(additions: 200, deletions: 100)
        #expect(mixed.added == 3 && mixed.removed == 2)
        let even = DiffBlocks(additions: 50, deletions: 50)
        #expect(even.added + even.removed == 4)
        #expect(even.added >= 1 && even.removed >= 1)
        let deletedOnly = DiffBlocks(additions: 0, deletions: 30)
        #expect(deletedOnly.added == 0 && deletedOnly.removed == 3)
        // Two lines light one block, which goes to one kind or the other.
        let tiny = DiffBlocks(additions: 1, deletions: 1)
        #expect(tiny.added + tiny.removed == 1)
        #expect(DiffBlocks(additions: -3, deletions: 0) == DiffBlocks(additions: 0, deletions: 0))
    }

    @Test func namesAFilesKind() {
        #expect(FileSymbol.name(for: "Sources/App/Model.swift") == "swift")
        #expect(FileSymbol.name(for: "Tests/AppTests/ModelTests.swift") == "testtube.2")
        #expect(FileSymbol.name(for: "src/parser.test.ts") == "testtube.2")
        #expect(FileSymbol.name(for: "pkg/server_test.go") == "testtube.2")
        #expect(FileSymbol.name(for: "Contest.swift") == "swift")
        #expect(FileSymbol.name(for: "README.md") == "doc.text")
        #expect(FileSymbol.name(for: "package.json") == "curlybraces")
        #expect(FileSymbol.name(for: "Package.resolved") == "lock")
        #expect(FileSymbol.name(for: "Dockerfile") == "shippingbox")
        #expect(FileSymbol.name(for: ".github/workflows/ci.yml") == "gearshape")
        #expect(FileSymbol.name(for: "Scripts/make-app.sh") == "terminal")
        #expect(FileSymbol.name(for: "Assets/icon.PNG") == "photo")
        #expect(FileSymbol.name(for: "notes") == "doc")
    }

    @Test func everySymbolExists() {
        for name in FileSymbol.allNames {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
