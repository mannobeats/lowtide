// Lowtide's privileged helper: a launchd daemon the person approves once
// (System Settings › General › Login Items), so moving what an installer
// put in /Applications or /Library to the Trash no longer asks for the
// password every time.
//
// launchd starts it on demand when Lowtide connects to its socket, and it
// quits once idle. It answers only a process signed by Lowtide's Developer
// ID (checked from the socket's audit token, not from anything the request
// says), and it does three narrow things:
//   trash   moves files an app left into the *caller's* Trash, inside the
//           places apps install to, and hands them to the caller so the
//           Trash empties (or Put Back works) without a password
//   launchd enables or disables one system launch daemon by label
//   bpf     lets the access_bpf group read /dev/bpf* (packet capture)
// One JSON object per line in, one per line out.
//
// Built by scripts/build-privileged.sh (swiftc, no package), installed as
// Contents/Helpers/lowtide-privileged with Contents/Library/LaunchDaemons/
// dev.lowtide.app.privileged.plist beside it.

import Darwin
import Foundation
import Security

let requirement = """
    anchor apple generic and identifier "dev.lowtide.app" \
    and certificate leaf[subject.OU] = "7CPDA6H8CT"
    """
let idleSeconds: Int32 = 30

// MARK: - Socket

@_silgen_name("launch_activate_socket")
func launch_activate_socket(
    _ name: UnsafePointer<CChar>, _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ count: UnsafeMutablePointer<Int>
) -> Int32

func listeningSocket() -> Int32? {
    var fds: UnsafeMutablePointer<Int32>?
    var count = 0
    guard launch_activate_socket("Listener", &fds, &count) == 0, let fds, count > 0 else { return nil }
    defer { free(fds) }
    return fds[0]
}

/// The caller's uid, when its code is Lowtide's (from the socket's audit
/// token: a request can't claim to be someone else).
func verify(_ client: Int32) -> uid_t? {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
    var cred = xucred()
    var credLength = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(client, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLength) == 0 else { return nil }
    let data = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
          let code
    else { return nil }
    var required: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
          let required,
          SecCodeCheckValidity(code, [], required) == errSecSuccess
    else { return nil }
    return cred.cr_uid
}

// MARK: - Requests

func reply(_ object: [String: Any], to client: Int32) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { buffer in
        var sent = 0
        while sent < buffer.count {
            let n = write(client, buffer.baseAddress! + sent, buffer.count - sent)
            if n <= 0 { return }
            sent += n
        }
    }
}

