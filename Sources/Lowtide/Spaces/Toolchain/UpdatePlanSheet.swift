import LowtideKit
import SwiftUI

/// The risk-aware update plan: safest first, major versions start
/// unticked, each manager updates one package at a time and then checks
/// the result.
struct UpdatePlanSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let items: [InventoryItem]
    let run: ([InventoryItem]) -> Void
    @State private var ticked: Set<String>
    private let ordered: [InventoryItem]

    init(items: [InventoryItem], run: @escaping ([InventoryItem]) -> Void) {
        self.items = items
        self.run = run
        ordered = UpdatePlan.order(items)
        // Preselected once, when the sheet opens: a background rescan must
        // not wipe the person's choices.
        _ticked = State(initialValue: UpdatePlan.preselected(items))
    }

    private var breaking: Int { ordered.filter { UpdatePlan.risk($0) == .breaking }.count }
    private var chosen: [InventoryItem] { ordered.filter { ticked.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Update plan").font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color)
                Text("Safest first. Major versions start unticked. Each manager updates one package at a time, then checks the result.")
                    .font(.ui(.sm)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.xl).padding(.top, Space.xl).padding(.bottom, Space.md)

            HStack(spacing: Space.sm) {
                Toggle(isOn: Binding(get: { ticked.count == ordered.count && !ordered.isEmpty },
                                     set: { all in ticked = all ? Set(ordered.map(\.id)) : [] })) {
                    HStack(spacing: 4) {
                        Text("\(ordered.count - breaking) ready").foregroundStyle(palette.ink2.color)
                        if breaking > 0 {
                            Text("· \(LowtideFormat.count(breaking, "major version"))").foregroundStyle(palette.warn.color)
                        }
                    }
                    .font(.ui(.xs))
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, Space.xl).padding(.bottom, Space.sm)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline() }
                        row(index, item)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: Radius.lg))
            .card()
            .padding(.horizontal, Space.xl)

            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button("Update \(LowtideFormat.count(chosen.count, "package"))") {
                    run(chosen)
                    dismiss()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(Space.xl)
        }
        .frame(width: 600)
        .background(palette.overlay.color)
    }

    private func row(_ index: Int, _ item: InventoryItem) -> some View {
        let risk = UpdatePlan.risk(item)
        let on = Binding(get: { ticked.contains(item.id) }, set: { if $0 { ticked.insert(item.id) } else { ticked.remove(item.id) } })
        return HStack(spacing: Space.md) {
            Toggle("Update \(item.package.name)", isOn: on).toggleStyle(.checkbox).labelsHidden()
            Text("\(index + 1)").font(.ui(.xs)).foregroundStyle(palette.ink4.color).monospacedDigit().frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.package.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                Text("\(item.ownerName) · \(UpdatePlan.reason(item))").font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Badge(risk.label, tone: risk == .safe ? .ok : risk == .breaking ? .bad : .warn)
            Text(item.package.latestVersion ?? "Latest").font(.mono(.xs)).foregroundStyle(palette.ink2.color)
                .lineLimit(1).truncationMode(.middle).frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 48)
        .contentShape(.rect)
        .onTapGesture { on.wrappedValue.toggle() }
        .toolRowHover()
    }
}
