import Foundation

/// Reads the agents and daemons folders. Apple's own jobs under /System/Library are
/// counted, not listed.
struct LaunchdReader: Sendable {
    var folders: [LaunchdItem.Scope: URL] = Dictionary(
        uniqueKeysWithValues: LaunchdItem.Scope.allCases.map { ($0, $0.folder) })
    var appleFolders: [URL] = [
        URL(fileURLWithPath: "/System/Library/LaunchAgents"),
        URL(fileURLWithPath: "/System/Library/LaunchDaemons"),
    ]

    struct Result: Equatable, Sendable {
        var items: [LaunchdItem]
        var appleCount: Int
        var unreadable: [Unreadable]
    }

    /// A plist in one of the folders that could not be read: a daemon's owner can make it
    /// readable by root alone, and launchd still runs it.
    struct Unreadable: Equatable, Sendable {
        var url: URL
        var scope: LaunchdItem.Scope
        var reason: String
    }

    func read() -> Result {
        var items: [LaunchdItem] = []
        var unreadable: [Unreadable] = []
        for scope in LaunchdItem.Scope.allCases {
            guard let folder = folders[scope] else { continue }
            for url in plists(in: folder) {
                do {
                    items.append(try LaunchdItem.parse(try Data(contentsOf: url), url: url, scope: scope))
                } catch {
                    unreadable.append(Unreadable(url: url, scope: scope, reason: Self.reason(error)))
                }
            }
        }
        let appleCount = appleFolders.reduce(0) { $0 + plists(in: $1).count }
        return Result(items: items, appleCount: appleCount, unreadable: unreadable)
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case LaunchdItem.ParseError.noLabel: "it has no Label, so launchd rejects it too"
        case LaunchdItem.ParseError.notADictionary: "it is not a launchd job"
        case let error as CocoaError where error.code == .fileReadNoPermission: "Tattle has no permission to read this file"
        case let error as CocoaError where error.code == .propertyListReadCorrupt: "it is not a valid property list"
        default: error.localizedDescription
        }
    }

    private func plists(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
    }
}
