import Foundation

/// JSON lines to the app, one at a time from any thread.
enum Output {
    private static let lock = NSLock()

    static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    /// `extra` carries the contract's optional fields (see `voice/mod.rs`
    /// `VoiceState`): method, app, text, kind, action, queued.
    static func state(_ phase: String, _ message: String = "", _ extra: [String: Any] = [:]) {
        var object: [String: Any] = ["type": "state", "phase": phase, "message": message]
        object.merge(extra) { _, new in new }
        send(object)
    }
}

/// What the helper did and how long it took, as NDJSON in
/// `~/Library/Logs/Lowtide/voice.ndjson`: taps, microphones, how text
/// went in and whether that was confirmed. Never what was said.
enum Log {
    private static let queue = DispatchQueue(label: "voice.log", qos: .utility)
    private static let limit = 2_000_000
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lowtide/voice.ndjson")
    private static var handle: FileHandle?

    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["event"] = name
        line["at"] = Int(Date().timeIntervalSince1970 * 1000)
        guard var data = try? JSONSerialization.data(withJSONObject: line) else { return }
        data.append(0x0A)
        queue.async { write(data) }
    }

    private static func write(_ data: Data) {
        let files = FileManager.default
        if handle == nil {
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        handle.write(data)
        // One older file is kept beside it.
        if let size = try? handle.offset(), size > limit {
            try? handle.close()
            self.handle = nil
            let old = url.deletingPathExtension().appendingPathExtension("1.ndjson")
            try? files.removeItem(at: old)
            try? files.moveItem(at: url, to: old)
        }
    }
}

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
