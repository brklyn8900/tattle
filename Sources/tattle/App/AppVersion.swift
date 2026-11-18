import Foundation

/// The app's version as Settings shows it, alike in every copy: the version and, in
/// parentheses, the commit make app recorded. A copy that lacks one shows the other alone,
/// and one that lacks both shows "Unknown".
enum AppVersion {
    /// The Info.plist key make app records the version in.
    static let versionKey = "CFBundleShortVersionString"
    /// The Info.plist key make app records the commit in.
    static let sourceCommitKey = "TattleSourceCommit"

    static let current = text(info: Bundle.main.infoDictionary ?? [:])

    static func text(info: [String: Any]) -> String {
        // Only a release's form is a version, so a placeholder in the version key reads as none.
        let version = (info[versionKey] as? String).flatMap {
            $0.wholeMatch(of: #/[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*/#) == nil ? nil : $0
        }
        let commit = (info[sourceCommitKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch (version, commit) {
        case let (version?, commit?): return "\(version) (\(commit))"
        case let (version?, nil): return version
        case let (nil, commit?): return commit
        case (nil, nil): return "Unknown"
        }
    }
}
