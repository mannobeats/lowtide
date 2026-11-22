import Foundation

/// One installed thing in the inventory, with who manages it.
public struct InventoryItem: Sendable, Identifiable, Hashable {
    public enum ItemType: String, Sendable, Hashable, CaseIterable {
        case app, cli, package
    }

    public var package: ToolPackage
    /// The source that scans, updates and removes it.
    public var sourceID: String
    /// Who it is shown as managed by (Homebrew's app casks read "Homebrew Apps").
    public var ownerID: String
    public var ownerName: String
    public var itemType: ItemType

    public var id: String { "\(sourceID):\(package.id)" }

    public init(package: ToolPackage, source: PackageSourceInfo) {
        self.package = package
        sourceID = source.id
        if package.kind == .app, source.id == "homebrew" {
            ownerID = "homebrew-apps"
            ownerName = "Homebrew Apps"
        } else {
            ownerID = source.id
            ownerName = source.name
        }
        itemType = switch package.kind {
        case .app: .app
        case .tool: .cli
        case .package: source.id == "standalone" ? .cli : .package
        }
    }
}

/// How risky an update is. It comes from the engine's version analysis
/// (`bump`), not a guess.
public enum UpdateRisk: Int, Sendable, Comparable {
    case safe, review, breaking

    public static func < (a: UpdateRisk, b: UpdateRisk) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .breaking: "Breaking"
        }
    }
}

/// The update plan: safest first, major versions start unticked.
public enum UpdatePlan {
    public static func risk(_ item: InventoryItem) -> UpdateRisk {
        switch item.package.bump {
        case .major: .breaking
        case .minor, .patch: item.itemType == .app ? .review : .safe
        case .other, nil: .review
        }
    }

    public static func reason(_ item: InventoryItem) -> String {
        switch item.package.bump {
        case .major: "Major version: may contain breaking changes"
        case .minor: "Minor version: new features, compatible"
        case .patch: "Patch: fixes only"
        case .other: "Rebuild or revision of the same version"
        case nil: item.itemType == .app ? "Graphical application" : "Version resolved during update"
        }
    }

    public static func order(_ items: [InventoryItem]) -> [InventoryItem] {
        items.sorted { a, b in
            let (ra, rb) = (risk(a), risk(b))
            if ra != rb { return ra < rb }
            if a.itemType != b.itemType { return a.itemType.rawValue < b.itemType.rawValue }
            return a.package.name.localizedCaseInsensitiveCompare(b.package.name) == .orderedAscending
        }
    }

    /// What the plan ticks when it opens: everything but breaking updates.
    public static func preselected(_ items: [InventoryItem]) -> Set<String> {
        Set(items.filter { risk($0) != .breaking }.map(\.id))
    }
}
