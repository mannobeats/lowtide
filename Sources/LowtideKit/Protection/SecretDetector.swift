import Foundation

/// What kind of file a candidate is; decides which detectors run on it.
public enum SecretSource: Sendable, Equatable {
    case env, key, bundle, npmrc, netrc, pypirc, gitCredentials, docker, kube, aws, tfvars, tfstate, cloudJSON, history
}

/// One secret found in a file's text. Never holds the value: only a masked
/// preview (the first few characters).
public struct SecretHit: Sendable, Equatable {
    public var kind: String
    public var label: String
    public var line: Int?
    public var preview: String
    /// A known token shape, key or tool login (not a generic assignment).
    public var strong: Bool
    /// Private keys only: whether a passphrase protects it.
    public var encrypted: Bool?
    /// Looks like a test or example value.
    public var test: Bool
}

/// Credentials left lying in files: known token shapes, private keys, tool
/// logins and `KEY=value` assignments. Raw values never leave this type;
/// only a masked preview is reported. Pure functions, tested in
/// `ProtectionSecretTests` with real-world shapes and look-alikes.
public enum SecretDetector {
    // MARK: Which files

    static let histories: Set<String> = [
        ".zsh_history", ".bash_history", ".local/share/fish/fish_history", ".python_history", ".node_repl_history",
        ".psql_history", ".mysql_history",
    ]

    /// The decoys Lowtide plants on purpose are never a finding.
    static var decoys: Set<String> { Set(Decoys.kinds.map(\.relative)) }

    static let keyNames: Set<String> = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
    static let envTemplates = ["example", "sample", "template", "dist", "defaults"]

    static let skipDirs: Set<String> = [
        "node_modules", ".git", "target", ".venv", "venv", "vendor", ".Trash", "Caches", ".cache", ".npm",
        ".pnpm-store", ".yarn", ".rustup", ".nvm", ".bun", ".pyenv", ".rbenv", ".gem", ".gradle", ".m2", ".vscode",
        ".cursor", ".oh-my-zsh", ".terraform", ".next", ".turbo", "__pycache__", "site-packages", "DerivedData", "Pods",
    ]
    static let skipSuffixes = [".app", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".framework", ".bundle", ".xcarchive"]
    static let synced = ["Library/Mobile Documents", "Library/CloudStorage", "Dropbox", "Google Drive"]
    static let testDirs: Set<String> = [
        "test", "tests", "__tests__", "fixtures", "__fixtures__", "testdata", "spec", "mocks", "example", "examples",
    ]

    /// What a file is, or nil when it is not worth reading.
    public static func classify(_ path: String, home: String) -> SecretSource? {
        let url = URL(fileURLWithPath: path)
        if let relative = RunRules.under(path, home).map(String.init) {
            if decoys.contains(relative) { return nil }
            if histories.contains(relative) { return .history }
            switch relative {
            case ".docker/config.json": return .docker
            case ".kube/config": return .kube
            case ".aws/credentials": return .aws
            default: break
            }
        }
        let name = url.lastPathComponent
        let ext = url.pathExtension
        switch name {
        case ".npmrc": return .npmrc
        case ".netrc": return .netrc
        case ".pypirc": return .pypirc
        case ".git-credentials": return .gitCredentials
        case "terraform.tfstate", "terraform.tfstate.backup": return .tfstate
        case "credentials.json": return .cloudJSON
        default: break
        }
        if name == ".env" || (name.hasPrefix(".env.") && !envTemplates.contains { name.dropFirst(5).contains($0) }) {
            return .env
        }
        if name.hasPrefix("service-account"), ext == "json" { return .cloudJSON }
        let inSSH = url.deletingLastPathComponent().path == home + "/.ssh"
        if keyNames.contains(name) || ext == "pem" || ext == "key" || (inSSH && !sshPublic(name)) { return .key }
        switch ext {
        case "p12", "pfx": return .bundle
        case "tfvars": return .tfvars
        default: return nil
        }
    }

