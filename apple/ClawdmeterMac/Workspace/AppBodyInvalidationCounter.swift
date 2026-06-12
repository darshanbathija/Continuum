import Foundation
import ClawdmeterShared

/// App-target bridge for body invalidation counters used by hosted XCTest views.
///
/// The Mac test bundle links its own copy of `ClawdmeterShared`, while app views
/// call the copy linked into the hosted app binary. Tests that exercise app
/// target SwiftUI bodies must toggle/read through this bridge to observe the
/// same counter storage that those views bump.
enum AppBodyInvalidationCounter {
    @MainActor
    static func setEnabled(_ enabled: Bool) {
        BodyInvalidationCounter.enabled = enabled
    }

    @MainActor
    static func resetAll() {
        BodyInvalidationCounter.resetAll()
    }

    @MainActor
    static func count(for label: String) -> Int {
        BodyInvalidationCounter.count(for: label)
    }
}
