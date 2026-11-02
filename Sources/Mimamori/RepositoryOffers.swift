import AppKit
import MimamoriCore

/// A git repository an agent works in that Mimamori does not watch, waiting for your answer.
struct RepositoryOffer: Identifiable, Hashable {
    var root: String
    var agent: AgentKind
    var since: Date

    var id: String { root }
    var name: String { (root as NSString).lastPathComponent }
}

/// What git said about a folder an agent worked in.
struct CheckedFolder {
    /// The repository holding it; nil while git is asked, or when it is in none.
    var root: String?
    var at: Date
    var pending: Bool

    /// A folder in no repository is asked about again after a while: an agent starting a project
    /// often works in a folder before it runs `git init` there.
    var isStale: Bool { !pending && root == nil && Date().timeIntervalSince(at) > 30 }
}

enum RepositoryOfferAnswer {
    case watch, notNow, never
}

extension AppModel {
    /// Folders a hook event came from that no watched worktree holds. A repository already watched
    /// has likely gained a worktree, so its worktrees are looked for again; any other repository
    /// is offered, watched or left alone, as Settings › Agents › Hooks says.
    func agentWorks(in folders: [String], agent: AgentKind) {
        guard settings.agentRepositoryPolicy != .ignore, let git else { return }
        let filter = UnwatchedRepositoryFilter()
        for folder in Set(folders) where filter.allows(folder) {
            if let checked = checkedAgentFolders[folder], !checked.isStale { continue }
            checkedAgentFolders[folder] = CheckedFolder(root: nil, at: Date(), pending: true)
            Task {
                let root = try? await git.worktrees(in: URL(fileURLWithPath: folder, isDirectory: true)).first?.path
                checkedAgentFolders[folder] = CheckedFolder(root: root, at: Date(), pending: false)
                if let root { repositoryFound(root, agent: agent) }
            }
        }
    }

    private func repositoryFound(_ root: String, agent: AgentKind) {
        if let watched = repositories.first(where: { $0.rootPath == root }) {
            Task { await rediscoverWorktrees(for: watched.id) }
            return
        }
        guard UnwatchedRepositoryFilter().allows(root), !settings.ignoredAgentRepositories.contains(root),
              offeredRepositories.insert(root).inserted else { return }
        switch settings.agentRepositoryPolicy {
        case .ignore:
            return
        case .watch:
            Log.agents.notice("Watching \(root) because \(agent.displayName, privacy: .public) works in it")
            Task { await addRepository(at: URL(fileURLWithPath: root, isDirectory: true), select: false, fromOutside: true) }
        case .ask:
            Log.agents.notice("Offering to watch \(root), where \(agent.displayName, privacy: .public) works")
            repositoryOffers.append(RepositoryOffer(root: root, agent: agent, since: Date()))
            notifier.offerToWatch(root: root, agent: agent.displayName)
        }
    }

    func answerOffer(for root: String, _ answer: RepositoryOfferAnswer) {
        repositoryOffers.removeAll { $0.root == root }
        notifier.withdrawOffer(root: root)
        switch answer {
        case .watch:
            Task { await addRepository(at: URL(fileURLWithPath: root, isDirectory: true)) }
        case .notNow:
            break
        case .never:
            var copy = settings
            if !copy.ignoredAgentRepositories.contains(root) { copy.ignoredAgentRepositories.append(root) }
            updateSettings(copy)
        }
    }

    /// A folder or file opened with Mimamori from outside it: dropped on its Dock icon, chosen in
    /// Finder's Open With, or `open -a Mimamori <folder>`. Its repository is watched and shown.
    func openFromOutside(_ url: URL) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        let folder = isFolder.boolValue ? url : url.deletingLastPathComponent()
        Log.state.notice("Asked from outside to watch \(folder.path)")
        Task { await addRepository(at: folder, fromOutside: true) }
    }
}
