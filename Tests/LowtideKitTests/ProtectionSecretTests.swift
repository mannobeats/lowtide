import Foundation
import Testing
@testable import LowtideKit

/// Random-looking, never token-shaped in the source (so no scanner flags
/// this file): digits, upper and lower case.
private func r(_ length: Int) -> String { String(String(repeating: "aB3x9Kq", count: length / 7 + 1).prefix(length)) }

private func kinds(_ text: String, _ source: SecretSource = .env) -> [String] {
    SecretDetector.detect(text, source: source).map(\.kind)
}

@Suite struct ProtectionSecretTests {
    @Test func detectsEveryTokenShape() {
        let cases: [(String, String)] = [
            ("AKIA" + String(repeating: "Q7ZX", count: 4), "aws-access-key"),
            ("ASIA" + String(repeating: "Q7ZX", count: 4), "aws-access-key"),
            ("ghp_" + r(36), "github-token"),
            ("gho_" + r(40), "github-token"),
            ("github_pat_" + r(22) + "_" + r(59), "github-token"),
            ("glpat-" + r(20), "gitlab-token"),
            ("xoxb-1234567890-" + r(24), "slack-token"),
            ("sk_live_" + r(24), "stripe-key"),
            ("rk_live_" + r(24), "stripe-key"),
            ("sk-ant-api03-" + r(80), "anthropic-key"),
            ("sk-proj-" + r(40), "openai-key"),
            ("sk-svcacct-" + r(40), "openai-key"),
            ("sk-" + r(48), "openai-key"),
            ("AIza" + r(35), "google-api-key"),
            ("hf_" + r(34), "huggingface-token"),
            ("npm_" + r(36), "npm-token"),
            ("pypi-" + r(60), "pypi-token"),
            ("SK" + String(repeating: "0a1b2c3d", count: 4), "twilio-key"),
            ("SG." + r(22) + "." + r(43), "sendgrid-key"),
            ("M" + r(23) + "." + r(6) + "." + r(27), "discord-token"),
            ("eyJ" + r(20) + ".eyJ" + r(30) + "." + r(30), "jwt"),
        ]
        for (token, kind) in cases {
            #expect(kinds("KEY=\(token)") == [kind], "\(kind)")
        }
    }

    @Test func findsTokensInRealLines() {
        let token = "ghp_" + r(36)
        // Quoted, in a URL, in a JSON value, after a colon, at the end of a sentence.
        #expect(kinds("export GH_TOKEN=\"\(token)\"") == ["github-token"])
        #expect(kinds("https://x-access-token:\(token)@github.com/a/b.git") == ["github-token"])
        #expect(kinds("{\"token\": \"\(token)\"}", .cloudJSON) == ["github-token"])
        #expect(kinds("token:\(token).", .history) == ["github-token"])
        // Two on one line both count.
        #expect(kinds("A=\(token) B=npm_\(r(36))") == ["github-token", "npm-token"])
    }

