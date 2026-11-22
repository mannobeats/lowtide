import Foundation

/// A speech model Lowtide offers (the helper's `ModelID`).
public struct VoiceModelInfo: Identifiable, Hashable, Sendable {
    public enum Family: String, Sendable { case parakeet, phonon, qwen }

    public let id: String
    public let name: String
    public let family: Family
    /// Download size, in megabytes.
    public let sizeMB: Int
    public let languages: String
    public let note: String

    public var bytes: Int64 { Int64(sizeMB) * 1_000_000 }

    public static let all: [VoiceModelInfo] = [
        VoiceModelInfo(id: "parakeet-v3", name: "Parakeet v3", family: .parakeet, sizeMB: 480,
                       languages: "25 European languages",
                       note: "Fast and accurate, on the Neural Engine. The proven choice."),
        VoiceModelInfo(id: "parakeet-ultra", name: "Parakeet Ultra", family: .parakeet, sizeMB: 630,
                       languages: "25 European languages",
                       note: "The most accurate Parakeet, at the same speed."),
        VoiceModelInfo(id: "phonon-2", name: "Phonon-2", family: .phonon, sizeMB: 346,
                       languages: "English",
                       note: "Parakeet distilled for English: about twice as fast, a quarter smaller."),
        VoiceModelInfo(id: "qwen3-0.6b", name: "Qwen3-ASR 0.6B", family: .qwen, sizeMB: 1010,
                       languages: "30 languages and 22 dialects",
                       note: "Strong in every language, on the GPU. Uses your words as hints."),
        VoiceModelInfo(id: "qwen3-1.7b", name: "Qwen3-ASR 1.7B", family: .qwen, sizeMB: 2040,
                       languages: "30 languages and 22 dialects",
                       note: "The most accurate overall; slower, and needs about 2.5 GB of memory."),
    ]

    public static func named(_ id: String) -> VoiceModelInfo? { all.first { $0.id == id } }
}

/// Where dictation keeps and finds things.
public enum VoicePaths {
    /// One folder per downloaded model, with `.complete` once it's whole.
    public static var models: URL { Paths.data.appending(path: "models", directoryHint: .isDirectory) }

    public static func folder(_ id: String, in root: URL = models) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    public static func installed(_ id: String, in root: URL = models) -> Bool {
        FileManager.default.fileExists(atPath: folder(id, in: root).appending(path: ".complete").path)
    }

    /// The helper writes its own log here (never what was said).
    public static var log: URL {
        Paths.home.appending(path: "Library/Logs/Lowtide/voice.ndjson")
    }

    /// The helper ships in `Contents/Helpers`, its resource bundles beside it.
    /// `LOWTIDE_VOICE_HELPER` points at another build (tests, development).
    public static var helper: URL? {
        if let path = ProcessInfo.processInfo.environment["LOWTIDE_VOICE_HELPER"] {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/lowtide-voice")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

/// Words in a dictation, by the system's word breaker, so Chinese and
/// Japanese count words rather than whole phrases.
public func wordCount(_ text: String) -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
        count += 1
    }
    return count
}
