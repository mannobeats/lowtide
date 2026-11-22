import os

/// One logger per area, all under the app's subsystem. Never log what a
/// person typed, said, or a secret.
public enum Log {
    private static let subsystem = Paths.bundleID
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let shell = Logger(subsystem: subsystem, category: "shell")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let system = Logger(subsystem: subsystem, category: "system")
    public static let apps = Logger(subsystem: subsystem, category: "apps")
    public static let watch = Logger(subsystem: subsystem, category: "watch")
    public static let terminal = Logger(subsystem: subsystem, category: "terminal")
    public static let voice = Logger(subsystem: subsystem, category: "voice")
    public static let menubar = Logger(subsystem: subsystem, category: "menubar")
}
