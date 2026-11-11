import Foundation

/// One record from the login-items database that System Settings manages
/// (General, Login Items & Extensions).
struct LoginItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// An app set to open at login.
        case app
        /// A helper inside an app's Contents/Library/LoginItems.
        case loginItemHelper
        /// A launch agent, registered by its app or found as a plist.
        case agent
        case daemon
        case backgroundRefresh
        /// Runs when Spotlight indexes the app's file types.
        case spotlightImporter
        /// Runs while the app is in the Dock.
        case dockTilePlugin
        /// Quick Look, thumbnails, sharing and the like: runs when macOS needs it.
        case appExtension
        /// Developer groups and anything unrecognised.
        case other(type: Int)
    }

    var identifier: String
    var name: String
    var kind: Kind
    var developerName: String?
    var teamIdentifier: String?
    var bundleIdentifier: String?
    var executablePath: String?
    /// The app bundle, the plist, or a path relative to the container.
    var url: String?
    /// The parent record: the app for a helper, the developer for a plist item.
    var container: String?
    /// Set to run: an app added to Open at Login, or a helper its app registered.
    var enabled: Bool
    /// The System Settings toggle: the user permits it.
    var allowed: Bool
    var hidden: Bool
    var notified: Bool
    /// Found as a plist on disk rather than registered through SMAppService.
    var legacy: Bool

    /// The launchd label: a legacy record has no bundle identifier, and keeps the label after
    /// its type in the identifier.
    var jobLabel: String? {
        bundleIdentifier ?? (legacy ? identifier.split(separator: ".", maxSplits: 1).last.map(String.init) : nil)
    }

    var isStartupItem: Bool {
        switch kind {
        case .app, .loginItemHelper, .agent, .daemon, .backgroundRefresh: true
        case .spotlightImporter, .dockTilePlugin, .appExtension, .other: false
        }
    }

    /// A launch agent or daemon: a plist says what it runs.
    var isLaunchItem: Bool { kind == .agent || kind == .daemon }

    var isExtension: Bool {
        switch kind {
        case .spotlightImporter, .dockTilePlugin, .appExtension: true
        default: false
        }
    }
}

/// The BackgroundItems-v*.btm file: an NSKeyedArchiver archive whose top-level `store` is
/// a Storage object, with itemsByUserIdentifier mapping each user to its ItemRecords.
/// Decoded by substituting a generic record class for the private ones, so unknown keys
/// and schema versions are tolerated.
struct LoginItemsDatabase: Sendable {
    static let folder = URL(fileURLWithPath: "/private/var/db/com.apple.backgroundtaskmanagement")
    static let storeKey = "store"

    /// The archive's own schema version (16 on macOS 26).
    var version: Int
    var items: [LoginItem]

    enum ReadError: Error, Equatable {
        /// The folder could not be listed. It is readable by anyone on disk, but macOS
        /// gates it behind Full Disk Access.
        case cannotList(String)
        case noDatabase
        case notAStorage
    }

    /// The newest BackgroundItems-v*.btm in the system folder.
    static func currentFile() throws -> URL? {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch {
            throw ReadError.cannotList(error.localizedDescription)
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("BackgroundItems-v") && $0.pathExtension == "btm" }
            .max { version(of: $0) < version(of: $1) }
    }

    private static func version(of url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("BackgroundItems-v".count)) ?? 0
    }

    static func readCurrent() throws -> LoginItemsDatabase {
        guard let file = try currentFile() else { throw ReadError.noDatabase }
        return try parse(Data(contentsOf: file))
    }

    static func parse(_ data: Data) throws -> LoginItemsDatabase {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.setClass(BTMStorage.self, forClassName: "Storage")
        unarchiver.setClass(BTMRecord.self, forClassName: "ItemRecord")
        unarchiver.setClass(BTMRecord.self, forClassName: "BTMUserSettings")
        guard let storage = unarchiver.decodeObject(of: BTMStorage.self, forKey: storeKey) else {
            throw ReadError.notAStorage
        }
        let version = unarchiver.decodeInteger(forKey: "version")
        unarchiver.finishDecoding()

        // The same developer group appears under several users; keep one record per
        // identifier, the first with a name.
        var seen: [String: LoginItem] = [:]
        var order: [String] = []
        for records in storage.itemsByUser.sorted(by: { $0.key < $1.key }).map(\.value) {
            for record in records {
                let item = record.loginItem
                if let existing = seen[item.identifier], !(existing.name.isEmpty && !item.name.isEmpty) { continue }
                if seen[item.identifier] == nil { order.append(item.identifier) }
                seen[item.identifier] = item
            }
        }
        return LoginItemsDatabase(version: version, items: order.compactMap { seen[$0] })
    }
}

