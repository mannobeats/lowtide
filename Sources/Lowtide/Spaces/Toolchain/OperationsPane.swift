import LowtideKit
import SwiftUI

/// The console for package operations: a status line while updates and
/// removals run, opening into the queue and each command's live output.
/// Shown where they're started, while there's anything to show.
struct OperationsPane: View {
    @Environment(\.palette) private var palette
    private var queue = ToolUpdateQueue.shared
    /// Only this manager's operations (a manager's page); nil for all.
    var sourceID: String?
    @State private var open = false
    @State private var selectedID: String?

    init(sourceID: String? = nil) { self.sourceID = sourceID }

    private var jobs: [ToolUpdateQueue.Job] { queue.jobs.filter { sourceID == nil || $0.target.sourceID == sourceID } }

    var body: some View {
        let jobs = jobs
        if !jobs.isEmpty {
            VStack(spacing: 0) {
                header(jobs)
                if open {
                    Hairline()
                    HStack(spacing: 0) {
                        list(jobs).frame(width: 240)
                        Rectangle().fill(palette.line.color).frame(width: 1)
                        OperationLog(job: selected(jobs))
                    }
                    .frame(height: 240)
                    .transition(.opacity)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.lg))
            .card()
            .animation(Motion.base, value: open)
        }
    }

    private func selected(_ jobs: [ToolUpdateQueue.Job]) -> ToolUpdateQueue.Job? {
        jobs.first { $0.id == selectedID } ?? jobs.first { $0.status == .running }
            ?? jobs.last { !$0.status.active } ?? jobs.first
    }

    private func header(_ jobs: [ToolUpdateQueue.Job]) -> some View {
        let running = jobs.first { $0.status == .running }
        let finished = jobs.filter { !$0.status.active }.count
        let queued = jobs.filter { $0.status == .queued }.count
        let failed = jobs.filter { $0.status == .failed }.count
        let label: String
        var progress = ""
        var line = ""
        if let running {
            label = "\(running.action == .update ? "Updating" : "Removing") \(running.target.name)"
            progress = "\(finished + 1)/\(jobs.count)"
            line = running.lines.last ?? running.command ?? ""
        } else if queued > 0 {
            label = "\(queued) queued"
        } else {
            let done = jobs.filter { $0.status == .updated || $0.status == .removed }.count
            label = failed > 0 ? "\(failed) failed · \(done) done" : "Complete"
            progress = "\(finished)/\(jobs.count)"
        }
        let active = jobs.contains { $0.status.active }
        return HStack(spacing: Space.sm) {
            Button { open.toggle() } label: {
                HStack(spacing: Space.sm) {
                    if active {
                        ProgressView().controlSize(.mini)
                    } else {
                        JobGlyph(status: failed > 0 ? .failed : .updated)
                    }
                    Text("Operations").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink3.color)
                    Text(label).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if !progress.isEmpty {
                        Text(progress).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                    }
                    Text(line).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Space.sm)
                    Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ink3.color)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the output" : "Show each command's output")
            if active {
                Button { queue.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .help("Stop the running command and skip the rest")
            } else {
                Button("Clear") {
                    queue.clearFinished()
                    open = false
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 40)
    }

    private func list(_ jobs: [ToolUpdateQueue.Job]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(jobs) { job in
                    let isSelected = job.id == selected(jobs)?.id
                    Button { selectedID = job.id } label: {
                        HStack(spacing: Space.sm) {
                            JobGlyph(status: job.status)
                            Text(job.target.name).font(.ui(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                            Spacer(minLength: Space.xs)
                            Text(job.status.label).font(.ui(.xxs)).foregroundStyle(job.status.tone.color(palette).color)
                        }
                        .padding(.horizontal, Space.md)
                        .frame(height: 26)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .toolRowHover(selected: isSelected)
                }
            }
            .padding(.vertical, Space.xs)
        }
    }
}

/// One command's output, following it as it streams, like a terminal.
struct OperationLog: View {
    @Environment(\.palette) private var palette
    let job: ToolUpdateQueue.Job?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let job {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text("$ ").foregroundStyle(palette.brand.color)
                            Text(job.command ?? "\(job.target.sourceName) · \(job.target.name) (queued)").foregroundStyle(palette.ink3.color)
                        }
                        ForEach(Array(job.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(palette.ink2.color)
                        }
                        if let error = job.error {
                            Text(error).foregroundStyle((job.status == .unchanged ? palette.warn : palette.bad).color).padding(.top, 2)
                        }
                        if job.status == .updated {
                            Text("verified \(job.target.currentVersion) → \(job.version ?? job.target.latestVersion ?? "latest")"
                                 + (job.duration.map { String(format: " in %.1fs", $0) } ?? ""))
                                .foregroundStyle(palette.ok.color).padding(.top, 2)
                        }
                        if job.status == .removed {
                            Text("removed" + (job.duration.map { String(format: " in %.1fs", $0) } ?? ""))
                                .foregroundStyle(palette.ok.color).padding(.top, 2)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.mono(.xxs))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                }
            }
            .background(palette.terminal.color)
            .onChange(of: job?.lines.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: job?.id) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct JobGlyph: View {
    @Environment(\.palette) private var palette
    let status: ToolUpdateQueue.Status

    var body: some View {
        Group {
            switch status {
            case .running: ProgressView().controlSize(.mini)
            case .updated, .removed: Image(systemName: "checkmark").foregroundStyle(palette.ok.color)
            case .unchanged: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.warn.color)
            case .failed: Image(systemName: "xmark").foregroundStyle(palette.bad.color)
            case .skipped: Image(systemName: "minus").foregroundStyle(palette.ink4.color)
            case .queued: Image(systemName: "circle.dotted").foregroundStyle(palette.ink4.color)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .frame(width: 14, height: 14)
    }
}

extension ToolUpdateQueue.Status {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .updated: "Updated"
        case .unchanged: "No change"
        case .removed: "Removed"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    var tone: Tone {
        switch self {
        case .updated, .removed: .ok
        case .unchanged: .warn
        case .failed: .bad
        case .running: .brand
        case .queued, .skipped: .neutral
        }
    }
}
