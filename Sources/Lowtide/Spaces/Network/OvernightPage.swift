import LowtideKit
import SwiftUI

/// Network → Overnight report: what happened while you were away (or in
/// the last hour, on request), written up as a morning report.
struct OvernightPage: View {
    @Environment(\.palette) private var palette
    private var model = NetworkModel.shared
    @State private var picked: Int64?
    @State private var recent: Briefing?
    @State private var briefing = false
    /// Set by the "Brief me" action before opening the page.
    static var briefNow = false

    var body: some View {
        let list = (recent.map { [$0] } ?? []) + model.briefings
        let selected = list.first { $0.id == picked } ?? list.first
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                PageHeader("Overnight report", description: statusLine(list.count)) {
                    EmptyView()
                } action: {
                    Button("Brief me on the last hour", action: brief)
                        .buttonStyle(.lowtide(.secondary, size: .small))
                        .disabled(briefing)
                }
                .padding(.horizontal, -(Space.page + 4))
                if list.isEmpty {
                    EmptyState("No reports yet", symbol: "moon.stars",
                               message: "Step away for twenty minutes, or close the lid. Lowtide keeps watch and has a report ready when you're back: who used the network, where it went, and anything that broke the pattern.")
                        .frame(minHeight: 320)
                } else {
                    strip(list, selected: selected)
                    if let selected {
                        BriefingView(briefing: selected).id("\(selected.kind)-\(selected.id)")
                    }
                }
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.page * 2)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            model.refreshBriefings()
            if Self.briefNow {
                Self.briefNow = false
                brief()
            }
        }
        // Opening the page is reading the report: the tab's mark clears.
        .task(id: model.unseenBriefing?.id) {
            guard let id = model.unseenBriefing?.id else { return }
            await Task.detached { NightShift.shared.markSeen(id) }.value
            model.refreshBriefings()
        }
    }

    private func statusLine(_ count: Int) -> String {
        let status = model.shiftStatus
        let watch = status.away ? "On watch since \(status.since.map { NetFormat.clock($0) } ?? "a moment ago")."
            : "You're here. The watch starts after five idle minutes."
        return "\(watch) \(LowtideFormat.count(count, "report")) kept."
    }

    private func brief() {
        briefing = true
        Task {
            let report = await Task.detached { NightShift.shared.brief(minutes: 60) }.value
            withAnimation(Motion.base) {
                recent = report
                picked = report.id
            }
            briefing = false
        }
    }

    /// Every report as a pill, newest first: the day, the time, a dot when it
    /// needs a look. Scrolls sideways when there are many.
    private func strip(_ list: [Briefing], selected: Briefing?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(list, id: \.id) { briefing in
                    let on = briefing.id == selected?.id
                    Button {
                        withAnimation(Motion.base) { picked = briefing.id }
                    } label: {
                        HStack(spacing: 6) {
                            if briefing.attention > 0 {
                                Circle().fill(palette.warn.color).frame(width: 6, height: 6).accessibilityLabel("Needs a look")
                            }
                            Text(BriefingView.day(briefing.start)).font(.ui(.xs, .medium))
                            Text(NetFormat.clock(briefing.start)).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                        }
                        .foregroundStyle((on ? palette.ink : palette.ink3).color)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background((on ? palette.selectedBrand : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .capsule)
                        .overlay(Capsule().strokeBorder(on ? .clear : palette.line.color))
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help("\(briefing.kind == "away" ? "Away" : "On request") for \(LowtideFormat.duration(Double(briefing.end - briefing.start) / 1000))")
                }
            }
            .padding(1)
        }
        .scrollIndicators(.never)
    }
}

/// A briefing as a morning report: the answer, the figures, then what
/// happened, what got installed and who used the network.
struct BriefingView: View {
    @Environment(\.palette) private var palette
    let briefing: Briefing

