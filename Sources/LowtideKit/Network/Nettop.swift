import Foundation

/// A socket as `nettop` names it: `tcp4 192.168.0.157:55786<->17.57.144.154:5223`,
/// or for IPv6 `tcp6 fe80::1%lo0.49152<->*.*` (the port follows the last dot).
public struct NetSocket: Sendable, Hashable {
    /// `tcp`, `udp` or `quic` (HTTP/3 flows, listed apart from plain UDP).
    public var proto: String
    public var v6: Bool
    public var localIP: String
    public var localPort: UInt16
    public var remoteIP: String
    public var remotePort: UInt16
    /// The text nettop printed: unique per socket within a process.
    public var key: String

    public init?(_ text: String) {
        guard let space = text.firstIndex(of: " ") else { return nil }
        switch text[..<space] {
        case "tcp4": (proto, v6) = ("tcp", false)
        case "tcp6": (proto, v6) = ("tcp", true)
        case "udp4": (proto, v6) = ("udp", false)
        case "udp6": (proto, v6) = ("udp", true)
        case "quic4": (proto, v6) = ("quic", false)
        case "quic6": (proto, v6) = ("quic", true)
        default: return nil
        }
        let addresses = text[text.index(after: space)...]
        guard let arrow = addresses.range(of: "<->") else { return nil }
        let separator: Character = v6 ? "." : ":"
        func split(_ part: Substring) -> (String, UInt16) {
            guard let cut = part.lastIndex(of: separator) else { return (String(part), 0) }
            return (String(part[..<cut]), UInt16(part[part.index(after: cut)...]) ?? 0)
        }
        (localIP, localPort) = split(addresses[..<arrow.lowerBound])
        (remoteIP, remotePort) = split(addresses[arrow.upperBound...])
        key = text
    }

    public var listening: Bool { remoteIP == "*" }

    public var loopback: Bool {
        remoteIP.hasPrefix("127.") || remoteIP == "::1" || remoteIP.hasPrefix("fe80::1%lo0")
    }
}

/// One socket in one `nettop` snapshot, with the totals it moved since it opened.
public struct NettopRow: Sendable, Hashable {
    public var pid: Int32
    /// nettop's (truncated) process name.
    public var name: String
    public var socket: NetSocket
    public var iface: String
    public var state: String
    public var bytesIn: Int64
    public var bytesOut: Int64
    /// The best round trip seen: what the distance check trusts.
    public var rttMin: Double?
    /// The average round trip: what the person sees as "ping".
    public var rttAvg: Double?
}

/// Live sockets of every process, from `nettop` (no root needed).
public enum Nettop {
    public static let arguments = ["-L", "1", "-n", "-x", "-J", "interface,state,bytes_in,bytes_out,rtt_min,rtt_avg"]

    /// Parses one CSV snapshot. Columns are read from the header (nettop
    /// warns their order may change); a process line (`Safari.512`) is
    /// followed by its sockets.
    public static func parse(_ text: String) -> [NettopRow] {
        var rows: [NettopRow] = []
        var column: [String: Int] = [:]
        var pid: Int32 = 0
        var name = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if line.hasPrefix(",") {
                column = [:]
                for (i, field) in fields.enumerated() where !field.isEmpty { column[String(field)] = i }
                continue
            }
            guard let first = fields.first else { continue }
            func field(_ key: String, _ fallback: Int) -> Substring {
                let i = column[key] ?? fallback
                return i >= 0 && i < fields.count ? fields[i] : ""
            }
            if let socket = NetSocket(String(first)) {
                rows.append(NettopRow(
                    pid: pid, name: name, socket: socket,
                    iface: String(field("interface", 1)), state: String(field("state", 2)),
                    bytesIn: Int64(field("bytes_in", 3)) ?? 0, bytesOut: Int64(field("bytes_out", 4)) ?? 0,
                    rttMin: milliseconds(field("rtt_min", -1)), rttAvg: milliseconds(field("rtt_avg", 5))))
            } else if let dot = first.lastIndex(of: "."), let id = Int32(first[first.index(after: dot)...]) {
                pid = id
                name = String(first[..<dot])
            }
        }
        return rows
    }

    /// `48.78 ms` → 48.78.
    static func milliseconds(_ text: Substring) -> Double? {
        let trimmed = text.hasSuffix(" ms") ? text.dropLast(3) : text
        guard let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    /// Who signed a binary, from `codesign -dv --verbose=2`'s stderr.
    public static func parseSignature(_ text: String) -> Signature {
        if text.contains("not signed at all") { return .unsigned }
        let authorities = text.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("Authority=") ? String(line.dropFirst("Authority=".count)) : nil
        }
        if let first = authorities.first {
            if first == "Software Signing" || first == "macOS Software Signing" { return .apple }
            if first == "Apple Mac OS Application Signing" { return .appStore }
            if first.hasPrefix("Developer ID Application: ") { return .developer(String(first.dropFirst(26))) }
            if first.hasPrefix("Apple Development: ") { return .development(String(first.dropFirst(19))) }
        }
        if text.contains("Signature=adhoc") { return .adHoc }
        if text.contains("Platform identifier=") { return .apple }
        return .unknown
    }

    /// The outermost `.app` an executable lives in: helpers of
    /// `Google Chrome.app/…/Google Chrome Helper.app` belong to Chrome.
    public static func appBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// A command-line tool's name: its file name, or for a versioned install
    /// (`~/.local/share/claude/versions/2.1.283`) the folder it belongs to.
    public static func toolName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last else { return path }
        guard file.first?.isNumber == true else { return file }
        for dir in parts.dropLast().reversed()
        where !["versions", "bin", "current", "lib"].contains(dir) && dir.first?.isNumber != true {
            return dir
        }
        return file
    }
}
