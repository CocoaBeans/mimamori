import Foundation
import Testing
@testable import MimamoriCore

@Suite("Rediscovering worktrees")
struct WorktreeRediscoveryTests {
    let garden = UUID()
    let atlas = UUID()

    private func worktree(_ path: String, branch: String? = nil) -> WorktreeInfo {
        WorktreeInfo(path: path, branch: branch)
    }

    @Test func newWorktreesGetSessionsAndKnownOnesTakeTheirDetails() {
        let listed = [worktree("/src/garden", branch: "main"), worktree("/src/garden-paths", branch: "paths")]
        let plan = WorktreeReconciliation(listed: listed, hidden: [], sessions: ["/src/garden": garden], repository: garden)
        #expect(plan.update == [listed[0]])
        #expect(plan.create == [listed[1]])
        #expect(plan.stop.isEmpty)
    }

    @Test func sessionsStopWhenTheirWorktreeIsGoneOrHidden() {
        let listed = [worktree("/src/garden"), worktree("/src/garden-hidden")]
        let sessions = ["/src/garden": garden, "/src/garden-gone": garden, "/src/garden-hidden": garden]
        let plan = WorktreeReconciliation(listed: listed, hidden: ["/src/garden-hidden"], sessions: sessions, repository: garden)
        #expect(plan.stop == ["/src/garden-gone", "/src/garden-hidden"])
        #expect(plan.update.map(\.path) == ["/src/garden"])
        #expect(plan.create.isEmpty)
    }

    @Test func hiddenWorktreesGetNoSession() {
        let listed = [worktree("/src/garden"), worktree("/src/garden-hidden")]
        let plan = WorktreeReconciliation(listed: listed, hidden: ["/src/garden-hidden"], sessions: [:], repository: garden)
        #expect(plan.create.map(\.path) == ["/src/garden"])
    }

    @Test func otherRepositoriesSessionsAreLeftAlone() {
        let plan = WorktreeReconciliation(listed: [worktree("/src/garden")], hidden: [],
                                          sessions: ["/src/atlas": atlas], repository: garden)
        #expect(plan.stop.isEmpty)
        #expect(plan.create.map(\.path) == ["/src/garden"])
    }

    // The repository can be removed while git lists its worktrees. Applying that listing would
    // start sessions nothing stops, in a repository no longer watched.
    @Test func aListingForARepositoryRemovedMeanwhileIsRefused() {
        var listings = WorktreeListings()
        let ticket = listings.begin()
        listings.remove(garden)
        let later = listings.begin()
        let applied = [listings.accepts(ticket, for: garden), listings.accepts(later, for: garden)]
        #expect(applied == [false, false])
    }

    @Test func removingARepositoryLeavesOthersListed() {
        var listings = WorktreeListings()
        let ticket = listings.begin()
        listings.remove(garden)
        let applied = listings.accepts(ticket, for: atlas)
        #expect(applied)
    }

    // Two listings overlap and the newer one comes back first: the older one is stale.
    @Test func aListingOlderThanOneAppliedIsRefused() {
        var listings = WorktreeListings()
        let older = listings.begin()
        let newer = listings.begin()
        let applied = [listings.accepts(newer, for: garden), listings.accepts(older, for: garden)]
        #expect(applied == [true, false])
    }

    @Test func listingsThatComeBackInOrderAreAllApplied() {
        var listings = WorktreeListings()
        let older = listings.begin()
        let newer = listings.begin()
        let applied = [listings.accepts(older, for: garden), listings.accepts(newer, for: garden)]
        #expect(applied == [true, true])
    }

    @Test func eachRepositoryIsOrderedOnItsOwn() {
        var listings = WorktreeListings()
        let forGarden = listings.begin()
        let forAtlas = listings.begin()
        let applied = [listings.accepts(forAtlas, for: atlas), listings.accepts(forGarden, for: garden)]
        #expect(applied == [true, true])
    }
}