func readLine(_ client: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    // A request is a list of paths; a megabyte is far more than any.
    while data.count < 1_048_576 {
        let n = read(client, &byte, 1)
        if n <= 0 { return data.isEmpty ? nil : data }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    return nil
}

func handle(_ client: Int32) {
    defer { close(client) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    guard let uid = verify(client) else {
        reply(["ok": false, "error": "not Lowtide"], to: client)
        return
    }
    guard let line = readLine(client),
          let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let op = request["op"] as? String
    else {
        reply(["ok": false, "error": "bad request"], to: client)
        return
    }
    switch op {
    case "ping":
        reply(["ok": true], to: client)
    case "trash":
        let paths = request["paths"] as? [String] ?? []
        reply(["ok": true, "results": paths.map { trash($0, for: uid) }], to: client)
    case "launchd":
        reply(launchd(request["action"] as? String, request["label"] as? String), to: client)
    case "bpf":
        reply(bpf(for: uid), to: client)
    default:
        reply(["ok": false, "error": "unknown request"], to: client)
    }
}

// MARK: - Trash

/// Where apps install things, and how deep a path must be inside each: an
/// app's own folder, never the place itself.
func allowed(_ path: String, home: String) -> Bool {
    let places: [(String, Int)] = [
        ("/Applications/", 1),
        ("/Library/", 2),
        ("/private/var/db/receipts/", 1),
        ("/usr/local/", 2),
        (home + "/", 2),
    ]
    for (place, depth) in places where path.hasPrefix(place) {
        let rest = path.dropFirst(place.count).split(separator: "/")
        // /Library/Apple holds macOS's own parts.
        if place == "/Library/", rest.first == "Apple" { return false }
        return rest.count >= depth
    }
    return false
}

func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

func trash(_ raw: String, for uid: uid_t) -> [String: Any] {
    func fail(_ reason: String) -> [String: Any] { ["path": raw, "ok": false, "error": reason] }
    guard let user = getpwuid(uid), let homeC = user.pointee.pw_dir else { return fail("no such user") }
    let home = String(cString: homeC)
    let group = user.pointee.pw_gid
    guard raw.hasPrefix("/"), !raw.split(separator: "/").contains("..") else { return fail("not a full path") }
    let url = URL(fileURLWithPath: raw)
    // The folder it sits in is resolved (a link there could point anywhere);
    // the item itself isn't followed, so a link moves as a link.
    guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return fail("not found") }
    let path = String(cString: parent) + "/" + url.lastPathComponent
    free(parent)
    guard allowed(path, home: home) else { return fail("outside the places apps install to") }
    guard exists(path) else { return fail("not found") }
    if path.hasPrefix("/Library/LaunchDaemons/") {
        run("/bin/launchctl", ["bootout", "system", path])
    }
    // The Trash must be the person's own folder, not a link: root renames
    // into it, and a planted link would send the file anywhere.
    let trash = home + "/.Trash"
    var trashInfo = stat()
    guard lstat(trash, &trashInfo) == 0, trashInfo.st_mode & S_IFMT == S_IFDIR, trashInfo.st_uid == uid
    else { return fail("the Trash folder isn't usable") }
    let destination = unusedName(in: trash, for: url.lastPathComponent)
    guard rename(path, destination) == 0 else {
        return fail(errno == EXDEV ? "on another disk" : String(cString: strerror(errno)))
    }
    give(destination, to: uid, group: group)
    return ["path": raw, "ok": true, "to": destination]
}

/// A name in the Trash nothing has yet (a dangling link counts as taken:
/// rename would replace it).
func unusedName(in trash: String, for name: String) -> String {
    var candidate = trash + "/" + name
    var attempt = 0
    let stamp = Int(Date().timeIntervalSince1970)
    while exists(candidate) {
        attempt += 1
        candidate = trash + "/" + name + (attempt == 1 ? " \(stamp)" : " \(stamp) \(attempt)")
    }
    return candidate
}

/// The caller owns what it threw away, so emptying the Trash needs no password.
func give(_ path: String, to uid: uid_t, group: gid_t) {
    lchown(path, uid, group)
    guard let walker = FileManager.default.enumerator(atPath: path) else { return }
    for case let child as String in walker {
        lchown(path + "/" + child, uid, group)
    }
}

// MARK: - Launch daemons and packet capture

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

func launchd(_ action: String?, _ label: String?) -> [String: Any] {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
    guard let label, !label.isEmpty, label.unicodeScalars.allSatisfy(safe.contains),
          action == "enable" || action == "disable"
    else { return ["ok": false, "error": "bad label"] }
    let target = "system/\(label)"
    if action == "disable" {
        run("/bin/launchctl", ["bootout", target])
        return ["ok": run("/bin/launchctl", ["disable", target]) == 0]
    }
    return ["ok": run("/bin/launchctl", ["enable", target]) == 0]
}

/// Opens /dev/bpf* to the caller until restart: the access_bpf group (made
/// when missing, as Wireshark's ChmodBPF would, with the caller in it) reads
/// them, and the caller owns them so capture starts without a new login.
func bpf(for uid: uid_t) -> [String: Any] {
    let devices = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
        .filter { $0.hasPrefix("bpf") }.map { "/dev/" + $0 }
    guard !devices.isEmpty else { return ["ok": false, "error": "no /dev/bpf devices"] }
    guard let entry = getpwuid(uid), let name = String(validatingCString: entry.pointee.pw_name) else {
        return ["ok": false, "error": "unknown user"]
    }
    let group = "access_bpf"
    if run("/usr/bin/dscl", [".", "-read", "/Groups/" + group]) != 0 {
        run("/usr/sbin/dseditgroup", ["-o", "create", "-r", "Packet capture", group])
    }
    run("/usr/sbin/dseditgroup", ["-o", "edit", "-a", name, "-t", "user", group])
    let ok = run("/usr/sbin/chown", ["\(name):\(group)"] + devices) == 0
        && run("/bin/chmod", ["0640"] + devices) == 0
    return ["ok": ok]
}

// MARK: - Main

guard getuid() == 0, let listener = listeningSocket() else {
    FileHandle.standardError.write(Data("lowtide-privileged runs under launchd as root\n".utf8))
    exit(1)
}
while true {
    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    // Idle: quit; launchd starts it again on the next connection.
    if poll(&ready, 1, idleSeconds * 1000) <= 0 { exit(0) }
    let client = accept(listener, nil, nil)
    if client >= 0 { handle(client) }
}
