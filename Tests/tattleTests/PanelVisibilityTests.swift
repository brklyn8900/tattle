import Observation
import XCTest
@testable import tattle

/// The panel's views stay alive when it closes, and the sampler and the network readings keep
/// running for the menu bar label and the history. These hold what a closed panel's views see.
@MainActor
final class PanelVisibilityTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var isSet = false }

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Tracks the way a SwiftUI body does: the flag is set when something read in `read` changes.
    private func watching(_ read: () -> Void) -> Flag {
        let changed = Flag()
        withObservationTracking(read, onChange: { changed.isSet = true })
        return changed
    }

    private func nextSample(of sampler: ResourceSampler) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking({ _ = sampler.sample }, onChange: { continuation.resume() })
        }
    }

    func testNetworkReadingsDoNotReachAClosedPanel() async throws {
        let state = try AppState(database: try AppDatabase.inMemory())
        await state.network.fold(entries: [], now: t0)
        XCTAssertEqual(state.panelNetworkSnapshot?.takenAt, t0, "an open panel sees the latest reading")

        state.panelIsShowing = false
        let changed = watching { _ = state.panelNetworkSnapshot }
        let later = t0.addingTimeInterval(2)
        await state.network.fold(entries: [], now: later)
        XCTAssertFalse(changed.isSet, "a reading must not redraw a closed panel")
        XCTAssertEqual(state.panelNetworkSnapshot?.takenAt, t0)
        XCTAssertEqual(state.network.snapshot?.takenAt, later, "the readings themselves go on")

        state.panelIsShowing = true
        XCTAssertTrue(changed.isSet, "opening redraws")
        XCTAssertEqual(state.panelNetworkSnapshot?.takenAt, later, "and shows the latest reading")
    }

    func testSamplesDoNotReachAClosedPanel() async throws {
        let state = try AppState(database: try AppDatabase.inMemory())
        let sampler = state.sampler
        sampler.start(every: .milliseconds(5))
        defer { sampler.stop() }
        await nextSample(of: sampler)
        await nextSample(of: sampler)
        XCTAssertEqual(state.panelSample, sampler.sample, "an open panel sees the latest sample")

        state.panelIsShowing = false
        let held = state.panelSample
        let changed = watching { _ = state.panelSample }
        await nextSample(of: sampler)
        await nextSample(of: sampler)
        XCTAssertFalse(changed.isSet, "a sample must not redraw a closed panel")
        XCTAssertEqual(state.panelSample, held)

        state.panelIsShowing = true
        XCTAssertTrue(changed.isSet, "opening redraws")
        XCTAssertEqual(state.panelSample, sampler.sample, "and shows the latest sample")
    }
}
