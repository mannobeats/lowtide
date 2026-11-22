import Foundation
import Testing
@testable import LowtideKit

@Suite struct SystemWidgetTests {
    @Test func ratesStayThreeDigits() {
        #expect(WidgetText.rate(0) == "0 KB/s")
        #expect(WidgetText.rate(340_400) == "340 KB/s")
        #expect(WidgetText.rate(999_400) == "999 KB/s")
        #expect(WidgetText.rate(999_600) == "1.0 MB/s")
        #expect(WidgetText.rate(1_240_000) == "1.2 MB/s")
        #expect(WidgetText.rate(9_960_000) == "10 MB/s")
        #expect(WidgetText.rate(48_000_000) == "48 MB/s")
        #expect(WidgetText.rate(1_100_000_000) == "1.1 GB/s")
    }

    @Test func valuesFormatAndClamp() {
        #expect(WidgetText.percent(0.234) == "23%")
        #expect(WidgetText.percent(1.7) == "100%")
        #expect(WidgetText.percent(-0.2) == "0%")
        #expect(WidgetText.celsius(0) == "–")
        #expect(WidgetText.celsius(64.4) == "64°")
        #expect(WidgetText.watts(8.44) == "8.4 W")
        #expect(WidgetText.watts(38.4) == "38 W")
        #expect(WidgetText.rpm(2412) == "2412")
    }

    @Test func layoutPutsAGapBetweenWidgets() {
        let (starts, total) = WidgetLayout.layout([20, 30, 10])
        #expect(starts == [0, 26, 62])
        #expect(total == 72)
        #expect(WidgetLayout.layout([]).total == 0)
    }

    @Test func sparklineFillsFromTheRight() {
        let points = WidgetLayout.sparkPoints([0, 0.5, 1], x: 0, y: 0, width: 29, height: 10)
        #expect(points.map(\.0) == [27, 28, 29])
        #expect(points.map(\.1) == [0, 5, 10])
        let long = (0..<40).map { Double($0) / 40 }
        let many = WidgetLayout.sparkPoints(long, x: 0, y: 0, width: 29, height: 10)
        #expect(many.count == WidgetLayout.spark)
        #expect(many[0].0 == 0)
        #expect(WidgetLayout.sparkPoints([2], x: 0, y: 0, width: 29, height: 10)[0].1 <= 10)
    }

    @Test func scalingUsesThePeak() {
        #expect(WidgetLayout.scaled([1, 2, 4], max: 0) == [0.25, 0.5, 1])
        #expect(WidgetLayout.scaled([5, 20], max: 10) == [0.5, 1])
        #expect(WidgetLayout.scaled([0, 0], max: 0) == [0, 0])
    }

    @Test func missingHardwareHidesItsWidget() {
        let r = WidgetReadings()
        #expect(widgetPiece(.battery, .value, r) == nil)
        #expect(widgetPiece(.fans, .value, r) == nil)
        #expect(widgetPiece(.disk, .value, r) == nil)
        if case .value = widgetPiece(.cpu, .cores, r) {} else { Issue.record("cores without cores falls back to a value") }
    }

    @Test func widthsAreFixedWhateverTheValue() throws {
        func at(_ cpu: Double) -> (Double, Double) {
            var r = WidgetReadings()
            r.cpu = cpu
            r.rateIn = cpu * 3e9
            return (WidgetRenderer.width(of: widgetPiece(.cpu, .value, r)!), WidgetRenderer.width(of: widgetPiece(.network, .speed, r)!))
        }
        #expect(at(0.01) == at(1))
        let cpu = try #require(widgetPiece(.cpu, .value, WidgetReadings()))
        let bitmap = try #require(WidgetRenderer.strip([(cpu, .ink)], dark: true))
        #expect(bitmap.height == 36)
        #expect(bitmap.template)
        #expect(stride(from: 3, to: bitmap.rgba.count, by: 4).contains { bitmap.rgba[$0] > 0 })
        // A template is black: macOS supplies the colour.
        #expect(stride(from: 0, to: bitmap.rgba.count, by: 4).allSatisfy { bitmap.rgba[$0] == 0 && bitmap.rgba[$0 + 1] == 0 && bitmap.rgba[$0 + 2] == 0 })
    }

