import LowtideKit
import SwiftUI

/// The doctor's last run, kept while navigating. Every check runs at once
/// and lands as soon as it finishes; the slow ones (`brew doctor`) never
/// hold back the rest.
@Observable
final class DoctorModel {
    static let shared = DoctorModel()
    let planned = Doctor.planned
    private(set) var results: [String: DoctorCheck] = [:]
    /// Checks that finished in the current run.
    private(set) var fresh: Set<String> = []
    private(set) var running = false
    private(set) var ranAt: Date?
    /// Fix ids being applied.
    private(set) var fixing: Set<String> = []

    func run() {
        guard !running else { return }
        running = true
        fresh = []
        Task {
            await withTaskGroup(of: DoctorCheck.self) { group in
                for check in planned { group.addTask { await Doctor.run(check.id) } }
                for await check in group {
                    withAnimation(Motion.base) {
                        results[check.id] = check
                        fresh.insert(check.id)
                    }
                }
            }
            ranAt = .now
            running = false
        }
    }

    func fix(_ fix: DoctorFix) {
        fixing.insert(fix.id)
        Task {
            do {
                Toasts.shared.show(try await Doctor.fix(fix.id))
            } catch {
                Toasts.shared.failure("\(fix.label) didn't work", error)
            }
            fixing.remove(fix.id)
            run()
        }
    }

    func count(_ status: DoctorStatus) -> Int { results.values.filter { $0.status == status }.count }
}

/// Developer › Toolchain › Doctor: health checks for a developer Mac, each
/// problem with where it comes from and how to fix it.
struct DoctorPage: View {
    @Environment(\.palette) private var palette
    private var model = DoctorModel.shared
    @State private var pendingFix: DoctorFix?
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Doctor", description: description) {
                EmptyView()
            } action: {
                Button {
                    model.run()
                } label: {
                    Label(model.running ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
                .disabled(model.running)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        strip { id in withAnimation(Motion.base) { proxy.scrollTo(id, anchor: .center) } }
                        ForEach(categories, id: \.self) { category in
                            categoryPane(category)
                        }
                    }
                    .padding(.horizontal, Space.page + 4)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.xxl)
                }
            }
        }
        .onAppear { if model.ranAt == nil { model.run() } }
        .confirmation(Binding(
            get: { pendingFix.map { fix in
                ConfirmRequest(title: "Apply this fix?",
                               message: "\(fix.command)\n\nRemoved files go to the Trash. The checks run again afterwards.",
                               confirm: fix.label, destructive: false) { model.fix(fix) }
            } },
            set: { if $0 == nil { pendingFix = nil } }))
    }

    private var categories: [String] {
        var seen: [String] = []
        for check in model.planned where !seen.contains(check.category) { seen.append(check.category) }
        return seen
    }

    private var description: String {
        let parts = ["\(model.count(.pass)) passed",
                     model.count(.warn) > 0 ? LowtideFormat.count(model.count(.warn), "warning") : nil,
                     model.count(.fail) > 0 ? "\(model.count(.fail)) failing" : nil,
                     model.count(.skip) > 0 ? "\(model.count(.skip)) not applicable" : nil].compactMap { $0 }
        return "\(model.planned.count) checks · " + parts.joined(separator: " · ")
    }

    /// One cell per check, coloured by its result; click to jump to it.
    private func strip(_ jump: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(model.planned) { check in
                let result = model.results[check.id]
                let pending = model.running && !model.fresh.contains(check.id)
                Button { jump(check.id) } label: {
                    Capsule().fill(result.map { cellColor($0.status) } ?? palette.fill.color)
                        .frame(height: 6)
                        .opacity(pending ? 0.45 : 1)
                        .phaseAnimator(pending ? [0.6, 1] : [1]) { view, phase in view.opacity(phase) }
                        .contentShape(.rect.inset(by: -4))
                }
                .buttonStyle(.plain)
                .help("\(check.title): \(result?.summary ?? "Checking…")")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Check results: \(description)")
    }

    private func cellColor(_ status: DoctorStatus) -> Color {
        switch status {
        case .fail: palette.bad.color
        case .warn: palette.warn.color
        case .pass: palette.ok.opacity(0.7).color
        case .skip: palette.fill.color
        }
    }

    private func categoryPane(_ category: String) -> some View {
        let checks = model.planned.filter { $0.category == category }
        let worst = checks.compactMap { model.results[$0.id]?.status }.filter { $0 == .fail || $0 == .warn }.max()
        return Pane(category) {
            if let worst {
                Badge(worst == .fail ? "Failing" : "Warning", tone: worst == .fail ? .bad : .warn)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    Hairline()
                    CheckRow(plan: check, check: model.results[check.id],
                             running: model.running && !model.fresh.contains(check.id), onFix: { pendingFix = $0 })
                        .id(check.id)
                }
            }
        }
    }
}

