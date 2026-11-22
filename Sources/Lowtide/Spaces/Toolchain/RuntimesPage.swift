import LowtideKit
import SwiftUI

/// The runtimes on this Mac, kept while navigating (ten minutes fresh).
@Observable
final class RuntimesModel {
    static let shared = RuntimesModel()
    private(set) var runtimes: [LanguageRuntime]?
    private(set) var checking = false
    private var checkedAt: Date?

    func load(force: Bool = false) {
        guard !checking else { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 600 { return }
        checking = true
        Task {
            let found = await Runtimes.all()
            withAnimation(Motion.base) { runtimes = found }
            checkedAt = .now
            checking = false
        }
    }
}

/// Developer › Toolchain › Runtimes: which version of each language runs,
/// who installed it, what else hides on PATH, and how long its release
/// line stays supported.
struct RuntimesPage: View {
    @Environment(\.palette) private var palette
    private var model = RuntimesModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Runtimes", description: description) {
                EmptyView()
            } action: {
                Button {
                    model.load(force: true)
                } label: {
                    Label(model.checking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
                .disabled(model.checking)
            }
            content
        }
        .onAppear { model.load() }
    }

    private var description: String? {
        guard let runtimes = model.runtimes else { return nil }
        let attention = runtimes.filter { $0.standing == .eol || $0.standing == .behind }.count
        let shadowed = runtimes.filter { !$0.shadowed.isEmpty }.count
        return [LowtideFormat.count(runtimes.count, "runtime"),
                attention > 0 ? "\(attention) behind or unsupported" : "all supported",
                shadowed > 0 ? "\(LowtideFormat.count(shadowed, "duplicate")) on PATH" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let runtimes = model.runtimes {
            if runtimes.isEmpty {
                EmptyState("No language runtimes found", symbol: "cube",
                           message: "Node, Python, Ruby, Go and friends show up here once they're on your PATH.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: Space.lg) {
                            Text("Runtime").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Version").frame(width: RuntimeColumns.version, alignment: .leading)
                            AxisLabels().frame(width: RuntimeColumns.axis)
                            Color.clear.frame(width: RuntimeColumns.copy, height: 1)
                        }
                        .font(.ui(.xs, .medium)).foregroundStyle(palette.ink3.color)
                        .padding(.horizontal, Space.lg).padding(.top, 10).padding(.bottom, 6)
                        ForEach(runtimes) { runtime in
                            Hairline()
                            RuntimeRow(runtime: runtime)
                        }
                    }
                    .clipShape(.rect(cornerRadius: Radius.lg))
                    .card()
                    .padding(.horizontal, Space.page + 4)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.xxl)
                }
            }
        } else {
            ScanningState(title: "Reading runtimes and release lines")
        }
    }
}

/// Runtime, version, support axis, copy: the columns every row shares.
private enum RuntimeColumns {
    static let version: CGFloat = 190
    static let axis: CGFloat = 280
    static let copy: CGFloat = 28
}

/// The support axis spans five years from today, one tick a year.
private enum Axis {
    static let years = 5
    static let year: TimeInterval = 365 * 86_400
}

private struct AxisLabels: View {
    @Environment(\.palette) private var palette
    var body: some View {
        GeometryReader { geo in
            let start = Calendar.current.component(.year, from: .now)
            ForEach(1..<Axis.years, id: \.self) { n in
                Text(String(start + n)).font(.ui(.xxs)).foregroundStyle(palette.ink4.color).monospacedDigit()
                    .fixedSize()
                    .position(x: geo.size.width * CGFloat(n) / CGFloat(Axis.years), y: 7)
            }
        }
        .frame(height: 14)
    }
}

private struct RuntimeRow: View {
    @Environment(\.palette) private var palette
    let runtime: LanguageRuntime
    @State private var hovering = false

