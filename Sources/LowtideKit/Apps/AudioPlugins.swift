import Foundation

/// One plug-in bundle in one format.
public struct PluginFormat: Sendable, Hashable {
    public var format: String
    public var path: String
    /// `~/Library` (true) or `/Library`.
    public var user: Bool
    public var bundleID: String?
    public var version: String?
}

/// Audio plug-ins grouped into products: one "Serum" whether it is
/// installed as AU, VST, VST3, CLAP and AAX, for the person or everyone.
public struct PluginProduct: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var vendor: String?
    public var version: String?
    public var formats: [PluginFormat]
    public var bytes: Int64?

    public static let formatOrder = ["AU", "VST3", "VST", "AAX", "CLAP", "LV2", "MAS", "Driver"]

    /// Its formats, once each, in the usual order.
    public var formatNames: [String] {
        Array(Set(formats.map(\.format))).sorted {
            (Self.formatOrder.firstIndex(of: $0) ?? 99) < (Self.formatOrder.firstIndex(of: $1) ?? 99)
        }
    }
}

public enum AudioPlugins {
    struct Found: Sendable {
        var stem: String
        var format: PluginFormat
        var vendor: String?
    }

    /// `Arturia: ARP 2600 V3` in an Audio Unit's component list names the
    /// vendor exactly; otherwise the bundle id's second part (`com.arturia`).
    static func vendor(_ bundle: URL, bundleID: String?) -> String? {
        let fromAU = (AppBundles.infoDictionary(bundle)?["AudioComponents"] as? [[String: Any]])?.first?["name"] as? String
        if let fromAU, let colon = fromAU.firstIndex(of: ":") {
            return fromAU[..<colon].trimmingCharacters(in: .whitespaces)
        }
        return bundleID.flatMap(vendorFromID)
    }

    /// `com.arturia.…` → Arturia, `jp.co.roland.…` → Roland. Ids that aren't
    /// reverse-DNS (Native Instruments ships `Maschine 3.vst3`) name no
    /// vendor, so the product borrows one from its other formats.
    static func vendorFromID(_ id: String) -> String? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let part = ["co", "com", "ac", "or", "ne", "org", "net"].contains(parts[1]) ? parts[2] : parts[1]
        guard let first = part.first else { return nil }
        return first.uppercased() + part.dropFirst()
    }

    static func scan(home: String) -> [Found] {
        var found: [Found] = []
        for (library, user) in [(home + "/Library", true), ("/Library", false)] {
            for (folder, format) in Footprint.pluginFolders {
                let dir = library + "/" + folder
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                    let path = dir + "/" + name
                    // Bundles carry an extension; plain folders are vendor
                    // groupings (`VST/Arturia/…`) and hold bundles one level down.
                    let bundles: [String]
                    if !(name as NSString).pathExtension.isEmpty {
                        bundles = [path]
                    } else if !name.hasPrefix("."), CleanupFS.isFolder(path) {
                        bundles = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                            .filter { !($0 as NSString).pathExtension.isEmpty }.map { path + "/" + $0 }
                    } else {
                        bundles = []
                    }
                    for bundle in bundles {
                        let url = URL(fileURLWithPath: bundle)
                        let info = AppBundles.read(url)
                        found.append(Found(
                            stem: url.deletingPathExtension().lastPathComponent,
                            format: PluginFormat(format: format, path: bundle, user: user, bundleID: info?.bundleID, version: info?.version),
                            vendor: vendor(url, bundleID: info?.bundleID)
                        ))
                    }
                }
            }
        }
        return found
    }

    /// Groups format bundles into products by name, keeping vendors apart.
    static func group(_ found: [Found]) -> [PluginProduct] {
        var vendorsByName: [String: [String]] = [:]
        for item in found { if let vendor = item.vendor { vendorsByName[AppBundles.alnum(item.stem), default: []].append(vendor) } }
        var products: [String: PluginProduct] = [:]
        for item in found {
            let known = vendorsByName[AppBundles.alnum(item.stem)] ?? []
            // One product's formats can name its vendor differently (`Waves`
            // in the Audio Unit, `com.wavesaudio` in the VST3): the shortest
            // name the others contain stands for all of them.
            let vendor: String?
            if let own = item.vendor {
                let key = AppBundles.alnum(own)
                vendor = known.filter { !AppBundles.alnum($0).isEmpty && key.contains(AppBundles.alnum($0)) }
                    .min { AppBundles.alnum($0).count < AppBundles.alnum($1).count } ?? own
            } else {
                vendor = known.first
            }
            let id = "\(vendor.map(AppBundles.alnum) ?? ""):\(AppBundles.alnum(item.stem))"
            var product = products[id] ?? PluginProduct(id: id, name: item.stem, vendor: vendor, formats: [])
            if product.version == nil { product.version = item.format.version }
            product.formats.append(item.format)
            products[id] = product
        }
        return products.values.sorted { $0.id < $1.id }
    }

    /// Every plug-in product on the Mac, not yet measured.
    public static func list() async -> [PluginProduct] {
        let home = Footprint.home
        return await Footprint.offMain { group(scan(home: home)) }
    }

    /// Size of each product (all its formats).
    public static func measure(_ product: PluginProduct) async -> Int64? {
        let sizes = await DiskSize.measure(product.formats.map(\.path), width: 4)
        let known = sizes.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Everything one plug-in product installed: formats, presets, content,
    /// support files and receipts. `all` is the full list, to tell a
    /// vendor's shared files from this product's.
    public static func subject(_ product: PluginProduct, all: [PluginProduct]) async -> Footprint.Subject {
        var counts: [String: Set<String>] = [:]
        for other in all {
            for format in other.formats {
                if let prefix = format.bundleID.flatMap(AppBundles.vendorPrefix) { counts[prefix, default: []].insert(other.id) }
            }
        }
        let ids = product.formats.compactMap(\.bundleID)
        var subject = Footprint.Subject()
        subject.bundleIDs = ids
        subject.names = [product.name]
        subject.vendor = product.vendor
        subject.primary = product.formats.map { ($0.path, .plugins) }
        subject.sharedPrefixes = Set(ids.compactMap(AppBundles.vendorPrefix).filter { (counts[$0]?.count ?? 0) > 1 })
        if let first = product.formats.first { subject.packages = await Footprint.packages(of: first.path) }
        return subject
    }
}
