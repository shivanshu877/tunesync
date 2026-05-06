import Foundation
import os

public enum Log {
    private static let subsystem = "com.tunesync.app"

    public static let mesh = Logger(subsystem: subsystem, category: "mesh")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let player = Logger(subsystem: subsystem, category: "player")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
