import Foundation

/// How this Mac reaches the internet, from `route`, `ipconfig` and `scutil`.
public enum NetLinkReader {
    public static func read() async -> NetLink {
        let route = (try? await Shell.run("/sbin/route", ["-n", "get", "default"], timeout: .seconds(5)))?.stdout ?? ""
        let interface = field(route, "interface:")
        var ip: String?
        if let interface {
            let out = (try? await Shell.run("/usr/sbin/ipconfig", ["getifaddr", interface], timeout: .seconds(5)))?.stdout ?? ""
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            ip = text.isEmpty ? nil : text
        }
        let dns = (try? await Shell.run("/usr/sbin/scutil", ["--dns"], timeout: .seconds(5)))?.stdout ?? ""
        return parse(route: route, ip: ip, dns: dns)
    }

    static func field(_ text: String, _ name: String) -> String? {
        text.split(separator: "\n").lazy.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(name) ? trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces) : nil
        }.first
    }

    public static func parse(route: String, ip: String?, dns: String) -> NetLink {
        let interface = field(route, "interface:")
        return NetLink(interface: interface, ip: ip, gateway: field(route, "gateway:"), dns: field(dns, "nameserver[0] :"),
                       vpn: interface.map { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") } ?? false)
    }
}