    @Test func everyPieceDraws() throws {
        var r = WidgetReadings()
        r.cpu = 0.5; r.cores = [0.2, 0.4, 0.9, 1]; r.efficiency = 2; r.cpuHistory = [0.1, 0.5, 0.9]
        r.inHistory = [1e5, 2e6]; r.outHistory = [5e4, 1e5]; r.rateIn = 2e6; r.rateOut = 1e5
        r.disk = 0.8; r.battery = (42, true); r.cpuTemp = 71; r.systemWatts = 12; r.fanRPM = 2400; r.fanShare = 0.4
        for metric in WidgetMetric.allCases {
            for style in metric.styles {
                let piece = try #require(widgetPiece(metric, style, r), "\(metric) \(style)")
                for color in WidgetColor.allCases {
                    let bitmap = try #require(WidgetRenderer.strip([(piece, widgetTone(metric, color, r))], dark: color == .load))
                    #expect(bitmap.width > 0)
                }
            }
        }
    }

    @Test func heatFollowsEachMetricsThresholds() {
        #expect(WidgetScale.usage.heat(0.1) == 0)
        #expect(WidgetScale.usage.heat(0.3) == 0)
        #expect(abs(WidgetScale.usage.heat(0.6) - 0.5) < 1e-9)
        #expect(WidgetScale.usage.heat(0.95) == 1)
        #expect(WidgetScale.temperature.heat(40) == 0)
        #expect(WidgetScale.temperature.heat(100) == 1)
        // Less is worse for a battery: red at 20% and below.
        #expect(WidgetScale.battery.heat(0.8) == 0)
        #expect(WidgetScale.battery.heat(0.2) == 1)
        #expect(WidgetScale.battery.heat(0.05) == 1)
        // Pressure keeps memory warm however little is used.
        let pressed = WidgetScale(calm: 0.6, hot: 0.95, floor: 0.65)
        #expect(pressed.heat(0.1) == 0.65)
        #expect(pressed.heat(1) == 1)
        #expect(WidgetScale.usage.heat(.nan) == 0)
    }

