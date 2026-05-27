import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// A9-B: iOS-relayed daemon endpoints accept paths only under
/// `clawdmeter.repos.defaultParent` or one of the user's configured scan
/// roots, minus a hardcoded deny-list. These tests use an isolated
/// `UserDefaults` suite so they never touch the user's real preferences.
final class PathAllowListTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "path-allow-list-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Wipe any state that might survive across tests in the same suite name.
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Allow-list resolution

    func test_resolveAllowedRoots_defaultsToHomeCode_whenUnset() {
        let roots = PathAllowList.resolveAllowedRoots(userDefaults: defaults)
        let expected = (NSHomeDirectory() as NSString).appendingPathComponent("code")
        XCTAssertEqual(roots.first, expected)
    }

    func test_resolveAllowedRoots_includesScanRoots_inOrder_andDedups() {
        defaults.set("/Volumes/Code", forKey: PathAllowList.defaultParentKey)
        defaults.set(["/Volumes/Code", "/Volumes/Other"], forKey: RepoIndex.scanRootsKey)
        let roots = PathAllowList.resolveAllowedRoots(userDefaults: defaults)
        XCTAssertEqual(roots, ["/Volumes/Code", "/Volumes/Other"])
    }

    // MARK: - Positive cases

    func test_validate_acceptsPathUnderDefaultParent() {
        let home = NSHomeDirectory()
        defaults.set("\(home)/code", forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate("\(home)/code/my-repo", userDefaults: defaults)
        XCTAssertNoThrow(try result.get())
    }

    func test_validate_acceptsPathEqualToAllowedRoot() {
        let home = NSHomeDirectory()
        defaults.set("\(home)/code", forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate("\(home)/code", userDefaults: defaults)
        XCTAssertNoThrow(try result.get())
    }

    // MARK: - Negative cases

    func test_validate_rejectsPathOutsideAllowList() {
        let home = NSHomeDirectory()
        defaults.set("\(home)/code", forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate("\(home)/Documents/private", userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed):
            break
        default:
            XCTFail("Expected .pathNotAllowed; got \(result)")
        }
    }

    func test_validate_rejectsTraversalEscape() {
        let home = NSHomeDirectory()
        defaults.set("\(home)/code", forKey: PathAllowList.defaultParentKey)
        // `/<home>/code/../../etc` canonicalizes to `/<home>/../etc` →
        // typically resolves to /etc — outside allow-list.
        let traversal = "\(home)/code/../../etc"
        let result = PathAllowList.validate(traversal, userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed):
            break
        default:
            XCTFail("Traversal escape must be rejected; got \(result)")
        }
    }

    func test_validate_rejectsDeniedSubpath_dotSsh() {
        let home = NSHomeDirectory()
        // Even if the user has `~` in their allow-list, ~/.ssh is denied.
        defaults.set(home, forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate("\(home)/.ssh", userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed(let reason)):
            XCTAssertTrue(reason.contains("deny-list"), "Reason should mention deny-list; got \(reason)")
        default:
            XCTFail("Expected deny-list rejection; got \(result)")
        }
    }

    func test_validate_rejectsDeniedSubpath_library() {
        let home = NSHomeDirectory()
        defaults.set(home, forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate("\(home)/Library/Some/Dir", userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed(let reason)):
            XCTAssertTrue(reason.contains("deny-list"))
        default:
            XCTFail("Expected deny-list rejection; got \(result)")
        }
    }

    // MARK: - P0a: symlink bypass

    /// The attack: user (or attacker with a paired iPhone) creates
    /// `<allowed>/link -> /etc` and submits `<allowed>/link/file` as the
    /// quick-start parent. String-prefix check would accept (path starts
    /// with `<allowed>/`), but the actual mkdir/git init follows the
    /// symlink and writes outside the allow-list. Canonicalization must
    /// resolve the symlink before the prefix check.
    func test_validate_rejectsSymlinkPointingOutsideAllowList() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plal-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let allowedRoot = tempDir.appendingPathComponent("allowed")
        let outsideTarget = tempDir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)

        // Plant the malicious symlink: <allowed>/link -> <outside>
        let symlink = allowedRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)

        defaults.set(allowedRoot.path, forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate(symlink.path, userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed):
            break // expected
        default:
            XCTFail("Symlink pointing outside allow-list must reject; got \(result)")
        }
    }

    /// Quick Start passes `parent/name` where `name` doesn't exist yet.
    /// If `parent` is a symlink pointing outside the allow-list, the
    /// validate path must still resolve it (the deepest-existing-ancestor
    /// walk).
    func test_validate_rejectsParentSymlink_whenChildDoesntExistYet() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plal-parent-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let allowedRoot = tempDir.appendingPathComponent("allowed")
        let outsideTarget = tempDir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)

        // <allowed>/link -> <outside>. Submit <allowed>/link/newrepo (the
        // `newrepo` segment doesn't exist — Quick Start case).
        let symlink = allowedRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)

        defaults.set(allowedRoot.path, forKey: PathAllowList.defaultParentKey)
        let target = symlink.appendingPathComponent("newrepo").path
        let result = PathAllowList.validate(target, userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed):
            break // expected
        default:
            XCTFail("Symlinked parent must reject before Quick Start runs; got \(result)")
        }
    }

    /// R2-P0: Walking up >256 nonexistent components used to give up and
    /// return the standardized (NOT symlink-resolved) path, so an
    /// attacker with a symlink near the allow-list root could dodge
    /// resolution by submitting a very deep path. Fix: cap-fail-closed —
    /// any submission deeper than the cap rejects rather than slipping
    /// past unresolved.
    func test_validate_rejectsExtremelyDeepPath() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plal-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let allowedRoot = tempDir.appendingPathComponent("allowed")
        let outsideTarget = tempDir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        let symlink = allowedRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)

        defaults.set(allowedRoot.path, forKey: PathAllowList.defaultParentKey)

        // Build a path with 300 nonexistent trailing components — exceeds
        // both the explicit 256-component validate() pre-check and the
        // symlink resolver's hop cap. The string still prefix-matches
        // the allowed root via the symlink, so the OLD code would have
        // accepted it. The new code must reject.
        let deep = (0..<300).map { _ in "a" }.joined(separator: "/")
        let target = symlink.appendingPathComponent(deep).path
        let result = PathAllowList.validate(target, userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed):
            break // expected
        default:
            XCTFail("Pathologically deep submission must reject; got \(result)")
        }
    }

    // MARK: - P0b: real-home expansion (sandbox-aware)

    /// In sandboxed Release builds, `NSHomeDirectory()` returns the
    /// container, not `/Users/<user>/`. The deny-list must expand `~`
    /// against the *real* user home (via `ClawdmeterRealHome`) so that
    /// `~/.ssh` always means the user's real keys.
    func test_resolveDeniedSubpaths_expandsAgainstRealHome() {
        let denied = PathAllowList.resolveDeniedSubpaths()
        let realHome = ClawdmeterRealHome.path()
        let expectedSSH = (realHome as NSString).appendingPathComponent(".ssh")
        XCTAssertTrue(
            denied.contains(where: { $0 == expectedSSH || $0.hasPrefix(expectedSSH) }),
            "Deny-list must include real-home ~/.ssh; got \(denied)"
        )
    }

    // MARK: - existing collision check

    func test_validate_doesNotAcceptPrefixCollision() {
        // /foo/barz must NOT match /foo/bar (the prefix-with-/ check).
        defaults.set("/foo/bar", forKey: PathAllowList.defaultParentKey)
        let result = PathAllowList.validate("/foo/barz", userDefaults: defaults)
        switch result {
        case .failure(.pathNotAllowed):
            break
        default:
            XCTFail("Prefix collision should reject; got \(result)")
        }
    }
}
