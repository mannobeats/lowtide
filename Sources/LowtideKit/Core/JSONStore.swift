import Foundation

/// Small JSON files in the data folder, written atomically (temp file, then
/// rename) so a crash mid-write never leaves half a file.
public enum JSONStore {
    public static func url(_ name: String) -> URL { Paths.data.appending(path: name) }

    public static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        do { return try decoder.decode(T.self, from: data) } catch {
            Log.store.error("unreadable \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public static func load<T: Decodable & Sendable>(_ name: String, default value: T) -> T {
        load(T.self, from: name) ?? value
    }

    @discardableResult
    public static func save<T: Encodable>(_ value: T, to name: String) -> Bool {
        write(value, to: url(name))
    }

    @discardableResult
    public static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            Log.store.error("write failed \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()
}
