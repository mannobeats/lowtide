import Foundation

/// Files shipped inside the app (themes, geo databases), with the repo's
/// `Resources` folder as the fallback when running from `swift run`.
public enum AppResources {
    public static func url(_ name: String) -> URL {
        if let base = Bundle.main.resourceURL {
            let url = base.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Sources/LowtideKit/Core/AppResources.swift → the repo root.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/\(name)")
    }
}