    @Test func ignoresLookAlikes() {
        let lookAlikes: [(String, SecretSource)] = [
            ("ghp_" + r(20), .env),                                   // too short
            ("ghp_" + r(41), .env),                                   // too long
            ("xghp_" + r(36), .env),                                  // glued into a word
            ("ZAKIA" + String(repeating: "Q7ZX", count: 4), .env),    // not at a word boundary
            ("AKIA" + String(repeating: "q7zx", count: 4), .env),     // lower case is not an access key
            ("AKIA" + String(repeating: "Q7ZX", count: 4) + "Q", .env), // 17 characters
            ("sk-abc123", .env),                                      // a short sk- id
            ("sk-" + String(repeating: "abcdefgh", count: 6), .env),  // not random-looking
            ("sk_test_" + r(24), .env),                               // Stripe test keys are fine
            ("hf_" + String(repeating: "abcdefg", count: 5), .env),   // not random-looking
            ("glpat-" + r(10), .env),                                 // too short
            ("xoxb-12345", .env),                                     // too short
            ("AIza" + r(34), .env),                                   // one short
            ("npm_" + r(35), .env),                                   // one short
            ("pypi-" + r(40), .env),                                  // too short
            ("SK" + String(repeating: "0A1B2C3D", count: 4), .env),   // upper-case hex is a different id
            ("SG." + r(22) + "." + r(40), .env),                      // wrong second part
            ("M" + r(23) + "." + r(4) + "." + r(27), .env),           // wrong middle part
            ("eyJ" + r(20) + "." + r(30), .env),                      // two parts is not a JWT
            ("eyJ" + r(20) + ".eyJ" + r(30) + "." + r(30), .tfvars),  // JWTs only in env and history
            ("github_pat_" + r(10), .env),                            // too short
            ("-----BEGIN PUBLIC KEY-----", .key),                     // public keys are public
            ("-----BEGIN CERTIFICATE-----", .key),
            ("API_TOKEN=your-token-here", .env),                      // placeholder
            ("TOKEN_URL=https://x.dev/token", .env),                  // a URL, not a secret
            ("SECRET=${VAULT_SECRET}", .env),                         // a reference
            ("PASSWORD=$(cat /run/secret)", .env),                    // a command
            ("DB_PASSWORD=aaaaaaaaaaaa", .env),                       // one repeated character
            ("PASSWORD=hunter", .env),                                // too short to be real
            ("DB_PASSWORD_FILE=/run/secrets/db", .env),               // names a file
            ("TOKEN_TTL=86400000", .env),                             // a setting about tokens
            ("API_KEY=<paste here>", .env),
            ("SECRET_KEY=changeme123", .env),
            ("PASSWORD=************", .env),
            ("//registry.npmjs.org/:_authToken=${NPM_TOKEN}", .npmrc), // an env reference
            ("machine github.com login me", .netrc),                  // no password
            ("https://me@github.com", .gitCredentials),               // no password
            ("{\"auths\":{\"r\":{\"auth\":\"\"}}}", .docker),         // empty login
            ("    token: short", .kube),                              // too short for a token
            ("DB_PASSWORD=" + r(16), .history),                       // generic assignments only in config files
        ]
        #expect(lookAlikes.count >= 20)
        for (text, source) in lookAlikes {
            #expect(kinds(text, source).isEmpty, "\(text)")
        }
    }

    @Test func genericAssignmentsSkipPlaceholders() {
        let env = "DB_PASSWORD=\"\(r(16))\"\nAPI_TOKEN=your-token-here\nTOKEN_URL=https://x.dev/token\nSECRET=${VAULT}\n"
        let hits = SecretDetector.detect(env, source: .env)
        #expect(hits.count == 1)
        #expect(hits.first?.label == "Password" && hits.first?.line == 1 && hits.first?.strong == false)
        #expect(SecretDetector.detect("STRIPE_TOKEN: \(r(20))", source: .tfvars).first?.label == "Token")
        #expect(SecretDetector.detect("- client_secret: \(r(20))", source: .cloudJSON).first?.label == "Secret")
    }

    @Test func masksWithoutRevealing() {
        let token = "ghp_" + r(36)
        let hit = SecretDetector.detect(token, source: .env)[0]
        #expect(hit.preview == String(token.prefix(6)) + "••••")
        #expect(!hit.preview.contains(r(36)))
        #expect(SecretDetector.mask("abcdefgh") == "ab••••")
        #expect(SecretDetector.mask("abc") == "••••")
        // Test-looking values say so.
        #expect(SecretDetector.detect("sk_live_EXAMPLE" + r(20), source: .env).first?.test == true)
    }

    @Test func knownTokensForDisplay() {
        #expect(SecretDetector.hasToken("ghp_" + r(36)))
        #expect(!SecretDetector.hasToken("git push origin main"))
        #expect(!SecretDetector.hasToken("eyJ" + r(5)))
    }