    /// Files in `~/.ssh` that are never private keys.
    static func sshPublic(_ name: String) -> Bool {
        name.hasSuffix(".pub") || name.hasPrefix("known_hosts") || name.hasPrefix(".")
            || ["config", "authorized_keys", "environment"].contains(name)
    }

    /// A folder the sweep never enters.
    static func skipped(_ name: String, parent: String) -> Bool {
        skipDirs.contains(name) || skipSuffixes.contains { name.hasSuffix($0) }
            || (parent == ".cargo" && (name == "registry" || name == "git"))
    }

    // MARK: Masking

    static let testMarkers = ["example", "test", "dummy", "fake", "sample", "xxxxxxxx", "00000000"]

    /// At most the first 6 characters (a quarter for short values), then dots.
    public static func mask(_ value: String) -> String {
        String(value.prefix(min(value.count / 4, 6))) + "••••"
    }

    static func hit(_ kind: String, _ label: String, _ line: Int, _ value: String, strong: Bool) -> SecretHit {
        let lower = value.lowercased()
        return SecretHit(kind: kind, label: label, line: line, preview: mask(value), strong: strong, encrypted: nil,
                         test: testMarkers.contains { lower.contains($0) })
    }

    // MARK: Token shapes

    enum Charset {
        case alnum, word, url, urlDot, upperDigit, hex, alnumDash

        func allows(_ b: UInt8) -> Bool {
            let alnum = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
            switch self {
            case .alnum: return alnum
            case .word: return alnum || b == 95
            case .url: return alnum || b == 95 || b == 45
            case .urlDot: return alnum || b == 95 || b == 45 || b == 46
            case .upperDigit: return (b >= 65 && b <= 90) || (b >= 48 && b <= 57)
            case .hex: return (b >= 48 && b <= 57) || (b >= 97 && b <= 102)
            case .alnumDash: return alnum || b == 45
            }
        }
    }

    struct Pattern: Sendable {
        let kind: String
        let label: String
        let prefixes: [String]
        let set: Charset
        /// Length bounds of the part after the prefix.
        let min: Int
        let max: Int
        /// Extra check on the part after the prefix.
        var shape: @Sendable (Substring) -> Bool = { _ in true }
        /// Only in `.env` files and shell histories (too common elsewhere).
        var envOnly = false
    }

    /// Random-looking: digits, upper and lower case letters.
    static func mixed(_ body: Substring) -> Bool {
        body.contains(where: \.isNumber) && body.contains(where: \.isUppercase) && body.contains(where: \.isLowercase)
    }

    static func parts(_ body: Substring, _ lengths: [ClosedRange<Int>]) -> Bool {
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == lengths.count && zip(pieces, lengths).allSatisfy { $1.contains($0.utf8.count) }
    }

    static func jwt(_ body: Substring) -> Bool {
        parts(body, [7...2048, 10...4096, 10...1024])
            && body.split(separator: ".", omittingEmptySubsequences: false)[1].hasPrefix("eyJ")
    }

    static func discord(_ body: Substring) -> Bool {
        parts(body, [23...25, 6...7, 27...38])
            && body.split(separator: ".", omittingEmptySubsequences: false)[0].utf8.allSatisfy { Charset.alnum.allows($0) }
    }

    static func sendgrid(_ body: Substring) -> Bool { parts(body, [22...22, 43...43]) }

