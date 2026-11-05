import Foundation
import Testing
@testable import MimamoriCore

@Suite struct GitClientTests {
    private static let gone = URL(fileURLWithPath: "/nonexistent/Developer/usr/bin/git")

    @Test func aGitThatIsGoneRunsTheFallback() async throws {
        let git = try #require(await GitClient.locate())
        let moved = GitClient(executable: Self.gone, fallback: git.executable)
        #expect(try await moved.version().hasPrefix("git version"))
    }

    @Test func aGitThatIsGoneWithNoFallbackThrows() async {
        await #expect(throws: ProcessError.self) {
            try await GitClient(executable: Self.gone).version()
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")))
    func theGitBehindTheShimIsTheOneItRuns() async throws {
        let direct = try #require(await GitClient.gitBehindShim())
        #expect(direct.path != "/usr/bin/git")
        let throughShim = try await GitClient(executable: URL(fileURLWithPath: "/usr/bin/git")).version()
        #expect(try await GitClient(executable: direct).version() == throughShim)
    }
}