    private func openssh(_ cipher: String) -> String {
        var blob = Array("openssh-key-v1\0".utf8)
        let length = UInt32(cipher.utf8.count)
        blob += [UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)]
        blob += Array(cipher.utf8) + [UInt8](repeating: 0, count: 40)
        let body = Data(blob).base64EncodedString()
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    @Test func privateKeysAndTheirPassphrases() {
        let open = SecretDetector.detect(openssh("none"), source: .key)
        #expect(open.count == 1 && open[0].encrypted == false && open[0].label == "SSH private key")
        #expect(SecretDetector.detect(openssh("aes256-ctr"), source: .key)[0].encrypted == true)
        let rsa = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n\(r(64))\n-----END RSA PRIVATE KEY-----"
        #expect(SecretDetector.detect(rsa, source: .key)[0].encrypted == true)
        #expect(SecretDetector.detect("-----BEGIN ENCRYPTED PRIVATE KEY-----", source: .key)[0].encrypted == true)
        let json = "{\"private_key\": \"-----BEGIN PRIVATE KEY-----\\n\(r(40))\\n-----END PRIVATE KEY-----\\n\"}"
        let hits = SecretDetector.detect(json, source: .cloudJSON)
        #expect(hits.count == 1 && hits[0].encrypted == false && hits[0].preview == "BEGIN PRIVATE KEY")
        // The key's body is not scanned again for tokens.
        let ec = "-----BEGIN EC PRIVATE KEY-----\nAKIA\(String(repeating: "Q7ZX", count: 4))\n-----END EC PRIVATE KEY-----\n"
        #expect(kinds(ec, .key) == ["private-key"])
    }

    @Test func toolConfigs() {
        let secret = r(40)
        #expect(kinds("machine x login me password \(r(12))", .netrc) == ["netrc-password"])
        #expect(kinds("https://me:\(r(12))@github.com", .gitCredentials) == ["git-credential"])
        #expect(kinds("{\"auths\":{\"r\":{\"auth\":\"\(r(20))\"}}}", .docker) == ["docker-auth"])
        #expect(kinds("{\"identitytoken\" : \"\(r(20))\"}", .docker) == ["docker-auth"])
        #expect(kinds("    token: \(r(40))", .kube) == ["kube-credential"])
        #expect(kinds("    client-key-data: \(r(40))", .kube) == ["kube-credential"])
        #expect(kinds("//registry.npmjs.org/:_authToken=\(r(20))", .npmrc) == ["npm-auth"])
        #expect(kinds("aws_secret_access_key = \(secret)", .aws) == ["aws-secret-key"])
        #expect(kinds("export AWS_SECRET_ACCESS_KEY=\(secret)", .history) == ["aws-secret-key"])
        // zsh extended history lines.
        #expect(kinds(": 1700000000:0;export AWS_SECRET_ACCESS_KEY=\(secret)", .history) == ["aws-secret-key"])
        let token = "eyJ" + r(20) + ".eyJ" + r(30) + "." + r(30)
        #expect(kinds(": 1700000000:0;curl -H \(token)", .history) == ["jwt"])
    }

    @Test func decoysLookRealToTheDetector() {
        #expect(kinds(Decoys.aws(), .aws) == ["aws-access-key", "aws-secret-key"])
        #expect(Set(kinds(Decoys.env())) == ["openai-key", "anthropic-key", "stripe-key"])
        #expect(kinds(Decoys.netrc(), .netrc) == ["github-token"])
        #expect(kinds(Decoys.ssh(), .key) == ["private-key"])
        #expect(kinds(Decoys.docker(), .docker) == ["docker-auth"])
        #expect(kinds(Decoys.kube(), .kube) == ["kube-credential"])
    }

    private func finding(_ change: (inout ExposureFinding) -> Void = { _ in }) -> ExposureFinding {
        var f = ExposureFinding(id: "", kind: "github-token", label: "", path: "", line: 1, preview: "", strong: true)
        change(&f)
        return f
    }

