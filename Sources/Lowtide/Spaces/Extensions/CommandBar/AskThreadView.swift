import LowtideKit
import SwiftUI

/// Ask, inside the bar: plain questions about this Mac, answered by Apple's
/// on-device model from Lowtide's own records. The field above is the
/// composer; this is the conversation.
struct AskThreadView: View {
    @Environment(\.palette) private var palette
    let model: CommandBarModel

    private var conversation: AskConversation { model.conversation }

    var body: some View {
        if let availability = conversation.availability, !availability.available {
            unavailable(availability.reason)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if conversation.exchanges.isEmpty { welcome }
                        ForEach(conversation.exchanges) { exchange in
                            ExchangeView(exchange: exchange, again: { conversation.again(exchange.id) })
                                .id(exchange.id)
                        }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The bar keeps one size: answers scroll inside it as they stream.
                .frame(maxHeight: .infinity)
                .onChange(of: conversation.exchanges.last?.answer) { scrollToEnd(proxy) }
                .onChange(of: conversation.exchanges.count) { scrollToEnd(proxy) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = conversation.exchanges.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    /// Suggestions for the lookups that can answer them.
    static let suggestions: [(String, String)] = [
        ("How much disk space is free?", "disk_space"),
        ("What's listening on my ports?", "local_services"),
        ("How's my battery?", "battery"),
        ("How long has this Mac been up?", "uptime"),
        ("What uploaded the most this week?", "network_usage"),
        ("Anything suspicious today?", "recent_events"),
        ("What did my last npm install do?", "command_runs"),
        ("Which countries did my apps reach today?", "countries_reached"),
        ("What happened while I was away?", "away_briefings"),
        ("Any app updates waiting?", "app_updates"),
    ]

    private var welcome: some View {
        let wired = Set(AskTools.wired.map(\.name))
        return VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask about this Mac").font(.ui(.base, .medium)).foregroundStyle(palette.ink.color)
                Text("Plain questions, answered from Lowtide’ own records. Nothing leaves the Mac.")
                    .font(.ui(.sm)).foregroundStyle(palette.ink3.color)
            }
            FlowLayout(spacing: 6) {
                ForEach(Self.suggestions.filter { wired.contains($0.1) }.map(\.0), id: \.self) { suggestion in
                    Button { conversation.ask(suggestion) } label: {
                        Text(suggestion).font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                            .padding(.horizontal, Space.md).frame(height: 26)
                            .background(palette.fill.color, in: .capsule)
                            .overlay(Capsule().strokeBorder(palette.line.color))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: Space.xs) {
            Text("The on-device assistant isn’t available").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
            Text(reason).font(.ui(.xs)).foregroundStyle(palette.ink3.color).multilineTextAlignment(.center).frame(maxWidth: 380)
            if reason.contains("System Settings") {
                Button("Open Apple Intelligence Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
                .buttonStyle(.lowtide(.secondary, size: .small))
                .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl + Space.sm)
    }
}

/// One question and its answer: the lookups the model made, its answer as
/// it streams, and how long it took.
private struct ExchangeView: View {
    @Environment(\.palette) private var palette
    let exchange: AskExchange
    let again: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 80)
                Text(exchange.question)
                    .font(.ui(.sm)).foregroundStyle(palette.ink.color)
                    .padding(.horizontal, 14).padding(.vertical, Space.sm)
                    .background(palette.brandSoft.color, in: UnevenRoundedRectangle(
                        topLeadingRadius: Radius.lg, bottomLeadingRadius: Radius.lg, bottomTrailingRadius: 3, topTrailingRadius: Radius.lg))
                    .textSelection(.enabled)
            }
            if !exchange.lookups.isEmpty { lookups }
            if exchange.state == .looking, exchange.answer.isEmpty { Thinking(since: exchange.startedAt) }
            if !exchange.answer.isEmpty {
                Text(Self.markdown(exchange.answer))
                    .font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                    .frame(maxWidth: 560, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let error = exchange.error {
                Text(error).font(.ui(.xs)).foregroundStyle(palette.bad.color)
            }
            if let ended = exchange.endedAt { footer(ended) }
        }
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    private var lookups: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(exchange.lookups.enumerated()), id: \.offset) { index, lookup in
                // Every lookup but the one in flight has its answer.
                let done = !(exchange.state == .looking && index == exchange.lookups.count - 1)
                HStack(spacing: Space.sm) {
                    Group {
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(palette.ok.color)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 14)
                    Text((done ? "Checked " : "Checking ") + AskTools.line(lookup.name, lookup.arguments))
                        .font(.ui(.xs)).foregroundStyle((done ? palette.ink3 : palette.ink2).color).lineLimit(1)
                }
                .frame(height: 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color))
    }

    private func footer(_ ended: Date) -> some View {
        let seconds = String(format: "%.1f", ended.timeIntervalSince(exchange.startedAt))
        return HStack(spacing: Space.xs) {
            Text(exchange.state == .stopped ? "Stopped after \(seconds) s" : "Answered in \(seconds) s on this Mac")
                .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
            if !exchange.answer.isEmpty {
                IconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy the answer") {
                    Opener.copy(exchange.answer)
                    copied = true
                }
            }
            IconButton("arrow.clockwise", help: "Ask again", action: again)
        }
    }

    /// The model writes light Markdown (bold, lists); shown as styled text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Before the first word: what the model is doing, and for how long.
private struct Thinking: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.1)) { context in
            let elapsed = context.date.timeIntervalSince(since)
            HStack(spacing: Space.sm) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(palette.brand.color).frame(width: 4, height: 4)
                            .opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * max(0, sin(elapsed * 5 - Double(i) * 0.8)))
                    }
                }
                Text("Thinking on this Mac").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                Text(String(format: "%.1f s", elapsed)).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
            }
        }
        .accessibilityLabel("Thinking")
    }
}
