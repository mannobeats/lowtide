import AppKit
import SwiftUI

enum CheckState { case off, on, mixed }

/// Lowtide's checkbox: a small rounded square, brand-filled when on.
struct CheckMark: View {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    var state: CheckState

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill((state == .off ? palette.fill : palette.brand).color)
            .overlay {
                if state == .off {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(palette.lineStrong.color)
                } else {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.onBrand.color)
                }
            }
            .frame(width: 14, height: 14)
            .opacity(enabled ? 1 : 0.4)
            .animation(Motion.fast, value: state)
            .accessibilityHidden(true)
    }
}

/// A checkbox for selecting rows, with the mixed state a group needs.
/// ⇧-click runs come from `Checks.toggle`.
struct Checkbox: View {
    let state: CheckState
    let label: String
    var enabled = true
    let toggle: () -> Void

    init(_ state: CheckState, label: String, enabled: Bool = true, toggle: @escaping () -> Void) {
        self.state = state
        self.label = label
        self.enabled = enabled
        self.toggle = toggle
    }

    init(_ on: Bool, label: String, enabled: Bool = true, toggle: @escaping () -> Void) {
        self.init(on ? .on : .off, label: label, enabled: enabled, toggle: toggle)
    }

    var body: some View {
        Button(action: toggle) {
            CheckMark(state: state).frame(width: 22, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "checked" : state == .mixed ? "mixed" : "unchecked")
        .help(label)
    }
}

/// Which rows are checked, with ⇧-click to check (or uncheck) a run.
struct Checks<ID: Hashable>: Equatable {
    var ids: Set<ID> = []
    private var anchor: ID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func has(_ id: ID) -> Bool { ids.contains(id) }

    /// Toggles one row; with shift, the run from the last row touched in
    /// `order` takes the clicked row's new state.
    mutating func toggle(_ id: ID, in order: [ID], shift: Bool = NSEvent.modifierFlags.contains(.shift)) {
        if shift, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let run = order[min(from, to)...max(from, to)]
            if ids.contains(id) { ids.subtract(run) } else { ids.formUnion(run) }
        } else if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        anchor = id
    }

    mutating func set(_ list: [ID], on: Bool) {
        if on { ids.formUnion(list) } else { ids.subtract(list) }
    }

    mutating func only(_ list: [ID]) { ids = Set(list) }
    mutating func clear() { ids = []; anchor = nil }

    /// Only ids still listed.
    mutating func keep(_ listed: Set<ID>) { ids.formIntersection(listed) }

    /// What an action on `id` acts on: the checked rows (in `order` when
    /// given) when it's one of them, else that row alone.
    func targets(_ id: ID, in order: [ID]? = nil) -> [ID] {
        guard ids.contains(id) else { return [id] }
        return order.map { $0.filter(ids.contains) } ?? Array(ids)
    }

    func state(of list: [ID]) -> CheckState {
        let on = list.filter(ids.contains).count
        return on == 0 ? .off : on == list.count ? .on : .mixed
    }
}
