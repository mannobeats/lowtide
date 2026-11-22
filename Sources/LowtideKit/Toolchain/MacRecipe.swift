import Foundation

public struct RecipeItem: Codable, Sendable, Hashable, Identifiable {
    /// `<kind>:<key>`: `brew:ripgrep`, `cask:ghostty`, `code:biomejs.biome`.
    public var id: String
    public var name: String
    public var version: String?

    public init(id: String, name: String, version: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
    }

    init(kind: String, key: String, name: String, version: String?) {
        let trimmed = version?.trimmingCharacters(in: .whitespaces)
        self.init(id: "\(kind):\(key)", name: name, version: trimmed?.isEmpty == false ? trimmed : nil)
    }
}

public struct RecipeSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var items: [RecipeItem]

    public init(id: String, label: String, items: [RecipeItem]) {
        self.id = id
        self.label = label
        self.items = items
    }
}

/// An SSH host without secrets: no keys, passwords or identities.
public struct RecipeHost: Codable, Sendable, Hashable {
    public var group: String?
    public var hostname: String
    public var name: String
    public var port: Int
    public var user: String
}

public struct RecipeSettings: Codable, Sendable, Hashable {
    public struct Theme: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var themeId: String
    public var customThemes: [Theme]

    public init(themeId: String, customThemes: [Theme]) {
        self.themeId = themeId
        self.customThemes = customThemes
    }
}

/// Everything this Mac runs (Homebrew, global packages, App Store apps,
/// editor extensions, runtimes, SSH hosts) as one JSON file, and a bash
/// script that sets another Mac up from it.
public struct MacRecipe: Codable, Sendable, Hashable {
    public struct Machine: Codable, Sendable, Hashable {
        public var name: String
        public var os: String
        public var arch: String

        public init(name: String, os: String, arch: String) {
            self.name = name
            self.os = os
            self.arch = arch
        }
    }

    public static let format = "lowtide-recipe"
    /// Formats this version reads.
    public static let readable: Set<String> = [format]
    public static let fileExtension = ".lowtide-recipe.json"

    public var format: String
    public var version: Int
    /// Milliseconds since 1970.
    public var createdAt: Int
    public var machine: Machine
    public var sections: [RecipeSection]
    public var hosts: [RecipeHost]?
    public var settings: RecipeSettings?

