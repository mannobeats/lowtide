import Foundation

/// Apps with no update feed of their own whose developer still announces the
/// latest version in public: an API, or a page that always lists it first.
public struct UpdateVendor: Sendable {
    /// Lowercase bundle ids of the apps this entry serves.
    public let ids: Set<String>
    /// What is read for the latest version.
    public let url: URL
    /// Where a person downloads it.
    public let page: String
    public let read: @Sendable (Data) -> String?

    public static let all: [UpdateVendor] = [
        // Resolve's installer carries the Proxy Generator and Remote Monitor,
        // so all three move with it.
        UpdateVendor(
            ids: ["com.blackmagic-design.davinciresolve", "com.blackmagic-design.davinciresolvelite",
                  "com.blackmagic-design.blackmagicproxygeneratorstudio", "com.blackmagic-design.davinciremotemonitor"],
            url: URL(string: "https://www.blackmagicdesign.com/api/support/us/downloads.json")!,
            page: "https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion",
            read: blackmagic
        ),
        UpdateVendor(ids: ["org.soundflow.sfsx"], url: URL(string: "https://soundflow.org/changelog")!,
                     page: "https://soundflow.org/downloads", read: { soundflow(String(decoding: $0, as: UTF8.self)) }),
        UpdateVendor(ids: ["de.rme-audio.totalmixfx"], url: URL(string: "https://rme-audio.de/downloads.html")!,
                     page: "https://rme-audio.de/downloads.html", read: { totalmix(String(decoding: $0, as: UTF8.self)) }),
    ]

    public static func forID(_ bundleID: String) -> UpdateVendor? {
        let id = bundleID.lowercased()
        return all.first { $0.ids.contains(id) }
    }

    /// The newest final DaVinci Resolve for Mac (`21.1.1`). `beta: 255` marks
    /// a final release; a beta carries its number.
    static func blackmagic(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let downloads = json["downloads"] as? [[String: Any]]
        else { return nil }
        let versions = downloads
            .compactMap { ($0["urls"] as? [String: Any])?["Mac OS X"] as? [[String: Any]] }
            .joined()
            .filter { release in
                (release["beta"] as? NSNumber)?.intValue == 255
                    && ["davinci-resolve", "davinci-resolve-studio"].contains(release["product"] as? String ?? "")
            }
            .compactMap { release -> String? in
                guard let major = (release["major"] as? NSNumber)?.intValue, let minor = (release["minor"] as? NSNumber)?.intValue,
                      let patch = (release["releaseNum"] as? NSNumber)?.intValue else { return nil }
                return "\(major).\(minor).\(patch)"
            }
        return versions.max { AppVersion.compare($0, $1) == .orderedAscending }
    }

    /// The changelog lists releases newest first, each as `SoundFlow 6.2.4`.
    static func soundflow(_ html: String) -> String? {
        guard let range = html.range(of: ">SoundFlow ") else { return nil }
        let version = String(html[range.upperBound...].prefix { $0.isASCII && ($0.isNumber || $0 == ".") })
        return version.contains(".") && !version.hasSuffix(".") ? version : nil
    }

    /// The download list links the installer as `tmfx_203_1991_mac.zip`:
    /// version 2.03 (the second number is the older 1.x line's last release).
    static func totalmix(_ html: String) -> String? {
        var search = html.startIndex..<html.endIndex
        while let range = html.range(of: "tmfx_", range: search) {
            search = range.upperBound..<html.endIndex
            let name = html[range.lowerBound...].prefix { $0 != "\"" }
            let digits = name.dropFirst(5).prefix(3)
            guard name.hasSuffix("_mac.zip"), digits.count == 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            return "\(digits.first!).\(digits.dropFirst())"
        }
        return nil
    }
}
