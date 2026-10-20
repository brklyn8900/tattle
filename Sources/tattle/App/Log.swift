import os

enum Log {
    static let subsystem = "io.github.eladefrati.tattle"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let knowledge = Logger(subsystem: subsystem, category: "knowledge")
}
