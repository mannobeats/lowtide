import AppKit
import CryptoKit
import Foundation

/// Installing an app update. Homebrew and the App Store install their own; a
/// developer feed's download replaces the app only after macOS confirms it's
/// intact and signed by the same developer as the copy it replaces.
public enum UpdateInstaller {
    public enum Event: Sendable {
        case downloading(received: Int64, total: Int64?)
        case verifying
        case installing
        case log(String)
    }

    public enum Outcome: Sendable, Equatable {
        /// Installed; the version the app now reports.
        case updated(String?)
        /// The App Store finishes the job.
        case openedStore
    }

    public static func install(_ update: AppUpdate, events: @escaping @Sendable (Event) -> Void) async throws -> Outcome {
        switch update.method {
        case .appStore:
            guard let id = update.storeID, let url = URL(string: "macappstore://apps.apple.com/app/id\(id)") else {
                throw LowtideError.invalid("No App Store id for \(update.name)")
            }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return .openedStore
        case .homebrew:
            try await brew(["upgrade", "--cask"], update, events)
        case .cask:
            guard Shell.isAvailable("brew") else {
                throw LowtideError.toolMissing("Homebrew isn't installed. Download \(update.name) from its website instead.")
            }
            // `--force` lets Homebrew replace the copy it didn't install; it
            // manages the app from then on.
            try await brew(["install", "--cask", "--force"], update, events)
        case .sparkle, .electron:
            try await replace(update, events)
        case .vendor:
            // The page or the app itself updates these; there is nothing to run.
            throw LowtideError.invalid("Open \(update.name)’s download page, or launch it to update itself.")
        }
        AppUpdates.forget(update.id)
        return .updated(AppBundles.read(URL(fileURLWithPath: update.id))?.version)
    }

    static func brew(_ verb: [String], _ update: AppUpdate, _ events: @escaping @Sendable (Event) -> Void) async throws {
        guard let token = update.cask else { throw LowtideError.invalid("No Homebrew cask for \(update.name)") }
        events(.installing)
        try await Brew.cask(verb, token: token) { events(.log($0)) }
    }

    // MARK: - Replacing the app from a developer's feed

    static func replace(_ update: AppUpdate, _ events: @escaping @Sendable (Event) -> Void) async throws {
        guard let address = update.download, let url = URL(string: address) else {
            throw LowtideError.invalid("The developer’s feed has no download for this Mac")
        }
        guard url.scheme == "https" else { throw LowtideError.denied("The developer’s feed isn’t secure; open the app to update it") }
        let old = URL(fileURLWithPath: update.id)
        guard let team = await AppBundles.teamID(old) else {
            throw LowtideError.denied("\(update.name) isn’t signed by a developer, so Lowtide can’t prove a download comes from the same one. Open it to update.")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "lowtide-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Our own scratch folder, never the person's files.
        defer { try? FileManager.default.removeItem(at: work) }
        let name = url.lastPathComponent.isEmpty || url.lastPathComponent.contains("..") ? "update.zip" : url.lastPathComponent
        let file = work.appending(path: name)
        try await LargeDownload.fetch(url, to: file) { events(.downloading(received: $0, total: $1)) }
        events(.verifying)
        if let expected = update.sha512, try sha512(of: file) != expected {
            throw LowtideError.invalid("The download is damaged (checksum mismatch)")
        }
        let (root, mount) = try await unpack(file, in: work)
        do {
            try await install(update, from: root, team: team, events)
        } catch {
            if let mount { await detach(mount) }
            throw error
        }
        if let mount { await detach(mount) }
    }

    static func detach(_ mount: URL) async {
        _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], timeout: .seconds(60))
    }

    static func install(_ update: AppUpdate, from root: URL, team: String, _ events: @escaping @Sendable (Event) -> Void) async throws {
        let old = URL(fileURLWithPath: update.id)
        guard let new = findApp(root, bundleID: update.bundleID, name: update.name, depth: 2) else {
            throw LowtideError.invalid("The download doesn’t contain this app")
        }
        guard (try? await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path], timeout: .seconds(300)))?.ok == true else {
            throw LowtideError.denied("The download’s signature is broken")
        }
        guard await AppBundles.teamID(new) == team else { throw LowtideError.denied("The download is signed by a different developer") }
        events(.installing)
        var wasRunning = false
        if let id = update.bundleID, !id.isEmpty, AppBundles.isRunning(id) {
            wasRunning = true
            guard await AppBundles.quit(id, wait: .seconds(20)) else {
                throw LowtideError.commandFailed("\(update.name) didn’t quit. Save your work, quit it and try again.")
            }
        }
        try await swap(old: old, new: new)
        if wasRunning { _ = try? await Shell.run("/usr/bin/open", [old.path], timeout: .seconds(30)) }
    }

    /// The SHA-512 of a file, base64, as electron-builder publishes it.
    static func sha512(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).base64EncodedString()
    }

    /// Unpacks the download; returns the folder to look in and, for a disk
    /// image, its mount point.
    static func unpack(_ file: URL, in work: URL) async throws -> (URL, URL?) {
        let name = file.lastPathComponent.lowercased()
        let out = work.appending(path: "unpacked")
        if name.hasSuffix(".zip") {
            try await Shell.check("/usr/bin/ditto", ["-x", "-k", file.path, out.path], timeout: .seconds(600))
            return (out, nil)
        }
        if name.hasSuffix(".dmg") {
            let mount = work.appending(path: "mount")
            let result = try await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, file.path],
                                             timeout: .seconds(300), input: Data("Y\n".utf8))
            guard result.ok else { throw LowtideError.commandFailed("The disk image wouldn’t open (it may ask for a licence agreement)") }
            return (mount, mount)
        }
        if [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"].contains(where: name.hasSuffix) {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try await Shell.check("/usr/bin/tar", ["-xf", file.path, "-C", out.path], timeout: .seconds(600))
            return (out, nil)
        }
        throw LowtideError.invalid("The update is an installer package; open the app to update it")
    }

    /// The app bundle inside an unpacked download with the same bundle id.
    static func findApp(_ root: URL, bundleID: String?, name: String, depth: Int) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        for entry in names {
            let path = root.appending(path: entry)
            // lstat: skips a disk image's `Applications` shortcut.
            guard CleanupFS.isDir(path.path) else { continue }
            if path.pathExtension == "app" {
                let same = bundleID.map { AppBundles.read(path)?.bundleID == $0 } ?? (path.deletingPathExtension().lastPathComponent == name)
                if same { return path }
            } else if depth > 0, let found = findApp(path, bundleID: bundleID, name: name, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    /// Moves the old app to the Trash and copies the new one into its place,
    /// putting the old one back if the copy fails.
    static func swap(old: URL, new: URL) async throws {
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: old, resultingItemURL: &trashed)
        } catch {
            let denied = (error as NSError).code == NSFileWriteNoPermissionError
            throw LowtideError.denied(denied
                ? "macOS won’t let Lowtide replace this app (an administrator installed it). Update it from the app itself."
                : "Couldn’t move the old version to the Trash: \(error.localizedDescription)")
        }
        let copied = (try? await Shell.run("/usr/bin/ditto", [new.path, old.path], timeout: .seconds(600)))?.ok == true
        guard !copied else { return }
        // Our own half-written copy goes; the old version comes back.
        try? FileManager.default.removeItem(at: old)
        if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: old) }
        throw LowtideError.commandFailed("Couldn’t copy the new version into place; the old one is back")
    }
}