    /// Order matters: the first pattern that matches at a position wins
    /// (`sk-ant-` before the generic `sk-`).
    static let patterns: [Pattern] = [
        Pattern(kind: "aws-access-key", label: "AWS access key", prefixes: ["AKIA", "ASIA"], set: .upperDigit, min: 16, max: 16),
        Pattern(kind: "github-token", label: "GitHub token", prefixes: ["github_pat_"], set: .word, min: 22, max: 255),
        Pattern(kind: "github-token", label: "GitHub token", prefixes: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"],
                set: .alnum, min: 36, max: 40),
        Pattern(kind: "gitlab-token", label: "GitLab token", prefixes: ["glpat-"], set: .url, min: 20, max: 64),
        Pattern(kind: "slack-token", label: "Slack token", prefixes: ["xoxa-", "xoxb-", "xoxp-", "xoxo-", "xoxs-", "xoxr-"],
                set: .alnumDash, min: 10, max: 255),
        Pattern(kind: "stripe-key", label: "Stripe live key", prefixes: ["sk_live_", "rk_live_"], set: .alnum, min: 20, max: 255),
        Pattern(kind: "anthropic-key", label: "Anthropic API key", prefixes: ["sk-ant-"], set: .url, min: 32, max: 255),
        Pattern(kind: "openai-key", label: "OpenAI API key", prefixes: ["sk-proj-", "sk-svcacct-", "sk-admin-"],
                set: .url, min: 20, max: 255),
        Pattern(kind: "openai-key", label: "OpenAI API key", prefixes: ["sk-"], set: .url, min: 32, max: 255, shape: mixed),
        Pattern(kind: "google-api-key", label: "Google API key", prefixes: ["AIza"], set: .url, min: 35, max: 35),
        Pattern(kind: "huggingface-token", label: "Hugging Face token", prefixes: ["hf_"], set: .alnum, min: 30, max: 40,
                shape: mixed),
        Pattern(kind: "npm-token", label: "npm token", prefixes: ["npm_"], set: .alnum, min: 36, max: 36),
        Pattern(kind: "pypi-token", label: "PyPI token", prefixes: ["pypi-"], set: .url, min: 50, max: 255),
        Pattern(kind: "twilio-key", label: "Twilio API key", prefixes: ["SK"], set: .hex, min: 32, max: 32),
        Pattern(kind: "sendgrid-key", label: "SendGrid API key", prefixes: ["SG."], set: .urlDot, min: 66, max: 66,
                shape: sendgrid),
        Pattern(kind: "discord-token", label: "Discord bot token", prefixes: ["M", "N", "O"], set: .urlDot, min: 58, max: 75,
                shape: discord),
        Pattern(kind: "jwt", label: "JSON web token", prefixes: ["eyJ"], set: .urlDot, min: 30, max: 8192, shape: jwt,
                envOnly: true),
    ]

    static func wordByte(_ b: UInt8) -> Bool { Charset.word.allows(b) }

    /// The pattern matching at `at` and where its token ends.
    static func match(_ bytes: [UInt8], at: Int, source: SecretSource) -> (Pattern, Int)? {
        let env = source == .env || source == .history
        for pattern in patterns where env || !pattern.envOnly {
            for prefix in pattern.prefixes {
                let p = Array(prefix.utf8)
                guard at + p.count <= bytes.count, bytes[at..<(at + p.count)].elementsEqual(p) else { continue }
                let start = at + p.count
                var end = start
                while end < bytes.count, pattern.set.allows(bytes[end]) { end += 1 }
                let length = end - start
                let closed = end >= bytes.count || !Charset.alnum.allows(bytes[end])
                guard closed, (pattern.min...pattern.max).contains(length) else { continue }
                let body = String(decoding: bytes[start..<end], as: UTF8.self)
                if pattern.shape(body[...]) { return (pattern, end) }
            }
        }
        return nil
    }

    static func scanTokens(_ line: String, number: Int, source: SecretSource, into hits: inout [SecretHit]) {
        let bytes = Array(line.utf8)
        var at = 0
        while at < bytes.count {
            let boundary = at == 0 || !wordByte(bytes[at - 1])
            if boundary, let (pattern, end) = match(bytes, at: at, source: source) {
                hits.append(hit(pattern.kind, pattern.label, number, String(decoding: bytes[at..<end], as: UTF8.self), strong: true))
                at = end
                continue
            }
            at += 1
        }
    }

    /// Whether `text` holds a token of a known shape (`ghp_…`, `sk-…`, `AKIA…`).
    public static func hasToken(_ text: String) -> Bool {
        var hits: [SecretHit] = []
        scanTokens(text, number: 0, source: .history, into: &hits)
        return !hits.isEmpty
    }