private struct CheckRow: View {
    @Environment(\.palette) private var palette
    let plan: PlannedCheck
    let check: DoctorCheck?
    let running: Bool
    let onFix: (DoctorFix) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                StatusGlyph(status: running ? nil : check?.status)
                Text(plan.title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                Spacer(minLength: Space.md)
                Text(check?.summary ?? "Checking…").font(.ui(.xs))
                    .foregroundStyle(summaryColor).lineLimit(1).truncationMode(.tail)
                    .help(check?.summary ?? "")
                    .textSelection(.enabled)
                Text(check != nil && !running ? LowtideFormat.duration(check?.duration ?? 0) : "")
                    .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 44)
            ForEach(check?.issues ?? []) { issue in
                Hairline(inset: Space.lg + 28)
                IssueBlock(checkID: plan.id, issue: issue, onFix: onFix)
            }
        }
    }

    private var summaryColor: Color {
        guard let check else { return palette.ink4.color }
        switch check.status {
        case .fail: return palette.bad.color
        case .warn: return palette.warn.color
        case .pass, .skip: return palette.ink3.color
        }
    }
}

private struct StatusGlyph: View {
    @Environment(\.palette) private var palette
    let status: DoctorStatus?

    var body: some View {
        Group {
            switch status {
            case nil: ProgressView().controlSize(.small)
            case .pass: Image(systemName: "checkmark.circle").foregroundStyle(palette.ok.color)
            case .warn: Image(systemName: "exclamationmark.triangle").foregroundStyle(palette.warn.color)
            case .fail: Image(systemName: "xmark.circle").foregroundStyle(palette.bad.color)
            case .skip: Image(systemName: "minus").foregroundStyle(palette.ink4.color)
            }
        }
        .font(.system(size: 14))
        .frame(width: 16, height: 16)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch status {
        case nil: "Checking"
        case .pass: "Passed"
        case .warn: "Warning"
        case .fail: "Failing"
        case .skip: "Not applicable"
        }
    }
}

/// One problem: what it is, where it comes from, what to do, and the fix
/// (a safe action Lowtide applies, or a command to copy).
private struct IssueBlock: View {
    @Environment(\.palette) private var palette
    private var model = DoctorModel.shared
    let checkID: String
    let issue: DoctorIssue
    let onFix: (DoctorFix) -> Void

    init(checkID: String, issue: DoctorIssue, onFix: @escaping (DoctorFix) -> Void) {
        self.checkID = checkID
        self.issue = issue
        self.onFix = onFix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
            if !issue.detail.isEmpty {
                ScrollView {
                    Text(issue.detail).font(.ui(.sm)).foregroundStyle(palette.ink3.color).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let path = issue.path {
                Text(Paths.tilde(path)).font(.mono(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    .help(path).textSelection(.enabled)
            }
            Text(issue.suggestion).font(.ui(.sm)).foregroundStyle(palette.ink2.color).fixedSize(horizontal: false, vertical: true)
            if let command = issue.command { ToolCommandLine(text: command) }
            HStack(spacing: Space.sm) {
                if let fix = issue.fix {
                    Button {
                        onFix(fix)
                    } label: {
                        HStack(spacing: 6) {
                            if model.fixing.contains(fix.id) { ProgressView().controlSize(.mini) }
                            Text(fix.label)
                        }
                    }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                    .disabled(model.fixing.contains(fix.id))
                }
                if checkID == "disk-space" {
                    Button("Open Cleanup") { AppModel.shared.open(Page.cleanup) }.buttonStyle(.lowtide(.secondary, size: .small))
                }
                if let source = issue.source {
                    Button {
                        Task {
                            do { try await Doctor.openInEditor(source) } catch { Toasts.shared.failure("Couldn't open the file", error) }
                        }
                    } label: {
                        Text(Paths.tilde(source)).font(.mono(.xs))
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .help("Open the shell config at this line")
                }
                if issue.command == nil {
                    Button("Copy Advice", systemImage: "doc.on.clipboard") { ToolClipboard.copy(issue.suggestion, what: "Advice") }
                        .buttonStyle(.lowtide(.quiet, size: .small))
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, Space.lg + 28)
        .padding(.trailing, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
