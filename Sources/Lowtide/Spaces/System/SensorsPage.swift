import LowtideKit
import SwiftUI

/// System → Sensors and fans: every temperature sensor by where it sits,
/// the battery and the fans.
struct SensorsPage: View {
    @Environment(\.palette) private var palette
    var model = SystemModel.shared

    private static let groups: [(Sensor.Kind, String)] = [
        (.cpu, "CPU"), (.gpu, "GPU"), (.soc, "Chip package"), (.memory, "Memory"),
        (.storage, "Storage"), (.battery, "Battery"), (.other, "Around the Mac"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Sensors and fans", description: description)
            content
        }
        .systemFeed("page.sensors")
    }

    private var description: String? {
        guard let sensors = model.detail?.sensors, let hottest = sensors.map(\.celsius).max() else { return nil }
        return "\(sensors.count) temperature sensors, the hottest at \(Int(hottest.rounded()))°C"
    }

    @ViewBuilder private var content: some View {
        if let detail = model.detail {
            if detail.isEmpty {
                EmptyState("No sensors to show", symbol: "thermometer.medium",
                           message: "This Mac didn't report any temperatures, fans or battery.")
            } else {
                ScrollView {
                    SplitLayout(threshold: 760, trailing: 280, spacing: Space.page) {
                        VStack(spacing: Space.page) {
                            ForEach(Self.groups, id: \.0) { kind, label in
                                let sensors = detail.sensors.filter { $0.kind == kind }
                                if !sensors.isEmpty { SensorGroup(label: label, sensors: sensors) }
                            }
                        }
                        VStack(spacing: Space.page) {
                            if let battery = detail.battery { BatteryPane(battery: battery) }
                            if !detail.fans.isEmpty { FansPane(fans: detail.fans) }
                        }
                    }
                    .padding(.horizontal, Space.page + 4)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.page * 2)
                    .frame(maxWidth: 1180, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            }
        } else {
            ScanningState(title: "Reading sensors")
        }
    }
}

/// A label, a gauge and its value: one row of a sensor list.
private struct GaugeRow: View {
    @Environment(\.palette) private var palette
    let label: String
    /// 0–1.
    let level: Double
    let tone: Tone
    let value: String

    var body: some View {
        HStack(spacing: Space.lg) {
            Text(label).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
            Meter(value: max(0.02, min(level, 1)), tone: tone, height: 6)
                .opacity(tone == .brand ? 0.75 : 1)
                .frame(minWidth: 48, maxWidth: 144)
            Text(value).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink.color)
                .frame(width: 72, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct SensorGroup: View {
    let label: String
    let sensors: [Sensor]

    var body: some View {
        let hottest = sensors.map(\.celsius).max() ?? 0
        let average = sensors.reduce(0) { $0 + $1.celsius } / Double(max(sensors.count, 1))
        Pane(label, subtitle: "Average \(Int(average.rounded()))°, hottest \(Int(hottest.rounded()))°") {
            VStack(spacing: 0) {
                ForEach(sensors) { sensor in
                    Hairline()
                    // A temperature on a 20–110 °C scale.
                    GaugeRow(label: sensor.name, level: (sensor.celsius - 20) / 90, tone: tone(sensor.celsius),
                             value: String(format: "%.1f°", sensor.celsius))
                }
            }
        }
    }

    private func tone(_ c: Double) -> Tone { c >= 100 ? .bad : c >= 90 ? .warn : .brand }
}

private struct FansPane: View {
    let fans: [Fan]

    var body: some View {
        Pane("Fans", subtitle: "Slowest to fastest") {
            VStack(spacing: 0) {
                ForEach(fans.indices, id: \.self) { i in
                    Hairline()
                    GaugeRow(label: fans.count > 1 ? "Fan \(i + 1)" : "Fan", level: fans[i].share, tone: .brand,
                             value: "\(Int(fans[i].rpm.rounded()).formatted()) rpm")
                }
            }
        }
    }
}

private struct BatteryPane: View {
    @Environment(\.palette) private var palette
    let battery: BatteryState

    private var state: String {
        battery.charging ? "Charging" : battery.plugged ? "Plugged in, not charging" : "On battery"
    }

    private var facts: [(String, String)] {
        var facts = [("Health", battery.health > 0 ? "\(Int(battery.health.rounded()))% of new" : "–"),
                     ("Cycles", battery.cycles.formatted())]
        if battery.celsius > 0 { facts.append(("Temperature", String(format: "%.1f°C", battery.celsius))) }
        if battery.watts != 0 { facts.append(("Power", SystemFormat.watts(abs(battery.watts)))) }
        // Plugged in and not charging, the estimate means nothing.
        if let minutes = battery.minutes, battery.charging || !battery.plugged {
            facts.append((battery.charging ? "Until full" : "Until empty", SystemFormat.minutes(minutes)))
        }
        return facts
    }

    var body: some View {
        let low = battery.percent <= 20 && !battery.plugged
        Pane("Battery") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(battery.percent.rounded()))%").font(.title(.xxl)).monospacedDigit()
                        .foregroundStyle(palette.ink.color).contentTransition(.numericText())
                    Spacer()
                    Text(state).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
                Meter(value: battery.percent / 100, tone: low ? .warn : .ok, height: 8)
                VStack(spacing: 6) {
                    ForEach(facts, id: \.0) { key, value in
                        HStack {
                            Text(key).foregroundStyle(palette.ink3.color)
                            Spacer()
                            Text(value).foregroundStyle(palette.ink.color).monospacedDigit()
                        }
                        .font(.ui(.sm))
                    }
                }
                .padding(.top, Space.xs)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.lg)
        }
    }
}