    @Test func rampRunsGreenAmberRedInBothTunings() {
        for dark in [true, false] {
            #expect(widgetRamp(0, dark: dark) == WidgetSwatch.green.on(dark: dark))
            #expect(widgetRamp(0.5, dark: dark) == WidgetSwatch.amber.on(dark: dark))
            #expect(widgetRamp(1, dark: dark) == WidgetSwatch.red.on(dark: dark))
            #expect(widgetRamp(-1, dark: dark) == WidgetSwatch.green.on(dark: dark))
            #expect(widgetRamp(7, dark: dark) == WidgetSwatch.red.on(dark: dark))
            let orange = widgetRamp(0.75, dark: dark)
            #expect(orange[1] < WidgetSwatch.amber.on(dark: dark)[1] && orange[1] > WidgetSwatch.red.on(dark: dark)[1])
        }
        // Deeper on a light bar, lighter on a dark one.
        func luma(_ c: [UInt8]) -> Int { Int(c[0]) * 3 + Int(c[1]) * 6 + Int(c[2]) }
        for heat in [0, 0.25, 0.5, 0.75, 1] { #expect(luma(widgetRamp(heat, dark: true)) > luma(widgetRamp(heat, dark: false))) }
    }

    @Test func tonesFollowThePreset() {
        var r = WidgetReadings()
        r.battery = (80, true)
        #expect(widgetTone(.cpu, .mono, r) == .ink)
        #expect(widgetTone(.cpu, .load, r) == .scale(.usage))
        #expect(widgetTone(.cpu, .accent, r) == .solid(.teal))
        #expect(widgetTone(.power, .load, r) == .ink)
        #expect(widgetTone(.network, .load, r) == .solid(.blue))
        #expect(widgetTone(.battery, .accent, r) == .solid(.green))
        #expect(widgetTone(.battery, .mono, r) == .ink)
        var onBattery = WidgetReadings()
        onBattery.battery = (15, false)
        #expect(widgetTone(.battery, .accent, onBattery) == .scale(.battery))
        #expect(widgetTone(.temperature, .accent, r) == .scale(.temperature))
    }

    @Test func inkFollowsTheMenuBar() throws {
        let cpu = WidgetPiece.value(label: "CPU", value: WidgetText.percent(0.97), widest: WidgetText.percents, level: 0.97)
        let dark = try #require(WidgetRenderer.strip([(cpu, .scale(.usage))], dark: true))
        let light = try #require(WidgetRenderer.strip([(cpu, .scale(.usage))], dark: false))
        #expect(!dark.template && !light.template)
        func opaque(_ b: WidgetBitmap) -> [[UInt8]] {
            stride(from: 0, to: b.rgba.count, by: 4).filter { b.rgba[$0 + 3] == 255 }.map { Array(b.rgba[$0..<$0 + 3]) }
        }
        // The value is the hot end of the ramp; the label white on dark, black on light.
        #expect(opaque(dark).contains(WidgetSwatch.red.dark))
        #expect(opaque(light).contains(WidgetSwatch.red.light))
        #expect(stride(from: 0, to: dark.rgba.count, by: 4).contains { dark.rgba[$0..<$0 + 3] == [255, 255, 255] && dark.rgba[$0 + 3] > 0 })
        #expect(stride(from: 0, to: light.rgba.count, by: 4).contains { light.rgba[$0..<$0 + 3] == [0, 0, 0] && light.rgba[$0 + 3] > 0 })
    }

    @Test func readingsComeFromSamples() {
        var sample = SystemSample(cpu: 40, gpu: 10)
        sample.memory.total = 100
        sample.memory.used = 75
        sample.memory.pressure = .warning
        sample.cores = [CoreLoad(kind: .efficiency, usage: 50, mhz: 0), CoreLoad(kind: .performance, usage: 100, mhz: 0)]
        sample.network = NetworkRate(bytesIn: 2000, bytesOut: 100)
        sample.disk = DiskSpace(total: 100, available: 25)
        sample.fanRPM = [1200, 1800]
        let detail = SystemDetail(fans: [Fan(rpm: 1800, min: 1000, max: 5000)],
                                  battery: BatteryState(percent: 64, charging: false, plugged: false, watts: -8, celsius: 30,
                                                        cycles: 10, health: 99, minutes: 200))
        let r = WidgetReadings(samples: Array(repeating: sample, count: 40), detail: detail)
        #expect(r.cpu == 0.4 && r.gpu == 0.1 && r.memory == 0.75 && r.memoryPressure == 0.65)
        #expect(r.cores == [0.5, 1] && r.efficiency == 1)
        #expect(r.cpuHistory.count == WidgetLayout.spark)
        #expect(r.rateIn == 2000 && r.disk == 0.75 && r.fanRPM == 1800 && r.fanShare == 0.2)
        #expect(r.battery?.percent == 64)
        #expect(WidgetReadings(samples: [], detail: nil).battery == nil)
    }

    @Test func specsRoundTrip() throws {
        let specs = WidgetSpec.defaults + [WidgetSpec(id: "gpu-1", metric: .gpu, style: .ring, color: .accent)]
        let data = try JSONEncoder().encode(specs)
        #expect(try JSONDecoder().decode([WidgetSpec].self, from: data) == specs)
        #expect(WidgetSpec(metric: .network).style == .speed)
    }
}
