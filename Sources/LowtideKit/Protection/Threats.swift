import Foundation

/// One thing on the Threats page: an app the network scores as suspicious,
/// a break from an app's normal, an odd domain lookup (all from the network
/// monitor), or something Protection found on this Mac itself (an install
/// that needs a look, a decoy read, an exposed key, a broken start-up item).
public struct ThreatFinding: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        /// An app scored by its network behaviour.
        case app
        /// A break from an app's normal pattern.
        case event
        /// A suspicious domain lookup.
        case domain
        /// An install the tripwire flagged.
        case install
        /// A decoy key something read.
        case decoy
        /// A critical secret on disk.
        case secret
        /// A start-up item pointing at something gone.
        case startup
    }

    /// One reason behind an app's score: `+30 No code signature`.
    public struct Reason: Sendable, Hashable {
        public var points: Int
        public var label: String
        public init(points: Int, label: String) {
            self.points = points
            self.label = label
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// A path or one line of context, under the title.
    public var detail: String?
    /// The suspicion score (apps), 0–100.
    public var score: Int
    public var severity: Severity
    public var reasons: [Reason]
    /// One line of facts: signer, connections, traffic.
    public var summary: String?
    /// The `.app` bundle, for its icon.
    public var appPath: String?
    /// The executable or file it is about.
    public var path: String?
    public var at: Date?
    /// A run's id, for installs.
    public var runID: UInt64?

    public init(id: String, kind: Kind, title: String, detail: String? = nil, score: Int = 0, severity: Severity = .notice,
                reasons: [Reason] = [], summary: String? = nil, appPath: String? = nil, path: String? = nil, at: Date? = nil,
                runID: UInt64? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.score = score
        self.severity = severity
        self.reasons = reasons
        self.summary = summary
        self.appPath = appPath
        self.path = path
        self.at = at
        self.runID = runID
    }

    /// A score from here up is flagged (and counted in the sidebar).
    public static let flag = 35

    public enum Level: String, Sendable { case high, medium, low, clear }

    public static func level(_ score: Int) -> Level {
        score >= 60 ? .high : score >= flag ? .medium : score > 0 ? .low : .clear
    }

    public var flagged: Bool { kind == .app ? score >= Self.flag : severity == .alert }

    /// What Protection itself found on this Mac in the last week, worst first.
    public static func local(runs: [Run], decoys: Decoys.Status?, exposure: ExposureReport?,
                             permissions: PermissionMap.Snapshot?, now: Date = .now) -> [ThreatFinding] {
        let week = UInt64(max(now.timeIntervalSince1970 - 7 * 86_400, 0) * 1000)
        var found: [ThreatFinding] = []
        for run in runs where run.ecosystem != nil && run.verdict == .alert && run.started >= week {
            found.append(ThreatFinding(
                id: "install:\(run.id)", kind: .install, title: RunWords.shortCommand(run.command),
                detail: run.findings.first?.text, severity: .alert, at: run.startedAt, runID: run.id))
        }
        for decoy in decoys?.decoys ?? [] {
            guard let trip = decoy.trips.first, trip.t >= week else { continue }
            let lead = trip.suspects.first.map { ", \($0.comm) started around then" } ?? ""
            found.append(ThreatFinding(
                id: "decoy:\(decoy.id)", kind: .decoy, title: "Something read the decoy \(decoy.imitates)",
                detail: decoy.path + lead, severity: .alert, path: decoy.path, at: Clock.date(trip.t)))
        }
        for finding in exposure?.findings ?? [] where finding.severity == .critical && !finding.ignored {
            found.append(ThreatFinding(
                id: "secret:\(finding.id)", kind: .secret, title: "\(finding.label) exposed",
                detail: finding.location, severity: .alert, path: finding.path))
        }
        for app in permissions?.apps ?? [] where app.broken {
            let item = app.background.first(where: \.missing)
            found.append(ThreatFinding(
                id: "startup:\(app.key)", kind: .startup, title: "\(app.name) starts something that's gone",
                detail: item?.executable ?? item?.plist, severity: .notice, appPath: app.installed ? app.path : nil,
                path: item?.plist ?? item?.executable))
        }
        return found.sorted { ($1.severity, $1.at ?? .distantPast) < ($0.severity, $0.at ?? .distantPast) }
    }
}
