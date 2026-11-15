import Foundation
@testable import tattle

// The builders as most tests call them, with one table of signatures by path: each process
// reads as the file at its path, which is what a process runs unless a test says otherwise
// (`RunningCodeTests`). The app's own calls say how each process is read.

extension ProcessSnapshot {
    static func build(
        entries: [ProcessEntry], previous: ProcessSnapshot?, continuesPrevious: Bool = true,
        signature: (String) -> CodeSignature?, runningApp: (Int32) -> String? = { _ in nil },
        mainExecutable: (AppBundle) -> String? = { Bundle(path: $0.path)?.executablePath },
        responsible: (Int32) -> Int32? = ResponsibleProcess.pid(for:), takenAt: Date = Date()
    ) -> ProcessSnapshot {
        build(entries: entries, previous: previous, continuesPrevious: continuesPrevious,
              signature: signature, executable: { SignatureCache.ProcessReading(signature: signature($1)) }, runningApp: runningApp,
              mainExecutable: mainExecutable, responsible: responsible, takenAt: takenAt)
    }
}

extension PortsSnapshot {
    static func build(
        entries: [SocketEntry], services: ServiceNames,
        processes: (Int32) -> ProcessEntry?, signature: (String) -> CodeSignature?, takenAt: Date = Date()
    ) -> PortsSnapshot {
        build(entries: entries, services: services, processes: processes, executable: { signature($1) }, takenAt: takenAt)
    }
}

extension ConnectionOwner {
    static func resolve(
        pid: Int32, in byPid: [Int32: ProcessEntry], runningApp: (Int32) -> String?,
        responsible: (Int32) -> Int32? = ResponsibleProcess.pid(for:), signature: (String) -> CodeSignature?
    ) -> ConnectionOwner {
        resolve(pid: pid, in: byPid, runningApp: runningApp, responsible: responsible, executable: { signature($1) }, signature: signature)
    }
}

extension ProcessTable {
    static func read(
        fallback: ([Int32]) -> [Int32: ProcessUsage] = ProcessUsageFallback.read, signature: (String) -> CodeSignature?
    ) throws -> [ProcessEntry] {
        try read(fallback: fallback, signature: { signature($1) })
    }

    static func list(signature: (String) -> CodeSignature?) throws -> [ProcessEntry] {
        try list(signature: { signature($1) })
    }
}

extension NetworkObserver {
    convenience init(
        store: ConnectionStore, rules: RuleStore, settings: AppSettings,
        socketTable: @escaping @Sendable () throws -> [SocketEntry] = { try SocketTable.read() },
        processRecords: @escaping @Sendable () -> ProcessRecords? = { ProcessTable.records() },
        signature: @escaping @Sendable (String) -> CodeSignature?
    ) {
        self.init(store: store, rules: rules, settings: settings, socketTable: socketTable, processRecords: processRecords,
                  signature: signature, executable: { SignatureCache.ProcessReading(signature: signature($1)) })
    }
}