    // MARK: Assignments and tool configs

    /// `KEY=value`, `key: value`, `"key": "value"`, `export KEY="value"`.
    /// `.npmrc` keys contain `:` (`//registry/:_authToken=`), so `eqOnly`.
    static func assignment(_ text: String, eqOnly: Bool) -> (key: String, value: String)? {
        var line = Substring(text.trimmingCharacters(in: .whitespaces))
        // zsh extended history: `: 1700000000:0;command`
        if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
            line = Substring(line[line.index(after: semi)...].trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("export ") { line = line.dropFirst(7) }
        if line.hasPrefix("- ") { line = line.dropFirst(2) }
        guard let split = eqOnly ? line.firstIndex(of: "=") : line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }
        let key = line[..<split].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        let raw = Substring(line[line.index(after: split)...].trimmingCharacters(in: .whitespaces))
        var value: Substring
        if let quote = raw.first, quote == "\"" || quote == "'" {
            value = raw.dropFirst().split(separator: quote, maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        } else {
            value = raw.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).first ?? ""
        }
        while value.hasSuffix(",") { value = value.dropLast() }
        return (key, String(value))
    }

    static let secretKeys = ["password", "passwd", "secret", "token", "api_key", "apikey", "private_key", "access_key"]
    static let notSecretKeys = ["_url", "_uri", "_path", "_file", "_name", "_length", "_ttl", "expir", "_type"]
    static let placeholders = [
        "your", "change", "xxx", "<", "${", "$(", "example", "placeholder", "redacted", "***", "...", "todo", "replace",
        "dummy", "fill",
    ]

    static func secretKey(_ lower: String) -> Bool {
        secretKeys.contains { lower.contains($0) } && !notSecretKeys.contains { lower.contains($0) }
    }

    /// A real-looking value, not a placeholder, reference or flag.
    static func meaningful(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.count >= 8 && !value.hasPrefix("$") && !placeholders.contains { lower.contains($0) }
            && !(lower.hasPrefix("http") && !lower.contains("@")) && Set(value).count > 1
    }

    static func genericLabel(_ lower: String) -> String {
        lower.contains("pass") ? "Password" : lower.contains("token") ? "Token" : lower.contains("secret") ? "Secret" : "API key"
    }

    static func assignmentHit(_ line: String, _ number: Int, _ source: SecretSource) -> SecretHit? {
        guard let (key, value) = assignment(line, eqOnly: source == .npmrc) else { return nil }
        let lower = key.lowercased()
        if lower.contains("secret_access_key"), value.utf8.count >= 30 {
            return hit("aws-secret-key", "AWS secret key", number, value, strong: true)
        }
        switch source {
        case .npmrc where ["_authtoken", "_auth", "_password"].contains(where: { lower.hasSuffix($0) })
            && !value.isEmpty && !value.hasPrefix("${"):
            return hit("npm-auth", "npm registry token", number, value, strong: true)
        case .kube where (lower == "token" || lower == "client-key-data") && value.utf8.count >= 16:
            return hit("kube-credential", "Kubernetes credential", number, value, strong: true)
        case .env, .tfvars, .pypirc, .tfstate, .cloudJSON:
            guard secretKey(lower), meaningful(value) else { return nil }
            return hit("assignment", genericLabel(lower), number, value, strong: false)
        default:
            return nil
        }
    }