    private static let marks = ["node": "node", "python": "python", "ruby": "ruby", "go": "go", "rust": "rust",
                                "php": "php", "deno": "deno", "bun": "bun", "java": "java"]

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
                HStack(alignment: .top, spacing: Space.md) {
                    SourceTile(mark: Self.marks[runtime.id] ?? "terminal")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(runtime.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                            Text(runtime.manager).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        }
                        Text(Paths.tilde(runtime.path)).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                            .lineLimit(1).truncationMode(.middle).help(runtime.path).textSelection(.enabled)
                        ForEach(runtime.shadowed, id: \.self) { path in
                            Text("Also on PATH: \(Text(Paths.tilde(path)).font(.mono(.xxs)))")
                                .font(.ui(.xs)).foregroundStyle(palette.warn.color).lineLimit(1).truncationMode(.middle)
                                .help("Another copy later on PATH. Tools launched with a shorter PATH may run it instead.")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                version.frame(width: RuntimeColumns.version, alignment: .leading)
                SupportAxis(runtime: runtime).frame(width: RuntimeColumns.axis)
                Group {
                    if let hint = runtime.upgradeHint {
                        IconButton("doc.on.clipboard", help: hint) { ToolClipboard.copy(hint, what: "Command") }
                            .opacity(hovering ? 1 : 0)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: RuntimeColumns.copy)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .toolRowHover()
        .contextMenu {
            if let hint = runtime.upgradeHint { Button("Copy Upgrade Command") { ToolClipboard.copy(hint, what: "Command") } }
            Button("Copy Path") { ToolClipboard.copy(runtime.path, what: "Path") }
            Button("Show in Finder") { Files.reveal([runtime.path]) }
        }
    }

    private var version: some View {
        let newerLine = runtime.latest != nil && runtime.cycleLatest != nil && runtime.latest != runtime.cycleLatest
        let line = [runtime.cycle.map { "\($0) line" }, runtime.lts ? "LTS" : nil,
                    newerLine ? runtime.latest.map { "newest \($0)" } : nil].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(runtime.version).foregroundStyle((runtime.standing == .eol ? palette.bad : palette.ink).color)
                if runtime.standing == .behind, let latest = runtime.cycleLatest {
                    Text(" → \(latest)").foregroundStyle(palette.warn.color)
                }
            }
            .font(.mono(.sm)).monospacedDigit().textSelection(.enabled)
            if !line.isEmpty { Text(line).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1) }
        }
    }
}

/// How long the installed line stays supported, on the shared five-year
/// axis: green with a year or more to go, amber inside the last year, red
/// once it has ended.
private struct SupportAxis: View {
    @Environment(\.palette) private var palette
    let runtime: LanguageRuntime

    private var eolDate: Date? {
        runtime.eol.flatMap { text in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: text)
        }
    }

    var body: some View {
        let ended = runtime.standing == .eol
        let remaining = eolDate.map { $0.timeIntervalSinceNow }
        let share = remaining.map { min(1, max(0, $0 / (Double(Axis.years) * Axis.year))) } ?? 0
        let tone: Tone = remaining.map { $0 < Axis.year ? .warn : .ok } ?? .ok
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill((ended ? palette.badSoft : palette.fill).color)
                    if !ended, share > 0 {
                        Capsule().fill(tone.color(palette).color).frame(width: max(geo.size.width * share, geo.size.width * 0.02))
                    }
                    ForEach(1..<Axis.years, id: \.self) { n in
                        Rectangle().fill(palette.line.color).frame(width: 1, height: 10)
                            .position(x: geo.size.width * CGFloat(n) / CGFloat(Axis.years), y: 3)
                    }
                }
            }
            .frame(height: 6)
            .padding(.top, 6)
            Text(support).font(.ui(.xs)).foregroundStyle((ended ? palette.bad : palette.ink3).color).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var support: String {
        let month = eolDate?.formatted(.dateTime.month(.abbreviated).year())
        if runtime.standing == .eol { return month.map { "Support ended \($0)" } ?? "No longer supported" }
        if let month { return "Supported until \(month)" }
        return runtime.cycle != nil ? "Supported until the next release" : "No lifecycle data"
    }
}
