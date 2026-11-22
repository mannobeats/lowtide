import Foundation
import Synchronization

/// Who runs a server and where it is registered.
public struct Place: Sendable, Hashable, Codable {
    /// ISO 3166 alpha-2 country the address is registered in.
    public var country: String?
    /// The network's owner: "Amazon.com", "Cloudflare".
    public var org: String?
    public var asn: UInt32?

    public init(country: String?, org: String?, asn: UInt32?) {
        self.country = country
        self.org = org
        self.asn = asn
    }
}

/// Where a server is registered and who runs it, from DB-IP's free country
/// and ASN databases (CC BY 4.0) shipped inside the app: no lookup leaves
/// the Mac.
public final class GeoIP: Sendable {
    public static let shared = GeoIP(
        country: AppResources.url("geo/dbip-country-lite.mmdb"),
        asn: AppResources.url("geo/dbip-asn-lite.mmdb"))

    private let country: MMDBReader?
    private let asn: MMDBReader?
    private let cache = Mutex<[String: Place?]>([:])
    private static let maxCache = 20_000

    public init(country: URL, asn: URL) {
        do { self.country = try MMDBReader(url: country) } catch {
            Log.network.error("country database unavailable: \(error.localizedDescription, privacy: .public)")
            self.country = nil
        }
        do { self.asn = try MMDBReader(url: asn) } catch {
            Log.network.error("ASN database unavailable: \(error.localizedDescription, privacy: .public)")
            self.asn = nil
        }
    }

    public var available: Bool { country != nil }

    /// The place of a remote address, cached. Local addresses have none.
    public func lookup(_ ip: String) -> Place? {
        guard Self.isPublic(ip) else { return nil }
        if let hit = cache.withLock({ $0[ip] }) { return hit }
        let code = country?.lookup(ip, path: ["country", "iso_code"])?.string
        let number = asn?.lookup(ip, path: ["autonomous_system_number"])?.uint
        let owner = asn?.lookup(ip, path: ["autonomous_system_organization"])?.string
        let place = code == nil && owner == nil ? nil
            : Place(country: code, org: owner.map(Self.tidyOrg), asn: number.map { UInt32(truncatingIfNeeded: $0) })
        cache.withLock {
            if $0.count >= Self.maxCache { $0.removeAll(keepingCapacity: true) }
            $0[ip] = .some(place)
        }
        return place
    }

    /// Addresses that never leave the local network.
    public static func isPublic(_ ip: String) -> Bool {
        guard let bytes = MMDBReader.parse(ip) else { return false }
        if bytes.count == 4 {
            let (a, b) = (bytes[0], bytes[1])
            if a == 10 || a == 127 || a == 0 || a >= 224 { return false }
            if a == 172, b & 0xF0 == 16 { return false }
            if a == 192, b == 168 { return false }
            if a == 169, b == 254 { return false }
            // Carrier-grade NAT, 100.64.0.0/10.
            if a == 100, b & 0xC0 == 64 { return false }
            return true
        }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false }
        if bytes[0] == 0xFF { return false }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
        if bytes[0] & 0xFE == 0xFC { return false }
        // IPv4-mapped: judge the IPv4 address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPublic(bytes[12...].map(String.init).joined(separator: "."))
        }
        return true
    }

    /// "Amazon.com, Inc." → "Amazon.com"; "GOOGLE" → "Google".
    public static func tidyOrg(_ org: String) -> String {
        var name = org.trimmingCharacters(in: .whitespaces)
        for suffix in [", Inc.", ", PBC", " Inc.", ", Inc", " Inc", ", LLC", " LLC", " Ltd.", " Ltd", " Limited",
                       " GmbH", " B.V.", " S.A.", ", Co.", " Corporation", " Corp."] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.count > 3, !name.contains(where: \.isLowercase) {
            var out = ""
            var start = true
            for c in name {
                out += start ? c.uppercased() : c.lowercased()
                start = !(c.isLetter || c.isNumber)
            }
            return out
        }
        return name
    }

    /// The network an address belongs to, for sharing a measured round trip
    /// between its connections: a /24 for IPv4, a /48 for IPv6.
    public static func prefix(_ ip: String) -> String? {
        guard let bytes = MMDBReader.parse(ip) else { return nil }
        return bytes.count == 4 ? bytes[0..<3].map(String.init).joined(separator: ".")
            : bytes[0..<6].map { String(format: "%02x", $0) }.joined()
    }
}
