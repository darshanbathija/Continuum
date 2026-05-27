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
