import SwiftUI

// Settings parts for the extensions' pages:
// rows under a small heading in one inset group, like System Settings.
// Shared by Dictation and the menu bar manager.

/// Rows under a small heading, in one raised group, hairlines between them.
struct PrefsGroup<Content: View, Action: View>: View {
    @Environment(\.palette) private var palette
    let title: String?
    @ViewBuilder var action: Action
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder action: () -> Action = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || Action.self != EmptyView.self {
                HStack(spacing: Space.sm) {
                    if let title { Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color) }
                    Spacer(minLength: Space.sm)
                    action
                }
                .padding(.horizontal, Space.xs)
                .frame(minHeight: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        row
                    }
                }
            }
            .padding(.horizontal, Space.md)
            .card()
        }
    }
}

/// One setting: label and hint on the left, the control on the right.
/// `block` puts a wide control (a list, a grid) under the label instead.
struct PrefsRow<Control: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    var hint: String?
    var block = false
    @ViewBuilder var control: Control

    init(_ label: String, hint: String? = nil, block: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.block = block
        self.control = control()
    }

    var body: some View {
        if block {
            VStack(alignment: .leading, spacing: Space.md) {
                labels
                control
            }
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Space.xl) {
                labels
                Spacer(minLength: Space.md)
                HStack(spacing: Space.sm) { control }.fixedSize()
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.ui(.sm)).foregroundStyle(palette.ink.color)
            if let hint {
                Text(hint).font(.ui(.xxs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch for a setting row; the row carries the visible label.
struct PrefsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

/// Something that needs doing outside Lowtide: amber, with a word of why.
struct PrefsNotice<Actions: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var message: String?
    /// Inside a group, between its rows.
    var inset = false
    @ViewBuilder var actions: Actions

    init(_ title: String, message: String? = nil, inset: Bool = false, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.inset = inset
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.ui(.sm))
                .foregroundStyle(palette.warn.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                if let message {
                    Text(message).font(.ui(.xs)).foregroundStyle(palette.ink2.color).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.sm) { actions }.padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, inset ? Space.md : Space.md)
        .padding(.horizontal, inset ? 0 : 14)
        .background(inset ? .clear : palette.warnSoft.color, in: .rect(cornerRadius: Radius.md))
    }
}

/// "Allowed", in green with its mark.
struct PrefsAllowed: View {
    @Environment(\.palette) private var palette
    var text = "Allowed"
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.ui(.xs, .medium))
            .foregroundStyle(palette.ok.color)
            .labelStyle(TightLabelStyle())
    }
}

/// An extension that's off: what it does and what it needs, shown
/// before Install.
struct PrefsAbout: View {
    @Environment(\.palette) private var palette
    let about: String
    let facts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(about)
                .font(.ui(.sm))
                .foregroundStyle(palette.ink2.color)
                .lineSpacing(3)
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(facts.joined(separator: " · ")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        }
    }
}

/// Re-reads permissions when the app comes back to the front: they're
/// granted in System Settings, out of sight.
struct PrefsRefreshOnActivate: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            action()
        }
    }
}

extension View {
    func onAppActivate(_ action: @escaping () -> Void) -> some View { modifier(PrefsRefreshOnActivate(action: action)) }
}
