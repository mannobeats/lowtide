import LowtideKit
import SwiftUI

/// Recent operations from the vault's activity log, newest first, with
/// mono timestamps only, and a live status line at the bottom.
struct SignalLog: View {
    @Environment(\.palette) private var palette
    let status: String
    @State private var entries: [Entry]?

    struct Entry: Identifiable {
        var id: String
        var action: String
        var item: String
        var source: String
        var ok: Bool
        var detail: String?
        var previous: String?
        var resulting: String?
        var at: Date

        var text: String {
            let versions = previous.flatMap { p in resulting.map { " \(p) → \($0)" } } ?? ""
            return "\(action) \(item)\(versions)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let entries, entries.isEmpty {
                Text("No operations yet. Updates and cleanups land here.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).frame(height: 32)
            }
            ForEach(entries ?? []) { entry in
                HStack(spacing: 10) {
                    Circle().fill((entry.ok ? palette.ok : palette.bad).color).frame(width: 6, height: 6)
                        .accessibilityLabel(entry.ok ? "Done" : "Failed")
                    Text(entry.text).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineLimit(1)
                        .help(entry.detail ?? "")
                    Spacer(minLength: Space.sm)
                    Text(entry.source).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    Text(Self.stamp(entry.at)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                        .frame(width: 64, alignment: .trailing)
                }
                .frame(height: 32)
            }
            HStack(spacing: 10) {
                Circle().fill(palette.brand.color).frame(width: 6, height: 6)
                Text(status).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            .frame(height: 28)
            .padding(.top, Space.xs)
        }
        .task { await load() }
    }

    private func load() async {
        guard let vault = Vault.shared else { entries = []; return }
        let rows = (try? await vault.query("SELECT * FROM activity_log ORDER BY created_at DESC LIMIT 7")) ?? []
        entries = rows.map { row in
            Entry(id: row.string("id") ?? UUID().uuidString, action: row.string("action") ?? "", item: row.string("item_name") ?? "",
                  source: row.string("source_name") ?? "", ok: row.string("status") == "success", detail: row.string("detail"),
                  previous: row.string("previous_version"), resulting: row.string("resulting_version"),
                  at: Date(timeIntervalSince1970: Double(row.int("created_at") ?? 0) / 1000))
        }
    }

    /// The time today, else the day.
    static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? NetFormat.clock(date) : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
