import os

/// Flow events on their way from the sniffer's thread to the main actor, at most `capacity`
/// of them. What the sniffer reports is bounded by the packets on the wire, and what the main
/// actor handles by a database write for each outcome, so events can arrive faster than they
/// are handled; what arrives while the mailbox is full is dropped and counted. One drain
/// empties it at a time.
final class FlowEventMailbox: Sendable {
    static let capacity = 4096

    private struct State {
        var events: [FlowEvent] = []
        var dropped = 0
        var draining = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Adds what fits. True when no drain is under way, and the caller is to start one.
    func add(_ events: [FlowEvent]) -> Bool {
        state.withLock { state in
            let room = Self.capacity - state.events.count
            state.events += events.prefix(room)
            state.dropped += max(0, events.count - room)
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
    }

    /// The oldest events, at most `count`, and how many were dropped since the last call.
    /// Nil when there is nothing of either, which ends the drain.
    func take(_ count: Int) -> (events: [FlowEvent], dropped: Int)? {
        state.withLock { state in
            let dropped = state.dropped
            state.dropped = 0
            guard !state.events.isEmpty || dropped > 0 else {
                state.draining = false
                return nil
            }
            let taken = Array(state.events.prefix(count))
            state.events.removeFirst(taken.count)
            return (taken, dropped)
        }
    }
}
