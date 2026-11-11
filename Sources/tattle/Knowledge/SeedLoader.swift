import CryptoKit
import Foundation

/// Loads the seed knowledge files (one JSON file per source) into the rule table. A file
/// is applied only when its contents changed since the last load, and applying it
/// replaces that source's rules while keeping any confirmation the user gave.
struct SeedLoader: Sendable {
    let rules: RuleStore
    let settings: SettingsStore

    struct File: Decodable {
        var source: Rule.Source
        var rules: [Entry]

        struct Entry: Decodable {
            var kind: Rule.Kind
            var match: Rule.Match?
            var pattern: String
            var owner: String?
            var purpose: String
            var why: String?
            var care: String?
            var category: String?
            var risk: Rule.Level?
            var confidence: Rule.Level?
            var identity: String?
        }
    }

    enum SeedError: Error {
        /// Seed files may only carry shipped sources; user, iap and llm rules are made at runtime.
        case notASeedSource(Rule.Source)
    }

    static let seedSources: Set<Rule.Source> = [.builtin, .appleList, .trackerRadar]

    /// Applies every `*.json` in `folder`. A missing folder or an unreadable file is
    /// logged and skipped: the app runs without any seed. Returns the sources applied.
    @discardableResult
    func load(from folder: URL) -> [Rule.Source] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)
        else {
            Log.knowledge.notice("no seed folder at \(folder.path, privacy: .public)")
            return []
        }
        var applied: [Rule.Source] = []
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            do {
                if let source = try load(file: url) { applied.append(source) }
            } catch {
                Log.knowledge.error("seed \(url.lastPathComponent, privacy: .public) skipped: \(error, privacy: .public)")
            }
        }
        return applied
    }

    /// The source applied, or nil when the file's hash matched the last load.
    func load(file url: URL) throws -> Rule.Source? {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "seed." + url.lastPathComponent + ".hash"
        if try settings.string(key) == hash { return nil }

        let file = try JSONDecoder().decode(File.self, from: data)
        guard Self.seedSources.contains(file.source) else {
            throw SeedError.notASeedSource(file.source)
        }
        let now = Date()
        let rules = file.rules.map { entry in
            Rule(kind: entry.kind, match: entry.match ?? .exact, pattern: entry.pattern,
                 owner: entry.owner, purpose: entry.purpose, why: entry.why, care: entry.care, category: entry.category,
                 risk: entry.risk, confidence: entry.confidence, source: file.source, identity: entry.identity ?? "", created: now)
        }
        try self.rules.replaceAll(source: file.source, with: rules)
        try settings.set(key, hash)
        Log.knowledge.info("seed \(url.lastPathComponent, privacy: .public): \(rules.count) rules")
        return file.source
    }
}
