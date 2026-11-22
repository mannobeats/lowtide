import LowtideKit
import SwiftUI

/// How network figures read.
enum NetFormat {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
    static func clock(_ t: Millis) -> String { clock(t.date) }

    static func rate(_ bytes: Int64) -> String { LowtideFormat.rate(Double(bytes)) }

    /// `api.github.com:443`, or the address when there is no name.
    static func endpoint(_ host: String?, _ ip: String, _ port: UInt16) -> String {
        "\(host ?? ip)\(port > 0 ? ":\(port)" : "")"
    }

    static func ms(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "" }

    static func countries(_ n: Int) -> String { LowtideFormat.count(n, "country", "countries") }

    /// Risk level words and tones.
    static func level(_ score: Int) -> (String, Tone) {
        score >= 60 ? ("Risk \(score)", .bad) : score >= ThreatScore.flag ? ("Risk \(score)", .warn)
            : score > 0 ? ("Risk \(score)", .neutral) : ("Clear", .ok)
    }
}

/// An app's icon: its bundle's, else the executable's.
struct AppGlyph: View {
    @Environment(\.palette) private var palette
    let path: String?
    var size: CGFloat = 20

    var body: some View {
        if let path, path.hasSuffix(".app") {
            FileIcon(path: path, size: size)
        } else {
            // A command-line tool: Finder's icon for a bare executable is a blank page.
            Image(systemName: path == nil ? "app.dashed" : "terminal").font(.system(size: size * 0.8)).frame(width: size, height: size)
                .foregroundStyle(palette.ink3.color).accessibilityHidden(true)
        }
    }
}

/// Starts or stops packet capture. Asking for access is part of starting.
struct CaptureButton: View {
    private var model = NetworkModel.shared
    var primary: Bool?

    init(primary: Bool? = nil) { self.primary = primary }

    var body: some View {
        let running = model.overview.capture.running
        Button {
            Task { await model.toggleCapture() }
        } label: {
            Label(running ? "Stop capture" : "Capture packets", systemImage: running ? "stop.fill" : "record.circle")
        }
        .buttonStyle(.lowtide(primary ?? !running ? .primary : .secondary, size: .small))
        .disabled(model.capturePending)
        .help(running ? "Stop capturing packets" : model.overview.capture.permitted
            ? "Record every packet: DNS names, TLS server names and HTTP requests"
            : "Capturing packets needs access to /dev/bpf*; macOS asks for your password once (until restart)")
    }
}

/// A heading for a section of the Live side column: folds its body away
/// (remembered), with a quiet meta on the right.
struct HUDSection<Content: View, Meta: View>: View {
    @Environment(\.palette) private var palette
    @AppStorage private var open: Bool
    let title: String
    @ViewBuilder var meta: Meta
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder meta: () -> Meta, @ViewBuilder content: () -> Content) {
        self.title = title
        self.meta = meta()
        self.content = content()
        _open = AppStorage(wrappedValue: true, "network.hud.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Button {
                    withAnimation(Motion.base) { open.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.ink4.color).rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(open ? "Fold \(title)" : "Show \(title)")
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.sm)
                meta.font(.ui(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 34)
            if open { content.padding(.horizontal, Space.xs).padding(.bottom, Space.sm).transition(.opacity) }
        }
    }
}

/// A row in the side column people can click.
struct HUDRow<Content: View>: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .padding(.horizontal, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.md))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
