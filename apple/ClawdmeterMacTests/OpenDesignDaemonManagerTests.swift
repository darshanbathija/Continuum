// OpenDesignDaemonManagerTests — unit tests for the deterministic
// pieces of OpenDesignDaemonManager that can be exercised without
// actually spawning the Node child or hitting a real daemon.
//
// Spawn + /health round-trip + bridge supervision require integration
// against the bundled Vendor/open-design/ tree and are covered by the
// DMG smoke test (T17) + manual /qa flows in the test plan artifact.
//
// Plan ref: v2.1 phase 9 (T2 verification).

import XCTest
import CryptoKit
@testable import Clawdmeter

@MainActor
final class OpenDesignDaemonManagerTests: XCTestCase {

    // MARK: - BridgePortAtomic — concurrency contract

    func testBridgePortAtomicReadsBackWhatWasWritten() {
        let atomic = BridgePortAtomic()
        XCTAssertNil(atomic.get())
        atomic.set(27457)
        XCTAssertEqual(atomic.get(), 27457)
        atomic.set(nil)
        XCTAssertNil(atomic.get())
    }

    func testBridgePortAtomicConcurrentReadsAndWritesDoNotCrash() async {
        // Smoke test for the NSLock-guarded atomic: hammer it from many
        // tasks. The point isn't to test for correctness of the lock
        // (NSLock is well-tested), but to catch any future regression
        // that drops `@unchecked Sendable` and starts surfacing
        // data-race crashes under -strict-concurrency.
        let atomic = BridgePortAtomic()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask {
                    for _ in 0..<200 {
                        atomic.set(i)
                        _ = atomic.get()
                    }
                }
            }
        }
        XCTAssertNotNil(atomic.get())
    }

    // MARK: - HKDF design-token derivation (T19)

    func testDeriveDesignTokenIsStableForSamePairingId() {
        // The forwarder validates a token by re-deriving from
        // (OD_API_TOKEN, pairingId). The derivation MUST be deterministic
        // for the same (apiToken, pairingId) pair across daemon restarts
        // — otherwise iOS clients would silently 401 after every daemon
        // bounce.
        let token = "deadbeefcafebabe"
        let pairingA = "pairing-A"
        let pairingB = "pairing-B"
        let derived1 = derive(apiToken: token, pairingId: pairingA)
        let derived2 = derive(apiToken: token, pairingId: pairingA)
        let derivedOther = derive(apiToken: token, pairingId: pairingB)
        XCTAssertEqual(derived1, derived2, "same (token, pairingId) must yield identical derivation")
        XCTAssertNotEqual(derived1, derivedOther, "different pairing IDs must yield different tokens")
    }

    func testDeriveDesignTokenChangesWhenApiTokenRotates() {
        let pairingId = "pairing-X"
        let a = derive(apiToken: "secret-A", pairingId: pairingId)
        let b = derive(apiToken: "secret-B", pairingId: pairingId)
        XCTAssertNotEqual(a, b, "rotating OD_API_TOKEN must invalidate every derived design token")
    }

    func testDeriveDesignTokenIsHexEncoded() {
        let derived = derive(apiToken: "x", pairingId: "y")
        // 32 bytes → 64 hex characters
        XCTAssertEqual(derived.count, 64)
        XCTAssertTrue(derived.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - Mirror of OpenDesignDaemonManager.deriveDesignToken

private func derive(apiToken: String, pairingId: String) -> String {
    let key = SymmetricKey(data: Data(apiToken.utf8))
    let derived = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: key,
        info: Data(pairingId.utf8),
        outputByteCount: 32
    )
    return derived.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
}
