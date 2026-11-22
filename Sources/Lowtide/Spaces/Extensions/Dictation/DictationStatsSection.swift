import LowtideKit
import SwiftUI

/// Extensions › Dictation › Stats: counts kept on this Mac, never the words.
struct DictationStatsSection: View {
    @Environment(\.palette) private var palette
    private var dictation = Dictation.shared
    @Binding var confirm: ConfirmRequest?

    init(confirm: Binding<ConfirmRequest?>) { _confirm = confirm }

    var body: some View {
        let stats = dictation.stats
        let today = DictationStats.today()
        PrefsGroup("Stats") {
            if stats.counted {
                Button("Reset…") {
                    confirm = ConfirmRequest(title: "Reset dictation stats?", message: "The counts start again from zero. History isn't touched.",
                                             confirm: "Reset Stats") { Dictation.shared.resetStats() }
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
            }
        } content: {
            PrefsRow("Totals", hint: stats.counted ? nil : "Counts start with your next dictation. Only numbers are kept, never the words",
                     block: true) {
                if stats.counted {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        HStack(alignment: .top, spacing: 0) {
                            Period(label: "Today", tally: stats.total(from: today))
                            Rectangle().fill(palette.line.color).frame(width: 1)
                            Period(label: "Last 7 days", tally: stats.total(from: today - 6)).padding(.leading, Space.md)
                            Rectangle().fill(palette.line.color).frame(width: 1)
                            Period(label: "All time", tally: stats.total()).padding(.leading, Space.md)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Strip(days: stats.strip(today: today))
                        Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.xs) {
                            GridRow {
                                Figure(label: "Speaking pace", value: "\(stats.pace) words a minute")
                                Figure(label: "Time saved", value: "About \(spokenDuration(stats.saved))",
                                       hint: "Against typing at \(Int(DictationStats.typingWPM)) words a minute")
                            }
                            GridRow {
                                Figure(label: "Heard nothing", value: LowtideFormat.count(stats.empty, "time"))
                                Figure(label: "Failed", value: LowtideFormat.count(stats.failed, "time"))
                            }
                        }
                    }
                }
            }
            if !stats.speeds.isEmpty {
                PrefsRow("Model speed", hint: "Seconds of speech per second of waiting", block: true) {
                    VStack(spacing: Space.xs) {
                        ForEach(stats.speeds, id: \.model) { speed in
                            HStack(spacing: Space.md) {
                                Text(VoiceModelInfo.named(speed.model)?.name ?? (speed.model.isEmpty ? "Unknown" : speed.model))
                                    .font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                                Spacer(minLength: Space.md)
                                Text("\(String(format: "%.1f", speed.ratio))× real time · \(LowtideFormat.count(speed.dictations, "dictation"))")
                                    .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                            }
                        }
                    }
                }
            }
            let apps = stats.topApps()
            if let most = apps.first?.count, most > 0 {
                PrefsRow("Most dictated into", block: true) {
                    VStack(spacing: 6) {
                        ForEach(apps, id: \.app) { item in
                            HStack(spacing: Space.md) {
                                Text(item.app).font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                                    .frame(width: 128, alignment: .leading)
                                Meter(value: Double(item.count) / Double(most))
                                Text(item.count.formatted()).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct Period: View {
    @Environment(\.palette) private var palette
    let label: String
    let tally: DictationTally

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            Text(LowtideFormat.count(tally.words, "word")).font(.ui(.lg)).monospacedDigit().foregroundStyle(palette.ink.color)
                .contentTransition(.numericText())
            Text("\(spokenDuration(tally.seconds)) spoken · \(LowtideFormat.count(tally.dictations, "dictation"))")
                .font(.ui(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Words a day for the last month, today at the right.
private struct Strip: View {
    @Environment(\.palette) private var palette
    let days: [(day: Int, words: Int)]

    var body: some View {
        let most = max(1, days.map(\.words).max() ?? 1)
        VStack(spacing: Space.xs) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days, id: \.day) { day in
                    let ratio = Double(day.words) / Double(most)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.brand.opacity(day.words > 0 ? 1 : 0.2).color)
                        .frame(height: day.words > 0 ? max(4, 48 * ratio) : 2)
                        .frame(maxWidth: .infinity)
                        .help("\(Self.label(day.day)): \(LowtideFormat.count(day.words, "word"))")
                }
            }
            .frame(height: 48, alignment: .bottom)
            .accessibilityHidden(true)
            HStack {
                Text(days.first.map { Self.label($0.day) } ?? "")
                Spacer()
                Text("Today")
            }
            .font(.ui(.xxs))
            .foregroundStyle(palette.ink4.color)
        }
    }

    /// A local day (days since 1970) as "14 Nov".
    static func label(_ day: Int) -> String {
        Date(timeIntervalSince1970: Double(day) * 86_400)
            .formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).day().month(.abbreviated))
    }
}

private struct Figure: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var hint: String?

    var body: some View {
        HStack(spacing: Space.md) {
            Text(label).foregroundStyle(palette.ink3.color).lineLimit(1)
            Spacer(minLength: Space.md)
            Text(value).foregroundStyle(palette.ink2.color).monospacedDigit()
        }
        .font(.ui(.xs))
        .frame(height: 20)
        .help(hint ?? "")
    }
}
