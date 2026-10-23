import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var errorDescription: String? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "git \(command) exited with status \(status)" : trimmed
    }
}

/// Thin, typed wrapper over the git command line.
///
/// Every invocation runs with `--no-optional-locks` so Vigil never writes the
/// repository's own index and never competes with an agent for `index.lock`.
public struct GitClient: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public struct Options: Sendable {
        public var indexFile: URL?
        public var allowedExitCodes: Set<Int32> = [0]
        public var stdin: Data?
        public var timeout: Duration = .seconds(60)

        public init(indexFile: URL? = nil, allowedExitCodes: Set<Int32> = [0], stdin: Data? = nil, timeout: Duration = .seconds(60)) {
            self.indexFile = indexFile
            self.allowedExitCodes = allowedExitCodes
            self.stdin = stdin
            self.timeout = timeout
        }
    }

    // MARK: Locating git

    /// Finds a usable git binary. Prefers Homebrew/MacPorts installs over the
    /// Xcode shim so a missing Command Line Tools package cannot pop a dialog.
    public static func locate(preferred: String? = nil) async -> GitClient? {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append(preferred) }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                candidates.append("\(dir)/git")
            }
        }
        candidates.append("/usr/bin/git")

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if candidate == "/usr/bin/git" {
                // The shim fails loudly (and may prompt) when the developer tools are missing.
                let check = try? await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                    arguments: ["-p"], timeout: .seconds(10))
                guard let check, check.status == 0 else { continue }
            }
            let client = GitClient(executable: URL(fileURLWithPath: candidate))
            if (try? await client.version()) != nil { return client }
        }
        return nil
    }

    // MARK: Running

    private static let baseEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE", "GIT_PREFIX"] {
            env.removeValue(forKey: key)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GIT_FLUSH"] = "1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }()

    @discardableResult
    public func run(_ arguments: [String], in directory: URL?, options: Options = Options()) async throws -> ProcessResult {
        var env = Self.baseEnvironment
        if let indexFile = options.indexFile {
            env["GIT_INDEX_FILE"] = indexFile.path
        }
        let globalArguments = [
            "--no-optional-locks",
            "-c", "core.quotepath=off",
            "-c", "color.ui=never",
            "-c", "diff.noprefix=false",
            "-c", "diff.mnemonicPrefix=false",
            "-c", "diff.external=",
        ]
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: globalArguments + arguments,
            currentDirectory: directory,
            environment: env,
            stdin: options.stdin,
            timeout: options.timeout
        )
        guard options.allowedExitCodes.contains(result.status) else {
            throw GitError(command: arguments.joined(separator: " "), status: result.status, stderr: result.stderrText)
        }
        return result
    }

    // MARK: Repository facts

    public func version() async throws -> String {
        try await run(["--version"], in: nil, options: Options(timeout: .seconds(15))).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func layout(of path: URL) async throws -> RepoLayout {
        let top = try await run(["rev-parse", "--show-toplevel"], in: path).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let topLevel = URL(fileURLWithPath: top, isDirectory: true)
        let text = try await run(["rev-parse", "--absolute-git-dir", "--git-common-dir", "--show-object-format"], in: topLevel).stdoutText
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else {
            throw GitError(command: "rev-parse", status: 0, stderr: "Unexpected rev-parse output: \(text)")
        }
        let gitDir = URL(fileURLWithPath: lines[0], isDirectory: true)
        let commonRaw = lines[1]
        let commonDir = commonRaw.hasPrefix("/")
            ? URL(fileURLWithPath: commonRaw, isDirectory: true)
            : topLevel.appendingPathComponent(commonRaw, isDirectory: true).standardizedFileURL
        return RepoLayout(topLevel: topLevel, gitDir: gitDir, commonDir: commonDir, objectFormat: lines[2])
    }

    public func worktrees(in directory: URL) async throws -> [WorktreeInfo] {
        let text = try await run(["worktree", "list", "--porcelain"], in: directory).stdoutText
        return WorktreeListParser.parse(text)
    }

    public func status(in worktree: URL) async throws -> PorcelainStatus {
        let result = try await run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal", "--no-renames"],
            in: worktree, options: Options(timeout: .seconds(120)))
        return PorcelainStatusParser.parse(result.stdout)
    }

    public func headSubject(in worktree: URL) async -> String? {
        guard let result = try? await run(["log", "-1", "--format=%s"], in: worktree) else { return nil }
        let subject = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? nil : subject
    }

    public func revParse(_ revision: String, in worktree: URL) async -> String? {
        guard let result = try? await run(["rev-parse", "--verify", "-q", revision + "^{commit}"], in: worktree,
                                          options: Options(allowedExitCodes: [0, 1])),
              result.status == 0 else { return nil }
        let oid = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    public func treeOID(ofCommit commit: String, in worktree: URL) async -> String? {
        guard let result = try? await run(["rev-parse", "--verify", "-q", commit + "^{tree}"], in: worktree,
                                          options: Options(allowedExitCodes: [0, 1])),
              result.status == 0 else { return nil }
        let oid = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    /// The branch feature work is usually compared against, as a revision string.
    public func defaultBranch(in worktree: URL) async -> String? {
        if let result = try? await run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: worktree,
                                       options: Options(allowedExitCodes: [0, 1])),
           result.status == 0 {
            let name = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        for candidate in ["main", "master", "develop", "trunk"] {
            if await revParse("refs/heads/\(candidate)", in: worktree) != nil { return candidate }
        }
        for candidate in ["origin/main", "origin/master", "origin/develop"] {
            if await revParse("refs/remotes/\(candidate)", in: worktree) != nil { return candidate }
        }
        return nil
    }

    public func mergeBase(_ a: String, _ b: String, in worktree: URL) async -> String? {
        guard let result = try? await run(["merge-base", a, b], in: worktree, options: Options(allowedExitCodes: [0, 1])),
              result.status == 0 else { return nil }
        let oid = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    public func isAncestor(_ ancestor: String, of descendant: String, in worktree: URL) async -> Bool {
        guard let result = try? await run(["merge-base", "--is-ancestor", ancestor, descendant], in: worktree,
                                          options: Options(allowedExitCodes: [0, 1])) else { return false }
        return result.status == 0
    }

    public func emptyTreeOID(in worktree: URL) async throws -> String {
        try await run(["hash-object", "-t", "tree", "/dev/null"], in: worktree).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits reachable from `to` but not from `from`, newest first.
    public func commits(from: String, to: String, in worktree: URL, limit: Int = 50) async -> [(oid: String, subject: String)] {
        guard let result = try? await run(["log", "-z", "--format=%H%x09%s", "-n", String(limit), "\(from)..\(to)"], in: worktree) else {
            return []
        }
        return result.stdout.split(separator: 0).compactMap { record in
            let text = String(decoding: record, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { return nil }
            return (String(text[..<tab]), String(text[text.index(after: tab)...]))
        }
    }

    public func commitDate(_ commit: String, in worktree: URL) async -> Date? {
        guard let result = try? await run(["log", "-1", "--format=%ct", commit], in: worktree) else { return nil }
        guard let seconds = TimeInterval(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Diffing against the shadow index

    public func rawDiff(base: String, indexFile: URL, in worktree: URL) async throws -> [RawDiffEntry] {
        let result = try await run(
            ["diff", "--cached", "--raw", "-z", "-M", "--no-abbrev", "--no-ext-diff", base],
            in: worktree, options: Options(indexFile: indexFile, timeout: .seconds(120)))
        return RawDiffParser.parse(result.stdout)
    }

    public func numstat(base: String, indexFile: URL, in worktree: URL) async throws -> [NumstatEntry] {
        let result = try await run(
            ["diff", "--cached", "--numstat", "-z", "-M", "--no-ext-diff", base],
            in: worktree, options: Options(indexFile: indexFile, timeout: .seconds(120)))
        return NumstatParser.parse(result.stdout)
    }

    /// Unified diff for the given paths (all paths when empty).
    public func patch(base: String, paths: [String], indexFile: URL, in worktree: URL, context: Int = 3) async throws -> String {
        var arguments = ["diff", "--cached", "-M", "--no-ext-diff", "--no-color", "-p", "--unified=\(context)", base]
        if !paths.isEmpty {
            arguments.append("--")
            arguments += paths.map { ":(literal)\($0)" }
        }
        let result = try await run(arguments, in: worktree,
                                   options: Options(indexFile: indexFile, timeout: .seconds(120)))
        return result.stdoutText
    }

    /// Unified diff between two blobs. Its paths are the blob ids; callers relabel them.
    public func blobPatch(from old: String, to new: String, in worktree: URL, context: Int = 3) async throws -> String {
        let result = try await run(["diff", "--no-ext-diff", "--no-color", "-p", "--unified=\(context)", old, new],
                                   in: worktree, options: Options(timeout: .seconds(120)))
        return result.stdoutText
    }

    /// True when the object is in the repository's object store.
    public func objectExists(_ oid: String, in worktree: URL) async -> Bool {
        let result = try? await run(["cat-file", "-e", oid], in: worktree, options: Options(allowedExitCodes: [0, 1, 128]))
        return result?.status == 0
    }

    // MARK: Shadow index maintenance

    /// Makes the shadow index mirror the working tree (respecting ignore rules),
    /// skipping the given paths.
    public func shadowAddAll(indexFile: URL, excluding: [String], in worktree: URL) async throws {
        var arguments = ["add", "-A", "--ignore-errors"]
        var stdin: Data? = nil
        if excluding.isEmpty {
            arguments.append("--")
            arguments.append(".")
        } else {
            arguments += ["--pathspec-from-file=-", "--pathspec-file-nul"]
            var data = Data()
            data.append(contentsOf: Array(".".utf8)); data.append(0)
            for path in excluding {
                data.append(contentsOf: Array(":(exclude,literal)\(path)".utf8))
                data.append(0)
            }
            stdin = data
        }
        // --ignore-errors keeps going but still exits 1 when something could not be indexed.
        try await run(arguments, in: worktree,
                      options: Options(indexFile: indexFile, allowedExitCodes: [0, 1], stdin: stdin, timeout: .seconds(600)))
    }

    public func writeTree(indexFile: URL, in worktree: URL) async throws -> String {
        try await run(["write-tree"], in: worktree, options: Options(indexFile: indexFile)).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func commitTree(tree: String, parent: String?, message: String, in worktree: URL) async throws -> String {
        var arguments = [
            "-c", "user.name=Vigil", "-c", "user.email=vigil@localhost",
            "-c", "commit.gpgsign=false",
            "commit-tree", tree, "-m", message,
        ]
        if let parent { arguments += ["-p", parent] }
        return try await run(arguments, in: worktree).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func updateRef(_ name: String, to oid: String, in worktree: URL) async throws {
        try await run(["update-ref", "--no-deref", name, oid], in: worktree)
    }

    public func deleteRef(_ name: String, in worktree: URL) async throws {
        try await run(["update-ref", "--no-deref", "-d", name], in: worktree, options: Options(allowedExitCodes: [0, 1]))
    }

    public func refs(withPrefix prefix: String, in worktree: URL) async throws -> [(name: String, oid: String)] {
        let result = try await run(["for-each-ref", "--format=%(refname)%09%(objectname)", prefix], in: worktree)
        return result.stdoutText.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    // MARK: Working tree queries

    /// Untracked, not-ignored files (individual paths).
    public func untrackedFiles(in worktree: URL) async throws -> [String] {
        let result = try await run(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree,
                                   options: Options(timeout: .seconds(120)))
        return result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Subset of `paths` that git ignores.
    public func ignoredPaths(among paths: [String], in worktree: URL) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var data = Data()
        for path in paths {
            data.append(contentsOf: Array(path.utf8))
            data.append(0)
        }
        guard let result = try? await run(["check-ignore", "-z", "--stdin"], in: worktree,
                                          options: Options(allowedExitCodes: [0, 1], stdin: data)) else {
            return []
        }
        return Set(result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }
}
