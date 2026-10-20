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
        /// Plists that could not be read, by path, with the reason.
        var skipped: [String: String]
    }

    func read() -> Result {
        var items: [LaunchdItem] = []
        var skipped: [String: String] = [:]
        for scope in LaunchdItem.Scope.allCases {
            guard let folder = folders[scope] else { continue }
            for url in plists(in: folder) {
                do {
                    items.append(try LaunchdItem.parse(try Data(contentsOf: url), url: url, scope: scope))
                } catch {
                    skipped[url.path] = String(describing: error)
                }
            }
        }
        let appleCount = appleFolders.reduce(0) { $0 + plists(in: $1).count }
        return Result(items: items, appleCount: appleCount, skipped: skipped)
    }

    private func plists(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
    }
}
