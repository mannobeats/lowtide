import Foundation

/// The one HTTP client: update checks and model downloads only. No cookies,
/// no cache on disk, a plain user agent that says nothing about the Mac.
public enum HTTP {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        config.httpAdditionalHeaders = ["User-Agent": "Lowtide/\(version)"]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static func data(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LowtideError.commandFailed("\(url.host() ?? "server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    public static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(url))
    }
}