    public var created: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }

    public init(machine: Machine, sections: [RecipeSection], hosts: [RecipeHost]? = nil, settings: RecipeSettings? = nil,
                createdAt: Date = .now) {
        format = Self.format
        version = 1
        self.createdAt = Int(createdAt.timeIntervalSince1970 * 1000)
        self.machine = machine
        self.sections = sections
        self.hosts = hosts
        self.settings = settings
    }

    /// Every section, with the hosts and settings as sections too.
    public var allSections: [RecipeSection] {
        var extra: [RecipeSection] = []
        if let hosts, !hosts.isEmpty {
            extra.append(RecipeSection(id: "ssh-hosts", label: "SSH hosts", items: hosts.map {
                RecipeItem(id: "host:\($0.name)", name: $0.name, version: "\($0.user)@\($0.hostname):\($0.port)")
            }))
        }
        if let settings {
            extra.append(RecipeSection(id: "settings", label: "Lowtide",
                                       items: [RecipeItem(id: "setting:theme", name: "Theme", version: settings.themeId)]
                                           + settings.customThemes.map { RecipeItem(id: "theme:\($0.id)", name: $0.name) }))
        }
        return sections + extra
    }

    public var itemCount: Int { allSections.reduce(0) { $0 + $1.items.count } }

    // MARK: Files

    /// Reads a recipe file, checking it is one.
    public static func decode(_ data: Data) throws -> MacRecipe {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = root["format"] as? String, readable.contains(format),
              root["version"] as? Int == 1, root["sections"] is [Any] else {
            throw LowtideError.invalid("This isn't a Mac recipe (version 1).")
        }
        return try JSONDecoder().decode(MacRecipe.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// `jane-s-macbook-pro.lowtide-recipe.json`.
    public static func fileName(_ machine: String) -> String {
        let slug = machine.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return (slug.isEmpty ? "mac" : slug) + fileExtension
    }

    // MARK: Diff

    public struct SectionDiff: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        /// On the other Mac, not here.
        public var missing: [RecipeItem]
        public var onlyHere: [RecipeItem]
        /// Here's version, and the other Mac's item.
        public var changed: [(here: String, item: RecipeItem)]

        public static func == (a: SectionDiff, b: SectionDiff) -> Bool {
            a.id == b.id && a.missing == b.missing && a.onlyHere == b.onlyHere && a.changed.map(\.item) == b.changed.map(\.item)
        }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// What `other` has that this Mac lacks, the reverse, and version drift.
    public func diff(_ other: MacRecipe) -> [SectionDiff] {
        let mine = Dictionary(allSections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirs = other.allSections
        let ids = theirs.map(\.id) + allSections.map(\.id).filter { id in !theirs.contains { $0.id == id } }
        return ids.compactMap { id in
            let here = mine[id]
            let there = theirs.first { $0.id == id }
            let hereItems = Dictionary((here?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let otherIDs = Set((there?.items ?? []).map(\.id))
            var missing: [RecipeItem] = []
            var changed: [(here: String, item: RecipeItem)] = []
            for item in there?.items ?? [] {
                if let local = hereItems[item.id] {
                    if let a = local.version, let b = item.version, a != b { changed.append((a, item)) }
                } else {
                    missing.append(item)
                }
            }
            let onlyHere = (here?.items ?? []).filter { !otherIDs.contains($0.id) }
            guard !missing.isEmpty || !onlyHere.isEmpty || !changed.isEmpty else { return nil }
            return SectionDiff(id: id, label: there?.label ?? here?.label ?? id, missing: missing, onlyHere: onlyHere, changed: changed)
        }
    }

    // MARK: Setup script

    /// `(kind, label, tool, install)`: `install` runs once per item with `$p` set.
    static let steps: [(kind: String, label: String, tool: String, install: String)] = [
        ("tap", "Homebrew taps", "brew", #"brew tap "$p""#),
        ("brew", "Homebrew formulae", "brew", #"brew list --formula "$p" >/dev/null 2>&1 || brew install "$p""#),
        ("cask", "Homebrew casks", "brew", #"brew list --cask "$p" >/dev/null 2>&1 || brew install --cask "$p""#),
        ("mas", "Mac App Store apps", "mas", #"mas install "$p""#),
        ("npm", "npm globals", "npm", #"npm ls -g --depth=0 "$p" >/dev/null 2>&1 || npm install -g "$p""#),
        ("pnpm", "pnpm globals", "pnpm", #"pnpm add -g "$p""#),
        ("bun", "Bun globals", "bun", #"bun add -g "$p""#),
        ("pipx", "pipx apps", "pipx", #"pipx install "$p""#),
        ("uv", "uv tools", "uv", #"uv tool install "$p""#),
        ("cargo", "Cargo binaries", "cargo", #"cargo install "$p""#),
        ("gem", "Ruby gems", "gem", #"gem list -i "^${p}\$" >/dev/null 2>&1 || gem install "$p""#),
        ("code", "VS Code extensions", "code", #"code --install-extension "$p""#),
        ("cursor", "Cursor extensions", "cursor", #"cursor --install-extension "$p""#),
    ]

    /// Single-quotes a value for bash and zsh alike.
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// A key safe to hand to an installer: never an option, never
    /// multi-line, and App Store ids are numbers.
    static func installable(kind: String, key: String) -> Bool {
        !key.isEmpty && !key.hasPrefix("-") && !key.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && (kind != "mas" || key.allSatisfy { $0.isASCII && $0.isNumber })
    }

    /// The recipe's item ids, in order, once each; only those in `only` when given.
    func itemIDs(only: Set<String>?) -> [String] {
        var seen: Set<String> = []
        return sections.flatMap(\.items).map(\.id).filter { id in
            (only?.contains(id) ?? true) && seen.insert(id).inserted
        }
    }

    /// A readable, re-runnable setup script. Written for bash, and plain
    /// enough to type into an interactive zsh (comments aside).
    public func script(only: Set<String>? = nil) -> String {
        let ids = itemIDs(only: only)
        func keys(_ kind: String) -> [String] {
            ids.compactMap { id in
                guard let colon = id.firstIndex(of: ":"), id[..<colon] == kind else { return nil }
                let key = String(id[id.index(after: colon)...])
                return Self.installable(kind: kind, key: key) ? key : nil
            }
        }
        let machineName = String(machine.name.map { $0.isNewline || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : $0 })
        var script = "#!/usr/bin/env bash\n"
        script += "# Lowtide recipe from \(machineName).\n"
        script += "# Safe to run again: anything already installed is skipped.\n"
        if ["tap", "brew", "cask"].contains(where: { !keys($0).isEmpty }) {
            script += """

                if ! command -v brew >/dev/null 2>&1; then
                  echo '==> Installing Homebrew'
                  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
                fi

                """
        }
        for step in Self.steps {
            let keys = keys(step.kind)
            guard !keys.isEmpty else { continue }
            script += "\necho \(Self.quote("==> \(step.label) (\(keys.count))"))\n"
            script += "if command -v \(step.tool) >/dev/null 2>&1; then\n  for p in \\\n"
            script += keys.map { "    \(Self.quote($0))" }.joined(separator: " \\\n") + "\n"
            script += "  do\n    \(step.install)\n  done\nelse\n  echo \(Self.quote("skipped: \(step.tool) not found"))\nfi\n"
        }
        for (kind, label) in [("go", "Go binaries"), ("runtime", "Runtimes")] {
            let names = keys(kind)
            if !names.isEmpty {
                script += "\necho \(Self.quote("==> \(label), set up by hand: \(names.joined(separator: ", "))"))\n"
            }
        }
        script += "\necho '==> Done'\n"
        return script
    }

    /// The script without comments: an interactive zsh would try to run them.
    public static func forTerminal(_ script: String) -> String {
        script.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
