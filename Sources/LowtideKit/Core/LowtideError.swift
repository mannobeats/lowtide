import Foundation

/// Every failure a person can see, worded for them.
public enum LowtideError: LocalizedError, Equatable, Sendable {
    case toolMissing(String)
    case commandFailed(String)
    case cancelled
    case notFound(String)
    case denied(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool): "\(tool) isn't installed"
        case .commandFailed(let message): message
        case .cancelled: "Cancelled"
        case .notFound(let what): "\(what) wasn't found"
        case .denied(let why): why
        case .invalid(let why): why
        }
    }
}
