import Foundation

/// How suspicious an app's network behaviour looks, 0–100, with the
/// reasons. Each signal is weak alone (plenty of honest tools are unsigned
/// or poll a server); together they rank what deserves a look first.
public enum ThreatScore {
    /// At or above this an app is flagged: the hero, "Needs a look", the
    /// menu bar and the threat board all use the same line.
    public static let flag = 35

    /// Ports ordinary apps use; anything else is worth a mention.
    static let commonPorts: Set<UInt16> = [
        53, 80, 123, 443, 853, 993, 995, 465, 587, 22, 5223, 5228, 3478, 3479, 19302, 8080, 8443, 5353,
        1900, 67, 68, 143, 25, 110, 4070, 7000, 9000,
    ]

    /// What the score looks at for one app.
    public struct Input: Sendable {
        public var signature: Signature
        public var path: String?
        public var listens: [UInt16]
        public var bytesOut: Int64
        public var bytesIn: Int64
        public var hosts: Int
        /// Remote ports of its open connections.
        public var remotePorts: [UInt16]
        /// Each server it reconnects to, with when it opened each connection.
        public var opens: [(host: String, times: [Millis])]
        public var home: String

        public init(signature: Signature, path: String?, listens: [UInt16], bytesOut: Int64, bytesIn: Int64,
                    hosts: Int, remotePorts: [UInt16], opens: [(host: String, times: [Millis])], home: String) {
            self.signature = signature
            self.path = path
            self.listens = listens
            self.bytesOut = bytesOut
            self.bytesIn = bytesIn
            self.hosts = hosts
            self.remotePorts = remotePorts
            self.opens = opens
            self.home = home
        }
    }

    public static func score(_ input: Input) -> (Int, [ScoreReason]) {
        var reasons: [ScoreReason] = []
        func add(_ points: Int, _ label: String) { reasons.append(ScoreReason(label: label, points: points)) }

        switch input.signature {
        case .unsigned: add(30, "Not code-signed")
        case .adHoc: add(15, "Signed ad hoc, no known developer")
        case .development(let who): add(10, "Development build (\(who))")
        default: break
        }
        if let path = input.path {
            let hiddenOK = ["/.cargo/", "/.local/", "/.nvm/", "/.bun/", "/.rustup/", "/.vscode/", "/.cursor/"]
            let odd = ["/tmp/", "/private/tmp/", "/private/var/folders/", "/Users/Shared/"].contains { path.hasPrefix($0) }
                || path.hasPrefix(input.home + "/Downloads/")
                || (path.contains("/.") && !hiddenOK.contains { path.contains($0) })
            // Developer tools live in hidden folders all the time; only a
            // program nobody signed is suspicious for it.
            let anonymous = [.unsigned, .adHoc, .unknown].contains(input.signature)
            if odd && anonymous { add(25, "Runs from a temporary, hidden or download folder") }
        }
        if input.signature == .apple || input.signature == .appStore {
            // Apple's own daemons talk constantly and on odd ports.
            return (min(100, reasons.reduce(0) { $0 + $1.points }), reasons)
        }

        if let beacon = input.opens.lazy.compactMap({ open in beaconInterval(open.times).map { (open.host, $0) } }).first {
            add(20, "Calls home on a timer: \(beacon.0) every ~\(beacon.1)s")
        }
        let odd = Array(Set(input.remotePorts.filter { !commonPorts.contains($0) && $0 < 49152 })).sorted()
        if !odd.isEmpty {
            add(10, "Unusual remote ports: \(odd.prefix(4).map(String.init).joined(separator: ", "))")
        }
        let exposed = input.listens.filter { $0 < 49152 }
        if !exposed.isEmpty {
            add(10, "Accepts connections from the network on \(exposed.prefix(4).map(String.init).joined(separator: ", "))")
        }
        let mb: Int64 = 1_000_000
        if input.bytesOut > 50 * mb, input.bytesOut > input.bytesIn.multipliedReportingOverflow(by: 3).partialValue {
            add(15, "Uploads far more than it downloads (\(input.bytesOut / mb) MB out)")
        }
        if input.hosts > 60 { add(15, "Talks to \(input.hosts) different hosts at once") }
        return (min(100, reasons.reduce(0) { $0 + $1.points }), reasons)
    }

    /// Opens that arrive on a clock: a steady interval (low spread) of at
    /// least a few seconds, as malware check-ins do. Returns seconds.
    public static func beaconInterval(_ opens: [Millis]) -> Int? {
        guard opens.count >= 6 else { return nil }
        let gaps = zip(opens.dropFirst(), opens).map { Double($0 - $1) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard mean >= 4_000 else { return nil }
        let variance = gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)
        return sqrt(variance) / mean < 0.15 ? Int((mean / 1000).rounded()) : nil
    }

    /// A DNS name that looks machine-generated or used to smuggle data: a
    /// long, high-entropy label (DGA malware, DNS tunnelling).
    public static func oddDomain(_ name: String) -> String? {
        guard let longest = name.split(separator: ".").max(by: { $0.utf8.count < $1.utf8.count }) else { return nil }
        let length = longest.utf8.count
        if length >= 40, entropy(longest) > 3.5 { return "Very long random-looking label (possible DNS tunnelling)" }
        if length >= 16, entropy(longest) > 3.8, longest.filter(\.isNumber).count > 3 {
            return "Random-looking name (possible generated domain)"
        }
        return nil
    }

    static func entropy(_ text: Substring) -> Double {
        var counts = [Int](repeating: 0, count: 256)
        for byte in text.utf8 { counts[Int(byte)] += 1 }
        let length = Double(text.utf8.count)
        return counts.filter { $0 > 0 }.reduce(0) { sum, c in
            let p = Double(c) / length
            return sum - p * log2(p)
        }
    }
}