    @Test func severities() {
        #expect(ExposureFinding.level(of: finding()) == .medium)
        #expect(ExposureFinding.level(of: finding { $0.tracked = true }) == .critical)
        #expect(ExposureFinding.level(of: finding { $0.synced = true }) == .critical)
        #expect(ExposureFinding.level(of: finding { $0.tracked = true; $0.strong = false }) == .high)
        #expect(ExposureFinding.level(of: finding { $0.history = true }) == .high)
        #expect(ExposureFinding.level(of: finding { $0.encrypted = false }) == .high)
        #expect(ExposureFinding.level(of: finding { $0.encrypted = false; $0.worldReadable = true }) == .critical)
        #expect(ExposureFinding.level(of: finding { $0.encrypted = true; $0.synced = true }) == .low)
        #expect(ExposureFinding.level(of: finding { $0.test = true; $0.tracked = true }) == .low)
    }

    @Test func forgetsWholeHistoryEntries() {
        let history = Array(": 1:0;ls\n: 2:0;curl \\\n  -H secret\n: 3:0;pwd\n".utf8)
        let (kept, removed) = Exposure.forgetLines(history, [3])
        #expect(String(decoding: kept, as: UTF8.self) == ": 1:0;ls\n: 3:0;pwd\n" && removed == 2)
        let (rest, gone) = Exposure.forgetLines(Array("a\nb\n".utf8), [2, 9])
        #expect(String(decoding: rest, as: UTF8.self) == "a\n" && gone == 1)
        // A Windows line ending still continues an entry.
        let (crlf, count) = Exposure.forgetLines(Array("a \\\r\nb\nc\n".utf8), [1])
        #expect(String(decoding: crlf, as: UTF8.self) == "c\n" && count == 2)
    }

    @Test func forgetsOnlyLinesStillHoldingTheSecret() {
        let token = "ghp_" + r(36)
        let history = ": 1:0;ls\n: 2:0;export GH=\(token)\n"
        let hit = SecretDetector.detect(history, source: .history)[0]
        let wanted = [(2, hit.kind, hit.preview)]
        #expect(Exposure.stillThere(Array(history.utf8), wanted) == [2])
        // The shell trimmed its history: line 2 is now something else.
        #expect(Exposure.stillThere(Array(": 2:0;export GH=\(token)\n: 3:0;pwd\n".utf8), wanted).isEmpty)
    }

    @Test func classifiesCandidates() {
        let home = "/h"
        let source = { (path: String) in SecretDetector.classify(home + "/" + path, home: home) }
        #expect(source("p/.env.local") == .env)
        #expect(source("p/.env") == .env)
        #expect(source("p/.env.example") == nil)
        #expect(source("p/.env.sample") == nil)
        #expect(source(".env.backup") == nil)
        #expect(source(".ssh/id_rsa.old") == nil)
        #expect(source(".ssh/work") == .key)
        #expect(source(".ssh/work.pub") == nil)
        #expect(source(".ssh/known_hosts") == nil)
        #expect(source(".ssh/config") == nil)
        #expect(source("certs/server.pem") == .key)
        #expect(source("certs/me.p12") == .bundle)
        #expect(source(".local/share/fish/fish_history") == .history)
        #expect(source(".zsh_history") == .history)
        #expect(source("infra/prod.tfvars") == .tfvars)
        #expect(source("infra/terraform.tfstate") == .tfstate)
        #expect(source("gcp/service-account-prod.json") == .cloudJSON)
        #expect(source(".docker/config.json") == .docker)
        #expect(source("other/.docker/config.json") == nil)
        #expect(source(".aws/credentials") == .aws)
        #expect(source("notes/readme.txt") == nil)
        #expect(SecretDetector.skipped("node_modules", parent: "app"))
        #expect(SecretDetector.skipped("registry", parent: ".cargo"))
        #expect(!SecretDetector.skipped("registry", parent: "app"))
        #expect(SecretDetector.skipped("Xcode.app", parent: "Applications"))
    }

