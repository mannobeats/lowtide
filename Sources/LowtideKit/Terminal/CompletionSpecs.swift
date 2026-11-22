import Foundation

/// What the terminal knows about common developer commands: subcommands,
/// flags, and where their arguments come from. Arguments are filled from the
/// live folder context (branches, scripts, files…), never guessed. Order
/// matters (it breaks ties).
public struct CompletionSpec: Sendable, Decodable {
    /// Where an argument's values come from.
    public enum Generator: String, Sendable, Decodable {
        case branches, changed, dirs, formulae, hosts, just, make, paths, remotes, scripts, services
    }

    public var description: String?
    /// Where every positional argument comes from.
    public var args: [Generator]
    /// Per position instead: `git push <remote> <branch>`.
    public var positional: [Generator]?
    public var options: [(String, String)]
    public var subcommands: [(String, CompletionSpec)]

    public func subcommand(_ name: String) -> CompletionSpec? { subcommands.first { $0.0 == name }?.1 }

    enum Keys: String, CodingKey { case d, a, p, o, s }

    private struct Pair<T: Decodable>: Decodable {
        let key: String
        let value: T
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            key = try c.decode(String.self)
            value = try c.decode(T.self)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        description = try c.decodeIfPresent(String.self, forKey: .d)
        args = try c.decodeIfPresent([Generator].self, forKey: .a) ?? []
        positional = try c.decodeIfPresent([Generator].self, forKey: .p)
        options = (try c.decodeIfPresent([Pair<String>].self, forKey: .o) ?? []).map { ($0.key, $0.value) }
        subcommands = (try c.decodeIfPresent([Pair<CompletionSpec>].self, forKey: .s) ?? []).map { ($0.key, $0.value) }
    }

    /// The generators that fill the argument at `position`.
    func generators(at position: Int) -> [Generator] {
        guard let positional else { return args }
        return positional.indices.contains(position) ? [positional[position]] : []
    }
}

public enum CompletionSpecs {
    /// Words that run another command (`sudo git …`): skipped when parsing.
    public static let wrappers: Set<String> = ["sudo", "time", "nohup", "env", "exec", "command", "watch"]

