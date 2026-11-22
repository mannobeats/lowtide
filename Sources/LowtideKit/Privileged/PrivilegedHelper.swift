import Darwin
import Foundation
import ServiceManagement

/// Talks to the privileged helper (`Helpers/Privileged/lowtide-privileged.swift`),
/// the launch daemon a person approves once in System Settings › General ›
/// Login Items. While it's on, moving an app's root-owned files to the
/// Trash, stopping a system daemon and opening packet capture need no
/// password; while it isn't, those fall back to the password prompt (`Admin`).
public enum PrivilegedHelper {
    public static let plistName = "dev.lowtide.app.privileged.plist"
    public static let socketPath = "/var/run/dev.lowtide.app.privileged.sock"

    public enum State: String, Sendable {
        /// Approved and answering.
        case on
        /// Registered, waiting for the person's yes in Login Items.
        case approval
        case off
        /// A development build, outside an app bundle (or without the daemon's plist).
        case unavailable
    }

    static var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    /// Inside an app bundle that carries the daemon's plist.
    static var bundled: Bool {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app"
            && FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Library/LaunchDaemons/\(plistName)").path)
    }

    public static var state: State {
        guard bundled else { return .unavailable }
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .approval
        default: return .off
        }
    }

    /// Registers the helper. macOS then wants the person's yes in System
    /// Settings, which opens at Login Items.
    @discardableResult
    public static func enable() throws -> State {
        switch state {
        case .unavailable: throw LowtideError.denied("This works in the installed app, not in a development build.")
        case .on: return .on
        default: break
        }
        // Registering again after a refusal is harmless and lists it again.
        do { try service.register() } catch {
            Log.apps.info("helper register: \(error.localizedDescription, privacy: .public)")
        }
        if state != .on { SMAppService.openSystemSettingsLoginItems() }
        return state
    }

    /// Takes the helper away again; removals ask for the password from then on.
    public static func disable() async throws {
        guard bundled else { return }
        try await service.unregister()
    }

    // MARK: - Requests

    public struct TrashResult: Sendable, Equatable {
        public var ok: Bool
        public var trashed: String?
        public var error: String?
    }

    /// Moves each path to the person's Trash as root. Nil: do it another way.
    public static func trash(_ paths: [String]) async -> [TrashResult]? {
        // Handing a large app back to the person walks every file in it.
        guard let answer = await ask(["op": "trash", "paths": paths], wait: 300),
              let results = answer["results"] as? [[String: Any]], results.count == paths.count
        else { return nil }
        return results.map {
            TrashResult(ok: $0["ok"] as? Bool == true, trashed: $0["to"] as? String,
                        error: ($0["ok"] as? Bool == true) ? nil : ($0["error"] as? String ?? "Couldn't move it to the Trash"))
        }
    }

    /// `launchctl enable|disable system/<label>` as root. Nil: helper off.
    public static func launchd(enable: Bool, label: String) async -> Bool? {
        guard let answer = await ask(["op": "launchd", "action": enable ? "enable" : "disable", "label": label], wait: 30) else { return nil }
        return answer["ok"] as? Bool
    }

    /// Lets the `access_bpf` group read `/dev/bpf*` (packet capture).
    public static func bpf() async -> Bool? {
        guard let answer = await ask(["op": "bpf"], wait: 30) else { return nil }
        return answer["ok"] as? Bool
    }

    /// Whether the helper answers this build.
    public static func ping() async -> Bool {
        await ask(["op": "ping"], wait: 10)?["ok"] as? Bool == true
    }

    /// One request and its answer; nil when the helper isn't on or doesn't
    /// answer, so the caller asks for the password instead.
    static func ask(_ request: [String: Any], wait seconds: Int) async -> [String: Any]? {
        guard state == .on, var line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        line.append(0x0A)
        let payload = line
        let answer: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: exchange(payload, path: socketPath, timeout: seconds))
            }
        }
        guard let answer, let json = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else { return nil }
        if json["error"] as? String == "not Lowtide" {
            Log.apps.warning("privileged helper refused this build's signature")
            return nil
        }
        return json
    }

    /// Writes one line to a Unix socket and reads one line back. Blocking.
    static func exchange(_ payload: Data, path: String, timeout: Int) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let sent = payload.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard sent else { return nil }
        var answer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            answer.append(contentsOf: chunk[0..<n])
            if let newline = answer.firstIndex(of: 0x0A) { return Data(answer[..<newline]) }
            if answer.count > 4_194_304 { return nil }
        }
        return answer.isEmpty ? nil : answer
    }
}