/// Stand-in for the private ItemRecord class: decodes the keys Tattle uses and ignores
/// the rest. Also encodes them, which the tests use to build fixtures.
final class BTMRecord: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    enum Key {
        static let strings = ["name", "identifier", "developerName", "teamIdentifier", "bundleIdentifier", "executablePath", "container"]
        static let integers = ["type", "disposition"]
    }

    var strings: [String: String] = [:]
    var integers: [String: Int] = [:]
    var url: String?
    var items: [String] = []

    override init() {}

    init(_ strings: [String: String], type: Int, disposition: Int, url: String? = nil, items: [String] = []) {
        self.strings = strings
        self.integers = ["type": type, "disposition": disposition]
        self.url = url
        self.items = items
    }

    required init?(coder: NSCoder) {
        for key in Key.strings {
            if let value = coder.decodeObject(of: NSString.self, forKey: key) { strings[key] = value as String }
        }
        for key in Key.integers where coder.containsValue(forKey: key) {
            integers[key] = coder.decodeInteger(forKey: key)
        }
        url = coder.decodeObject(of: NSURL.self, forKey: "url")?.relativeString
        items = coder.decodeObject(of: [NSArray.self, NSString.self], forKey: "items") as? [String] ?? []
    }

    func encode(with coder: NSCoder) {
        for (key, value) in strings { coder.encode(value as NSString, forKey: key) }
        for (key, value) in integers { coder.encode(value, forKey: key) }
        if let url { coder.encode(NSURL(string: url), forKey: "url") }
        coder.encode(items as NSArray, forKey: "items")
    }

    /// Type bits, as the private framework uses them.
    enum TypeBit {
        static let app = 0x2
        static let loginItemHelper = 0x4
        static let agent = 0x8
        static let daemon = 0x10
        static let developer = 0x20
        static let spotlightImporter = 0x40
        static let dockTilePlugin = 0x80
        static let appExtension = 0x800
        static let backgroundRefresh = 0x1000
        static let legacy = 0x10000
    }

    enum DispositionBit {
        static let enabled = 0x1, allowed = 0x2, hidden = 0x4, notified = 0x8
    }

    var loginItem: LoginItem {
        let type = integers["type"] ?? 0
        let disposition = integers["disposition"] ?? 0
        let kind: LoginItem.Kind
        switch type & ~TypeBit.legacy {
        case TypeBit.app: kind = .app
        case TypeBit.loginItemHelper: kind = .loginItemHelper
        case TypeBit.agent: kind = .agent
        case TypeBit.daemon: kind = .daemon
        case TypeBit.backgroundRefresh: kind = .backgroundRefresh
        case TypeBit.spotlightImporter: kind = .spotlightImporter
        case TypeBit.dockTilePlugin: kind = .dockTilePlugin
        case TypeBit.appExtension: kind = .appExtension
        default: kind = .other(type: type)
        }
        let identifier = strings["identifier"] ?? ""
        return LoginItem(
            identifier: identifier,
            name: strings["name"] ?? strings["developerName"] ?? identifier,
            kind: kind,
            developerName: strings["developerName"],
            teamIdentifier: strings["teamIdentifier"],
            bundleIdentifier: strings["bundleIdentifier"],
            executablePath: strings["executablePath"],
            url: url,
            container: strings["container"],
            enabled: disposition & DispositionBit.enabled != 0,
            allowed: disposition & DispositionBit.allowed != 0,
            hidden: disposition & DispositionBit.hidden != 0,
            notified: disposition & DispositionBit.notified != 0,
            legacy: type & TypeBit.legacy != 0)
    }
}

/// Stand-in for the private Storage class.
final class BTMStorage: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    var itemsByUser: [String: [BTMRecord]] = [:]

    init(itemsByUser: [String: [BTMRecord]]) {
        self.itemsByUser = itemsByUser
    }

    required init?(coder: NSCoder) {
        itemsByUser = coder.decodeObject(
            of: [NSDictionary.self, NSString.self, NSArray.self, BTMRecord.self],
            forKey: "itemsByUserIdentifier") as? [String: [BTMRecord]] ?? [:]
    }

    func encode(with coder: NSCoder) {
        coder.encode(itemsByUser as NSDictionary, forKey: "itemsByUserIdentifier")
    }
}