    public static let all: [String: CompletionSpec] = {
        struct Entry: Decodable {
            let name: String
            let spec: CompletionSpec
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                name = try c.decode(String.self)
                spec = try c.decode(CompletionSpec.self)
            }
        }
        do {
            let entries = try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
            return Dictionary(entries.map { ($0.name, $0.spec) }, uniquingKeysWith: { a, _ in a })
        } catch {
            Log.terminal.fault("completion specs unreadable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }()

    private static let json = #"""
[
    ["brew",{"d":"Homebrew","s":[["autoremove",{"d":"Remove unused dependencies"}],["cleanup",{"d":"Remove old versions and caches","o":[["--prune=all","Everything cached"]]}],["deps",{"d":"Show dependencies","a":["formulae"],"o":[["--tree","As a tree"]]}],["doctor",{"d":"Check for problems"}],["info",{"d":"Show formula details","a":["formulae"]}],["install",{"d":"Install a formula or cask","o":[["--cask","Install an app"]]}],["leaves",{"d":"Formulae nothing depends on"}],["list",{"d":"List installed","o":[["--cask","Apps only"],["--versions","With versions"]]}],["outdated",{"d":"List outdated","o":[["--greedy","Include auto-updating casks"]]}],["pin",{"d":"Hold a formula at its version","a":["formulae"]}],["reinstall",{"d":"Reinstall","a":["formulae"]}],["search",{"d":"Search formulae and casks"}],["services",{"d":"Background services","s":[["list",{"d":"List services"}],["restart",{"d":"Restart a service","a":["formulae"]}],["start",{"d":"Start a service","a":["formulae"]}],["stop",{"d":"Stop a service","a":["formulae"]}]]}],["tap",{"d":"Add a third-party repository"}],["uninstall",{"d":"Remove","a":["formulae"]}],["unpin",{"d":"Allow upgrades again","a":["formulae"]}],["update",{"d":"Refresh Homebrew"}],["upgrade",{"d":"Upgrade","a":["formulae"]}],["uses",{"d":"What depends on a formula","o":[["--installed","Installed only"]]}]]}],
    ["bun",{"d":"Bun runtime and package manager","a":["scripts","paths"],"s":[["add",{"d":"Add a dependency","o":[["-d","As a dev dependency"],["-g","Globally"]]}],["build",{"d":"Bundle files","a":["paths"]}],["install",{"d":"Install dependencies"}],["outdated",{"d":"Show outdated dependencies"}],["remove",{"d":"Remove a dependency"}],["run",{"d":"Run a script or file","a":["scripts","paths"]}],["test",{"d":"Run tests"}],["upgrade",{"d":"Upgrade Bun itself"}],["x",{"d":"Run a package without installing"}]]}],
    ["cargo",{"d":"Rust package manager","s":[["add",{"d":"Add a dependency","o":[["--dev","As a dev dependency"],["-F","Enable features"]]}],["audit",{"d":"Check for vulnerable dependencies"}],["bench",{"d":"Run benchmarks"}],["build",{"d":"Compile","o":[["--all-targets","Include tests, benches, examples"],["--release","Optimized build"],["-p","Only this package"]]}],["check",{"d":"Type-check without building","o":[["--all-targets","Include tests, benches, examples"],["--release","Optimized build"],["-p","Only this package"]]}],["clean",{"d":"Remove the target folder"}],["clippy",{"d":"Lint","o":[["--all-targets","Include tests, benches, examples"],["--release","Optimized build"],["-p","Only this package"],["--fix","Apply suggestions"]]}],["doc",{"d":"Build documentation","o":[["--open","Open in the browser"]]}],["fmt",{"d":"Format code","o":[["--check","Only report"]]}],["init",{"d":"Make this folder a crate"}],["install",{"d":"Install a binary crate"}],["new",{"d":"Create a crate"}],["publish",{"d":"Publish to crates.io"}],["remove",{"d":"Remove a dependency"}],["run",{"d":"Build and run","o":[["--all-targets","Include tests, benches, examples"],["--release","Optimized build"],["-p","Only this package"],["--bin","Which binary"],["--example","Run an example"]]}],["test",{"d":"Run tests","o":[["--all-targets","Include tests, benches, examples"],["--release","Optimized build"],["-p","Only this package"],["--","Pass arguments to the test binary"]]}],["tree",{"d":"Show the dependency tree","o":[["-d","Duplicates only"]]}],["update",{"d":"Update the lockfile"}]]}],
    ["cd",{"d":"Change directory","a":["dirs"]}],
    ["deno",{"d":"Deno runtime","s":[["fmt",{"d":"Format"}],["lint",{"d":"Lint"}],["run",{"d":"Run a file","a":["paths"]}],["task",{"d":"Run a task"}],["test",{"d":"Run tests"}]]}],
    ["docker",{"d":"Containers","s":[["build",{"d":"Build an image","a":["dirs"],"o":[["-f","Dockerfile"],["-t","Tag"]]}],["compose",{"d":"Multi-container apps","s":[["build",{"d":"Build services","a":["services"]}],["down",{"d":"Stop and remove","o":[["-v","Also remove volumes"]]}],["exec",{"d":"Run in a running service","a":["services"]}],["logs",{"d":"Show logs","a":["services"],"o":[["--tail","Last lines"],["-f","Follow"]]}],["ps",{"d":"List services"}],["pull",{"d":"Pull images","a":["services"]}],["restart",{"d":"Restart services","a":["services"]}],["up",{"d":"Create and start","a":["services"],"o":[["--build","Rebuild images"],["-d","In the background"]]}]]}],["exec",{"d":"Run in a container","o":[["-it","Interactive terminal"]]}],["images",{"d":"List images"}],["inspect",{"d":"Show low-level details"}],["logs",{"d":"Show logs","o":[["--tail","Last lines"],["-f","Follow"]]}],["network",{"d":"Manage networks","s":[["ls",{"d":"List networks"}]]}],["ps",{"d":"List containers","o":[["-a","Include stopped"]]}],["pull",{"d":"Download an image"}],["rm",{"d":"Remove containers"}],["rmi",{"d":"Remove images"}],["run",{"d":"Start a new container","o":[["--name","Container name"],["--rm","Remove on exit"],["-d","Detached"],["-it","Interactive"],["-p","Publish a port"],["-v","Mount a volume"]]}],["start",{"d":"Start containers"}],["stop",{"d":"Stop containers"}],["system",{"d":"Docker disk and data","s":[["df",{"d":"Disk usage"}],["prune",{"d":"Remove unused data"}]]}],["volume",{"d":"Manage volumes","s":[["ls",{"d":"List volumes"}],["prune",{"d":"Remove unused volumes"}],["rm",{"d":"Remove volumes"}]]}]]}],
    ["gh",{"d":"GitHub CLI","s":[["auth",{"d":"Authentication","s":[["login",{"d":"Log in"}],["status",{"d":"Show status"}]]}],["issue",{"d":"Issues","s":[["create",{"d":"Open an issue"}],["list",{"d":"List issues"}],["view",{"d":"Show an issue"}]]}],["pr",{"d":"Pull requests","s":[["checkout",{"d":"Check out a PR"}],["checks",{"d":"Show CI checks"}],["create",{"d":"Open a PR","o":[["--draft","As a draft"],["--fill","Use commit info"]]}],["diff",{"d":"Show the diff"}],["list",{"d":"List PRs"}],["merge",{"d":"Merge a PR","o":[["--squash","Squash merge"]]}],["status",{"d":"Your PRs"}],["view",{"d":"Show a PR","o":[["--web","In the browser"]]}]]}],["release",{"d":"Releases","s":[["create",{"d":"Create a release"}],["list",{"d":"List releases"}]]}],["repo",{"d":"Repositories","s":[["clone",{"d":"Clone"}],["create",{"d":"Create"}],["fork",{"d":"Fork"}],["view",{"d":"Show","o":[["--web","In the browser"]]}]]}],["run",{"d":"Workflow runs","s":[["list",{"d":"List runs"}],["view",{"d":"Show a run"}],["watch",{"d":"Follow a run"}]]}],["workflow",{"d":"Workflows","s":[["list",{"d":"List workflows"}],["run",{"d":"Trigger a workflow"}]]}]]}],
    ["git",{"d":"Version control","s":[["add",{"d":"Stage changes","a":["changed","paths"],"o":[["-A","Stage everything"],["-p","Stage hunks interactively"]]}],["bisect",{"d":"Find the commit that broke something","s":[["bad",{"d":"Mark the current commit bad"}],["good",{"d":"Mark the current commit good"}],["reset",{"d":"End the bisect session"}],["start",{"d":"Start bisecting"}]]}],["blame",{"d":"Show who changed each line","a":["paths"]}],["branch",{"d":"List or change branches","a":["branches"],"o":[["--all","Include remote branches"],["-D","Force delete a branch"],["-d","Delete a merged branch"],["-m","Rename a branch"]]}],["checkout",{"d":"Switch branches or restore files","a":["branches","changed"],"o":[["-b","Create and switch to a branch"]]}],["cherry-pick",{"d":"Apply a commit from elsewhere","a":["branches"]}],["clone",{"d":"Copy a repository","o":[["--depth","Shallow clone"]]}],["commit",{"d":"Record staged changes","o":[["--amend","Rewrite the last commit"],["--no-edit","Keep the message when amending"],["-a","Stage tracked changes first"],["-m","Commit message"]]}],["diff",{"d":"Show changes","a":["changed","branches"],"o":[["--staged","Staged changes"],["--stat","Summary per file"]]}],["fetch",{"d":"Download remote refs","p":["remotes"],"o":[["--all","Every remote"],["--prune","Drop deleted branches"]]}],["init",{"d":"Create a repository"}],["log",{"d":"Show history","a":["branches"],"o":[["--graph","Draw the branch graph"],["--oneline","One line per commit"],["-n","Limit the count"],["-p","Include patches"]]}],["merge",{"d":"Join a branch into this one","a":["branches"],"o":[["--abort","Stop a conflicted merge"],["--no-ff","Always create a merge commit"],["--squash","Squash into one change"]]}],["pull",{"d":"Fetch and integrate","p":["remotes","branches"],"o":[["--ff-only","Refuse to merge"],["--rebase","Rebase instead"]]}],["push",{"d":"Upload commits","p":["remotes","branches"],"o":[["--force-with-lease","Force, unless someone else pushed"],["--tags","Push tags"],["-u","Set upstream"]]}],["rebase",{"d":"Replay commits onto another base","a":["branches"],"o":[["--abort","Stop the rebase"],["--continue","Continue after resolving"],["-i","Interactive"]]}],["remote",{"d":"Manage remotes","o":[["-v","Show URLs"]],"s":[["add",{"d":"Add a remote"}],["remove",{"d":"Remove a remote","a":["remotes"]}],["set-url",{"d":"Change a remote URL","a":["remotes"]}]]}],["reset",{"d":"Move HEAD or unstage","a":["changed","branches"],"o":[["--hard","Discard changes"],["--soft","Keep changes staged"]]}],["restore",{"d":"Discard or unstage file changes","a":["changed"],"o":[["--staged","Unstage"]]}],["revert",{"d":"Undo a commit with a new commit"}],["show",{"d":"Show a commit","a":["branches"]}],["stash",{"d":"Shelve changes","s":[["apply",{"d":"Apply without dropping"}],["drop",{"d":"Delete a stash"}],["list",{"d":"List stashes"}],["pop",{"d":"Apply and drop the latest"}],["push",{"d":"Stash changes","o":[["-m","Message"],["-u","Include untracked"]]}],["show",{"d":"Show a stash","o":[["-p","As a patch"]]}]]}],["status",{"d":"Show working tree state","o":[["-s","Short format"],["-sb","Short with branch"]]}],["switch",{"d":"Change branch","a":["branches"],"o":[["-c","Create and switch"]]}],["tag",{"d":"List or create tags"}],["worktree",{"d":"Work on several branches at once","s":[["add",{"d":"Check out a branch in a new folder","a":["dirs","branches"]}],["list",{"d":"List worktrees"}],["remove",{"d":"Remove a worktree","a":["dirs"]}]]}]]}],
    ["go",{"d":"Go toolchain","s":[["build",{"d":"Compile packages","o":[["-o","Output file"]]}],["env",{"d":"Print Go environment"}],["fmt",{"d":"Format packages"}],["generate",{"d":"Run go:generate"}],["get",{"d":"Add a dependency"}],["install",{"d":"Install a binary"}],["mod",{"d":"Module maintenance","s":[["download",{"d":"Download modules"}],["graph",{"d":"Print the module graph"}],["init",{"d":"Create go.mod"}],["tidy",{"d":"Add missing and remove unused modules"}],["why",{"d":"Explain why a module is needed"}]]}],["run",{"d":"Compile and run","a":["paths"]}],["test",{"d":"Run tests","o":[["-count=1","Skip the cache"],["-race","Race detector"],["-run","Filter tests"],["-v","Verbose"]]}],["vet",{"d":"Report suspicious code"}],["work",{"d":"Workspace maintenance"}]]}],
    ["just",{"d":"Run a just recipe","a":["just"]}],
    ["kubectl",{"d":"Kubernetes","o":[["-n","Namespace"]],"s":[["apply",{"d":"Apply configuration","a":["paths"],"o":[["-f","From a file"]]}],["config",{"d":"Kubeconfig","s":[["current-context",{"d":"Show the current context"}],["get-contexts",{"d":"List contexts"}],["use-context",{"d":"Switch context"}]]}],["delete",{"d":"Delete resources"}],["describe",{"d":"Show resource details"}],["exec",{"d":"Run in a pod","o":[["-it","Interactive terminal"]]}],["get",{"d":"List resources","o":[["-A","All namespaces"],["-o","Output format"],["-w","Watch"]]}],["logs",{"d":"Show pod logs","o":[["--tail","Last lines"],["-f","Follow"]]}],["port-forward",{"d":"Forward a local port"}],["rollout",{"d":"Manage rollouts","s":[["restart",{"d":"Restart"}],["status",{"d":"Watch status"}],["undo",{"d":"Roll back"}]]}],["scale",{"d":"Change replicas"}],["top",{"d":"Resource usage"}]]}],
    ["ls",{"d":"List files","a":["dirs"],"o":[["-la","Long, with hidden files"],["-lh","Long, readable sizes"]]}],
    ["make",{"d":"Run a make target","a":["make"]}],
    ["mkdir",{"d":"Create folders","a":["dirs"],"o":[["-p","With parents"]]}],
    ["npm",{"d":"Node package manager","s":[["exec",{"d":"Run a binary from node_modules"}],["outdated",{"d":"Show outdated dependencies"}],["test",{"d":"Run the test script"}],["why",{"d":"Explain why a package is installed"}],["audit",{"d":"Check for vulnerabilities","s":[["fix",{"d":"Fix what can be fixed"}]]}],["ci",{"d":"Clean install from the lockfile"}],["i",{"d":"Install dependencies"}],["init",{"d":"Create package.json"}],["install",{"d":"Install dependencies","o":[["--save-dev","As a dev dependency"],["-D","As a dev dependency"],["-g","Globally"]]}],["ls",{"d":"List installed packages","o":[["--depth=0","Top level only"]]}],["publish",{"d":"Publish to the registry"}],["run",{"d":"Run a package script","a":["scripts"]}],["start",{"d":"Run the start script"}],["uninstall",{"d":"Remove a dependency"}],["update",{"d":"Update dependencies"}],["version",{"d":"Bump the version","s":[["major",{"d":"x.0.0"}],["minor",{"d":"0.x.0"}],["patch",{"d":"0.0.x"}]]}]]}],
    ["pip",{"d":"Python packages","s":[["freeze",{"d":"Pinned list"}],["install",{"d":"Install","o":[["-r","From a requirements file"]]}],["list",{"d":"List"}],["show",{"d":"Details"}],["uninstall",{"d":"Remove"}]]}],
    ["pnpm",{"d":"Fast package manager","a":["scripts"],"o":[["--filter","Run in matching workspace packages"],["-r","In every workspace package"]],"s":[["exec",{"d":"Run a binary from node_modules"}],["outdated",{"d":"Show outdated dependencies"}],["test",{"d":"Run the test script"}],["why",{"d":"Explain why a package is installed"}],["add",{"d":"Add a dependency","o":[["-D","As a dev dependency"],["-g","Globally"],["-w","To the workspace root"]]}],["dlx",{"d":"Run a package without installing"}],["i",{"d":"Install dependencies"}],["install",{"d":"Install dependencies","o":[["--frozen-lockfile","Fail if the lockfile changes"]]}],["list",{"d":"List installed packages"}],["remove",{"d":"Remove a dependency"}],["run",{"d":"Run a package script","a":["scripts"]}],["store",{"d":"Manage the content store","s":[["prune",{"d":"Remove unused packages"}]]}],["up",{"d":"Update dependencies","o":[["--latest","Past version ranges"],["-i","Choose interactively"]]}],["update",{"d":"Update dependencies","o":[["--latest","Past version ranges"],["-i","Choose interactively"]]}]]}],
    ["python",{"d":"Python","a":["paths"],"o":[["-m","Run a module"]]}],
    ["python3",{"d":"Python","a":["paths"],"o":[["-m","Run a module"]]}],
    ["rsync",{"d":"Sync files","a":["paths","hosts"],"o":[["--delete","Remove extra files at the target"],["-avz","Archive, verbose, compressed"],["-n","Dry run"]]}],
    ["scp",{"d":"Copy over SSH","a":["paths","hosts"],"o":[["-r","Folders"]]}],
    ["ssh",{"d":"Connect to a host","a":["hosts"],"o":[["-A","Forward the agent"],["-i","Identity file"],["-J","Jump through a host"],["-L","Forward a local port"],["-p","Port"],["-v","Verbose diagnostics"]]}],
    ["uv",{"d":"Python project manager","s":[["add",{"d":"Add a dependency","o":[["--dev","As a dev dependency"]]}],["lock",{"d":"Update the lockfile"}],["pip",{"d":"pip-compatible interface","s":[["install",{"d":"Install"}],["list",{"d":"List"}]]}],["python",{"d":"Manage Python versions","s":[["install",{"d":"Install"}],["list",{"d":"List"}]]}],["remove",{"d":"Remove a dependency"}],["run",{"d":"Run in the project environment","a":["paths"]}],["sync",{"d":"Install exactly the locked set"}],["tool",{"d":"Command-line tools","s":[["install",{"d":"Install a tool"}],["list",{"d":"List tools"}],["run",{"d":"Run a tool"}],["upgrade",{"d":"Upgrade tools"}]]}],["venv",{"d":"Create a virtual environment"}]]}],
    ["yarn",{"d":"Yarn package manager","a":["scripts"],"s":[["exec",{"d":"Run a binary from node_modules"}],["outdated",{"d":"Show outdated dependencies"}],["test",{"d":"Run the test script"}],["why",{"d":"Explain why a package is installed"}],["add",{"d":"Add a dependency","o":[["-D","As a dev dependency"]]}],["dlx",{"d":"Run a package without installing"}],["install",{"d":"Install dependencies"}],["remove",{"d":"Remove a dependency"}],["run",{"d":"Run a package script","a":["scripts"]}],["up",{"d":"Update dependencies"}]]}],
    ["z",{"d":"Jump to a frequent folder","a":["dirs"]}],
    ["bat",{"a":["paths"]}],
    ["cat",{"a":["paths"]}],
    ["chmod",{"a":["paths"]}],
    ["code",{"a":["paths"]}],
    ["cp",{"a":["paths"]}],
    ["cursor",{"a":["paths"]}],
    ["head",{"a":["paths"]}],
    ["less",{"a":["paths"]}],
    ["ln",{"a":["paths"]}],
    ["mv",{"a":["paths"]}],
    ["nano",{"a":["paths"]}],
    ["nvim",{"a":["paths"]}],
    ["open",{"a":["paths"]}],
    ["rm",{"a":["paths"]}],
    ["source",{"a":["paths"]}],
    ["tail",{"a":["paths"]}],
    ["touch",{"a":["paths"]}],
    ["vim",{"a":["paths"]}],
    ["zed",{"a":["paths"]}]
]
"""#
}
