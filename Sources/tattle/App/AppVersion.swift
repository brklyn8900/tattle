import Foundation

/// The app's version as Settings shows it. The release shows its version alone; any other
/// build shows the version it was built from, then "dev" and the commit make app recorded.
enum AppVersion {
    /// The Info.plist key make app records a build's commit in. The release has none.
    static let sourceCommitKey = "TattleSourceCommit"

    static let current = text(info: Bundle.main.infoDictionary ?? [:])

    static func text(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String
        let commit = info[sourceCommitKey] as? String
        if let version, commit == nil { return version }
        // A bundle with no version, such as a bare executable's, is not the release either.
        return "\(version ?? "unknown") dev (\(commit ?? "unknown"))"
    }
}