    @Test func findingIDsAreStable() {
        let a = Exposure.findingID(path: "/h/.env", kind: "github-token", line: 3)
        #expect(a == Exposure.findingID(path: "/h/.env", kind: "github-token", line: 3))
        #expect(a != Exposure.findingID(path: "/h/.env", kind: "github-token", line: 4))
        #expect(a.count == 16)
    }

    @Test func sweepsAFakeHome() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-exposure-\(UUID())").resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let line = "GITHUB_TOKEN=ghp_\(r(36))\n"
        for relative in ["code/app/.env", "code/app/node_modules/x/.env", "Library/Preferences/.env",
                         "Library/Mobile Documents/com~apple~CloudDocs/.env", ".env.backup", "notes/readme.txt"] {
            let path = home + "/" + relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
        let swept = try #require(Exposure.sweep(home: home, cancelled: { false }, progress: { _, _ in }))
        let found = swept.files.map { String($0.path.dropFirst(home.count + 1)) }.sorted()
        #expect(swept.scanned == 2)
        #expect(found == ["Library/Mobile Documents/com~apple~CloudDocs/.env", "code/app/.env"])
        #expect(Exposure.sweep(home: home, cancelled: { true }, progress: { _, _ in }) == nil)
    }

    @Test func storeFixesForgetsAndIgnores() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lowtide-store-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home").path
        try FileManager.default.createDirectory(atPath: home + "/code", withIntermediateDirectories: true)
        let history = home + "/.zsh_history"
        let token = "ghp_" + r(36)
        try Data(": 1:0;ls\n: 2:0;export GH=\(token)\n: 3:0;pwd\n".utf8).write(to: URL(fileURLWithPath: history))
        let env = home + "/code/.env"
        try Data("STRIPE=sk_live_\(r(24))\n".utf8).write(to: URL(fileURLWithPath: env))
        chmod(env, 0o644)
        let store = Exposure(home: home, file: root.appending(path: "exposure.json"))
        let result = try #require(await store.scan { _ in })
        #expect(result.report.findings.count == 2)
        let stripe = try #require(result.report.findings.first { $0.path == env })
        #expect(stripe.worldReadable)

        try await store.fixPermissions(env)
        #expect(await store.last()?.findings.first { $0.path == env }?.worldReadable == false)

        let removed = try await store.forgetHistory(history, lines: [2])
        #expect(removed == 1)
        #expect(try String(contentsOfFile: history, encoding: .utf8) == ": 1:0;ls\n: 3:0;pwd\n")
        #expect(await store.last()?.findings.contains { $0.path == history } == false)

        await store.ignore(stripe.id, true)
        #expect(await store.last()?.findings.first?.ignored == true)
        // Saved and read back by a fresh store.
        let again = Exposure(home: home, file: root.appending(path: "exposure.json"))
        #expect(await again.last()?.findings.first?.ignored == true)
        await #expect(throws: LowtideError.self) { try await again.fixPermissions(home + "/other") }
    }
}

@Suite struct ProtectionExposureWatchTests {
    /// FSEvents reports `/private/tmp/…` for a home under `/tmp`: a change
    /// must land on the reported file, and a decoy must stay a decoy.
    @Test func changesUnderASymlinkedHomeMatchTheReport() async throws {
        let home = "/tmp/lowtide-watch-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/app", withIntermediateDirectories: true)
        let token = "ghp_" + String(String(repeating: "aB3x9Kq", count: 6).prefix(36))
        try Data("GH=\(token)\n".utf8).write(to: URL(fileURLWithPath: home + "/app/.env"))
        let store = Exposure(home: home, file: URL(fileURLWithPath: home + "/exposure.json"))
        _ = await store.scan { _ in }
        try Data(Decoys.env().utf8).write(to: URL(fileURLWithPath: home + "/.env.backup"))
        #expect(await !store.matters("/private" + home + "/.env.backup"))
        try Data("nothing here\n".utf8).write(to: URL(fileURLWithPath: home + "/app/.env"))
        await store.refresh("/private" + home + "/app/.env")
        #expect(await store.last()?.findings.isEmpty == true)
    }
}