    static func day(_ t: Millis) -> String {
        t.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(spacing: 6) {
                Text("\(briefing.kind == "away" ? "While you were away" : "On request") · \(Self.day(briefing.start))")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                Text(briefing.headline).font(.title(.xl)).foregroundStyle(palette.ink.color)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(span).font(.ui(.sm)).monospacedDigit().foregroundStyle(palette.ink3.color)
            }
            .frame(maxWidth: .infinity)
            figures
            if !briefing.newApps.isEmpty {
                Text("\(Text("First time online:").foregroundStyle(palette.ink3.color)) \(Text(briefing.newApps.joined(separator: ", ")).foregroundStyle(palette.ink.color))")
                    .font(.ui(.sm))
            }
            if !briefing.events.isEmpty { events }
            if !briefing.installs.isEmpty { installs }
            uploaders
        }
    }

    private var span: String {
        let asleep = briefing.sleptMs > 60_000 ? " · asleep for \(LowtideFormat.duration(Double(briefing.sleptMs) / 1000))" : ""
        return "\(NetFormat.clock(briefing.start)) to \(NetFormat.clock(briefing.end)) · \(LowtideFormat.duration(Double(briefing.end - briefing.start) / 1000))\(asleep)"
    }

    private var figures: some View {
        HStack(spacing: 0) {
            ForEach(Array([("Sent", LowtideFormat.bytes(briefing.uploaded)), ("Received", LowtideFormat.bytes(briefing.downloaded)),
                           ("Apps online", "\(briefing.appCount)"), ("Countries", "\(briefing.countries.count)")].enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    Text(item.1).font(.title(.lg)).monospacedDigit().foregroundStyle(palette.ink.color)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(palette.line.color).frame(width: 1) } }
            }
        }
        .card()
    }

    private func section<Content: View>(_ title: String, meta: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                Spacer()
                if let meta { Text(meta).font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit() }
            }
            .padding(.horizontal, Space.xs)
            VStack(alignment: .leading, spacing: 0) { content() }.card()
        }
    }

    private var events: some View {
        section("What broke the pattern", meta: "\(briefing.events.count)") {
            ForEach(Array(briefing.events.enumerated()), id: \.offset) { i, event in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text(NetFormat.clock(event.t)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color).frame(width: 56, alignment: .leading)
                    Circle().fill((event.severity == "alert" ? palette.bad : palette.warn).color).frame(width: 6, height: 6)
                        .accessibilityLabel(event.severity == "alert" ? "Alert" : "Notice")
                    Text(event.text).font(.ui(.sm)).foregroundStyle(palette.ink.color).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { if i > 0 { Hairline() } }
                .contextMenu {
                    if !event.subject.isEmpty, event.kind != "away" {
                        Button("Show \(event.subject) on the Map") {
                            NetworkModel.shared.pendingTarget = .app(event.subject)
                            AppModel.shared.open(.networkLive)
                        }
                    }
                    Button("Copy") { copy(event.text) }
                }
            }
        }
    }

    private var installs: some View {
        section("Installs", meta: "\(briefing.installs.count)") {
            ForEach(Array(briefing.installs.enumerated()), id: \.offset) { i, run in
                Button {
                    RunsStore.shared.focus = UInt64(exactly: run.id)
                    AppModel.shared.open(.installWatch)
                } label: {
                    HStack(spacing: Space.md) {
                        Text(NetFormat.clock(run.t)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color).frame(width: 56, alignment: .leading)
                        Text(run.command).font(.mono(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.sm)
                        Badge(run.verdict == "alert" ? "Alert" : run.verdict == "notice" ? "Notice" : "Clean",
                              tone: run.verdict == "alert" ? .bad : run.verdict == "notice" ? .warn : .neutral)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { if i > 0 { Hairline() } }
                .help("Open the install watch")
            }
        }
    }

    @ViewBuilder
    private var uploaders: some View {
        let top = briefing.apps.filter { $0.bytesIn + $0.bytesOut > 0 }
        if !top.isEmpty {
            let most = Double(max(1, top.map { $0.bytesIn + $0.bytesOut }.max() ?? 1))
            section("Who used the network") {
                ForEach(Array(top.enumerated()), id: \.offset) { i, app in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(app.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                            Spacer()
                            Text("\(LowtideFormat.bytes(app.bytesOut)) sent · \(LowtideFormat.bytes(app.bytesIn)) received")
                                .font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                        }
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                Rectangle().fill(palette.brand.color).frame(width: geo.size.width * Double(app.bytesOut) / most)
                                Rectangle().fill(palette.ok.opacity(0.6).color).frame(width: geo.size.width * Double(app.bytesIn) / most)
                                Spacer(minLength: 0)
                            }
                            .background(palette.fill.color)
                            .clipShape(.capsule)
                        }
                        .frame(height: 4)
                        if !app.countries.isEmpty {
                            Text(app.countries.map { WorldData.shared.name($0) }.joined(separator: ", "))
                                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .overlay(alignment: .top) { if i > 0 { Hairline() } }
                }
            }
        }
    }
}
