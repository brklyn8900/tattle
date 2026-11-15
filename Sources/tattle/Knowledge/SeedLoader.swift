import Foundation

/// Loads the seed knowledge files (one JSON file per source) from the app into the store's
/// memory, at every launch: the shipped rules are never read from the database (ADR-0005).
struct SeedLoader: Sendable {
    let rules: RuleStore

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
                applied.append(try load(file: url))
            } catch {
                Log.knowledge.error("seed \(url.lastPathComponent, privacy: .public) skipped: \(error, privacy: .public)")
            }
        }
        return applied
    }

    /// The source applied.
    func load(file url: URL) throws -> Rule.Source {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(File.self, from: data)
        let now = Date()
        let rules = file.rules.map { entry in
            Rule(kind: entry.kind, match: entry.match ?? .exact, pattern: entry.pattern,
                 owner: entry.owner, purpose: entry.purpose, why: entry.why, care: entry.care, category: entry.category,
                 risk: entry.risk, confidence: entry.confidence, source: file.source, identity: entry.identity ?? "", created: now)
        }
        try self.rules.replaceShipped(source: file.source, with: rules)
        Log.knowledge.info("seed \(url.lastPathComponent, privacy: .public): \(rules.count) rules")
        return file.source
    }
}