    static func netrc(_ line: String, _ number: Int) -> SecretHit? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard let at = words.firstIndex(of: "password"), at + 1 < words.count else { return nil }
        return hit("netrc-password", "netrc password", number, String(words[at + 1]), strong: true)
    }

    static func gitCredential(_ line: String, _ number: Int) -> SecretHit? {
        guard let scheme = line.range(of: "://") else { return nil }
        let rest = line[scheme.upperBound...]
        guard let at = rest.firstIndex(of: "@"), let colon = rest[..<at].firstIndex(of: ":") else { return nil }
        let password = rest[rest.index(after: colon)..<at]
        return password.isEmpty ? nil : hit("git-credential", "Git credential", number, String(password), strong: true)
    }

    static func dockerAuth(_ line: String, _ number: Int) -> SecretHit? {
        for key in ["\"auth\"", "\"identitytoken\""] {
            var search = line.startIndex
            while let found = line.range(of: key, range: search..<line.endIndex) {
                search = found.upperBound
                let rest = line[found.upperBound...].drop(while: \.isWhitespace)
                guard rest.first == ":" else { continue }
                let after = rest.dropFirst().drop(while: \.isWhitespace)
                guard after.first == "\"" else { continue }
                let value = after.dropFirst().prefix { $0 != "\"" }
                if !value.isEmpty { return hit("docker-auth", "Docker registry login", number, String(value), strong: true) }
            }
        }
        return nil
    }

    static func sourceSpecific(_ line: String, _ number: Int, _ source: SecretSource) -> SecretHit? {
        switch source {
        case .netrc: netrc(line, number)
        case .gitCredentials: gitCredential(line, number)
        case .docker: dockerAuth(line, number)
        default: assignmentHit(line, number, source)
        }
    }

    // MARK: Private keys

    /// The key type in a `-----BEGIN <type> PRIVATE KEY-----` line.
    static func pemHeader(_ line: String) -> String? {
        guard let begin = line.range(of: "-----BEGIN ") else { return nil }
        let rest = line[begin.upperBound...]
        guard let end = rest.range(of: "PRIVATE KEY-----") else { return nil }
        return rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    static func pemLabel(_ kind: String) -> String {
        switch kind {
        case "OPENSSH": "SSH private key"
        case "RSA": "RSA private key"
        case "EC": "EC private key"
        case "DSA": "DSA private key"
        default: "Private key"
        }
    }

    /// The cipher named in an `openssh-key-v1` blob (`none` = no passphrase).
    static func opensshCipher(_ body: String) -> String? {
        guard let bytes = Data(base64Encoded: body).map(Array.init) else { return nil }
        let magic = Array("openssh-key-v1\0".utf8)
        guard bytes.count >= magic.count + 4, bytes.starts(with: magic) else { return nil }
        let rest = bytes[magic.count...]
        let length = rest.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        let start = rest.startIndex + 4
        guard start + length <= bytes.count else { return nil }
        return String(decoding: bytes[start..<(start + length)], as: UTF8.self)
    }

    static func pemEncrypted(_ kind: String, _ block: ArraySlice<String>) -> Bool {
        if kind.contains("ENCRYPTED") || block.contains(where: { $0.contains("Proc-Type: 4,ENCRYPTED") }) { return true }
        guard kind == "OPENSSH" else { return false }
        let body = block.dropFirst().prefix { !$0.contains("-----END") }.map { $0.trimmingCharacters(in: .whitespaces) }.joined()
        return opensshCipher(body).map { $0 != "none" } ?? false
    }

    // MARK: A whole file

    /// Lines as Rust's `str::lines` reads them: split on `\n`, a trailing
    /// `\r` dropped, no empty last line.
    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Every secret in a file's text.
    public static func detect(_ text: String, source: SecretSource) -> [SecretHit] {
        let lines = lines(text)
        var hits: [SecretHit] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let number = index + 1
            if let kind = pemHeader(line) {
                let end = lines[index...].firstIndex { $0.contains("-----END") } ?? (lines.count - 1)
                hits.append(SecretHit(kind: "private-key", label: pemLabel(kind), line: number,
                                      preview: "BEGIN \(kind) PRIVATE KEY".replacingOccurrences(of: "  ", with: " "),
                                      strong: true, encrypted: pemEncrypted(kind, lines[index...end]), test: false))
                index = end + 1
                continue
            }
            let before = hits.count
            scanTokens(line, number: number, source: source, into: &hits)
            if hits.count == before, let found = sourceSpecific(line, number, source) { hits.append(found) }
            index += 1
        }
        return hits
    }
}
