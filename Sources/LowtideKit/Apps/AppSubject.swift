import Foundation

extension Footprint {
    // MARK: - An app's subject

    /// What identifies an installed app's files. `prefixes` holds the
    /// bundle-id prefixes of every installed app, to tell a developer's
    /// shared data from this app's own.
    public static func subject(app path: String, prefixes: [String]) async throws -> Subject {
        let bundle = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard bundle.pathExtension == "app", FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw LowtideError.invalid("That isn't an application bundle")
        }
        guard let info = AppBundles.read(bundle) else { throw LowtideError.invalid("Its Info.plist can't be read") }
        if AppBundles.isProtected(bundle, bundleID: info.bundleID) {
            throw LowtideError.denied("This app is part of macOS and can't be removed")
        }
        let own = info.bundleID.flatMap(AppBundles.vendorPrefix)
        let shared = own.map { prefix in prefixes.filter { $0 == prefix }.count > 1 } ?? false
        let stemName = bundle.deletingPathExtension().lastPathComponent
        let vendor = info.bundleID.flatMap { id -> String? in
            let parts = id.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count > 1 ? String(parts[1]) : nil
        }
        // Support folders often take the id's last part (`obs-studio` of
        // `com.obsproject.obs-studio`), unless it says nothing.
        let product = info.bundleID.flatMap { $0.split(separator: ".").last.map(String.init) }
            .flatMap { genericProducts.contains($0.lowercased()) ? nil : $0 }
        let ownFlat = AppBundles.alnum(stemName)
        var names = [stemName, info.name, info.displayName, info.executable, product].compactMap { $0 }
        async let team = AppBundles.teamID(bundle)
        async let packages = packages(of: path)
        // The app's helpers keep files under their own ids and names.
        var helperIDs: [String] = []
        for helper in await offMain({ AppBundles.nestedBundles(bundle).map { Pair(name: $0.name, id: $0.id) } }) {
            let (name, id) = (helper.name, helper.id)
            let flat = AppBundles.alnum(name)
            if flat.hasPrefix(ownFlat) || ownFlat.hasPrefix(flat) { names.append(name) }
            if let id, !["com.apple.", "org.sparkle-project.", "com.github.electron"].contains(where: id.lowercased().hasPrefix) {
                helperIDs.append(id)
            }
        }
        var subject = Subject()
        subject.bundleIDs = info.bundleID.map { [$0] } ?? []
        subject.helperIDs = helperIDs
        subject.names = names
        subject.vendor = vendor
        subject.teamID = await team
        subject.primary = [(path, .app)]
        subject.sharedPrefixes = shared ? Set(own.map { [$0] } ?? []) : []
        subject.packages = await packages
        return subject
    }

    struct Pair: Sendable {
        var name: String
        var id: String?
    }
}
