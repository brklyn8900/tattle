import Foundation
import os

enum Log {
    /// The bundle's identifier, so the dev build's lines are its own.
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.eladefrati.tattle"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let knowledge = Logger(subsystem: subsystem, category: "knowledge")
    static let sniffer = Logger(subsystem: subsystem, category: "sniffer")
}
