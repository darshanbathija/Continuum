import XCTest
@testable import ClawdmeterShared

final class UIPrimitivesTests: XCTestCase {
    func testChimeSettingsDefaultPackIsAudible() {
        XCTAssertEqual(ChimeSettings().pack, .bell)
    }

    func testCommandRegistryFiltersByTitleSubtitleAndKeywords() {
        let registry = ClawdmeterCommandRegistry(commands: [
            .init(id: "nav.code", title: "Open Code", subtitle: "Sessions", keywords: ["workbench"], scope: .global, kind: .navigation),
            .init(id: "settings.pair", title: "Pair iPhone", subtitle: "Desktop sync", keywords: ["qr"], scope: .settings, kind: .setting),
        ])

        XCTAssertEqual(registry.filtered(query: "workbench").map(\.id.rawValue), ["nav.code"])
        XCTAssertEqual(registry.filtered(query: "sync").map(\.id.rawValue), ["settings.pair"])
        XCTAssertEqual(registry.filtered(query: "pair", scopes: [.global]).map(\.id.rawValue), [])
        XCTAssertEqual(registry.filtered(query: "pair", scopes: [.settings]).map(\.id.rawValue), ["settings.pair"])
    }

    func testShortcutDisplayChordAndGrouping() {
        let registry = ClawdmeterShortcutRegistry(shortcuts: [
            .init(id: "a", label: "Archive", key: "A", modifiers: [.command, .shift], scope: .session),
            .init(id: "b", label: "Find", key: "F", modifiers: [.command], scope: .chat),
        ])

        XCTAssertEqual(registry.shortcuts[0].displayChord, "⌘⇧A")
        XCTAssertEqual(registry.grouped(query: "find")[.chat]?.map(\.id), ["b"])
        XCTAssertNil(registry.grouped(query: "find")[.session])
    }

    func testDefaultShortcutsHaveUniqueIdsAndChords() {
        let defaults = ClawdmeterShortcutRegistry.defaults
        XCTAssertEqual(Set(defaults.map(\.id)).count, defaults.count)

        let chords = defaults.map { "\($0.modifiers.map(\.rawValue).joined(separator: "+")):\($0.key)" }
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    func testCodeHoverShortcutDefaultsAreRegistered() {
        let defaults = Dictionary(uniqueKeysWithValues: ClawdmeterShortcutRegistry.defaults.map { ($0.id, $0) })

        XCTAssertEqual(defaults["code.newChatTab"]?.displayChord, "⌘T")
        XCTAssertEqual(defaults["code.newChatTab"]?.commandID?.rawValue, "code.newChatTab")
        XCTAssertEqual(defaults["code.newTerminalTab"]?.displayChord, "⌘⇧T")
        XCTAssertEqual(defaults["session.new"]?.displayChord, "⌘N")
        XCTAssertEqual(defaults["composer.attach"]?.displayChord, "⌘U")
        XCTAssertEqual(defaults["session.rename"]?.displayChord, "⌘⇧R")
        XCTAssertEqual(defaults["session.archive"]?.displayChord, "⌘⇧A")
        XCTAssertEqual(defaults["composer.modelEffort"]?.displayChord, "⌘⌥M")
        XCTAssertEqual(defaults["composer.context"]?.displayChord, "⌘⌥C")
        XCTAssertEqual(defaults["composer.effortNext"]?.displayChord, "⌘⌥E")
        XCTAssertEqual(defaults["composer.effortPrevious"]?.displayChord, "⌘⌥⇧E")
    }

    func testSessionPresentationStorePersistsPinsUnreadAndRecents() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("presentation.json")
        let id = UUID()

        let store = SessionPresentationStore(storeURL: url)
        try store.togglePin(id)
        try store.markUnread(id, unread: true)
        try store.recordCommand("global.palette", limit: 3)
        try store.recordCommand("nav.code", limit: 3)
        try store.recordCommand("global.palette", limit: 3)
        try store.recordPrompt("  fix the tests  ", limit: 3)

        let reloaded = SessionPresentationStore(storeURL: url)
        XCTAssertEqual(reloaded.snapshot.pinnedSessionIds, [id])
        XCTAssertTrue(reloaded.snapshot.unreadSessionIds.contains(id))
        XCTAssertEqual(reloaded.snapshot.commandRecents, ["global.palette", "nav.code"])
        XCTAssertEqual(reloaded.snapshot.promptHistory, ["fix the tests"])
    }

    func testSessionPresentationStorePersistsRemainingClientLocalState() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("presentation.json")
        let id = UUID()
        let snoozeDate = Date(timeIntervalSince1970: 1_700_000_000)

        let store = SessionPresentationStore(storeURL: url)
        try store.setTitleOverride(id, title: "Build polish")
        try store.snooze(id, until: snoozeDate)
        try store.setMuted(id, muted: true)
        try store.setColorTag(id, tag: "green")
        try store.toggleMessageBookmark(sessionId: id, messageId: "m1")
        try store.recordViewedFile(sessionId: id, path: "Sources/App.swift", contentHash: "abc")
        try store.recordPathAction("Sources/App.swift")
        try store.savePrompt(title: "Fix tests", body: "swift test")
        try store.setExternalEditorIdentifier("finder")
        try store.setLastDictationTab(.chat)
        try store.setShortcutOverride(id: "global.filePicker", chord: "⌘P")
        try store.cacheRepoIdentity(RepoIdentityResolver.badge(repoKey: "/repo/clawdmeter", displayName: "Clawdmeter", remoteURL: "git@github.com:openai/clawdmeter.git"))
        try store.setSyntaxTheme(.graphite)
        try store.setDiffDisplayMode(.split)
        try store.setDiffHunkCollapsed(sessionId: id, hunkId: "Sources/App.swift:12", collapsed: true)
        try store.setFileReviewDisposition(sessionId: id, path: "Sources/App.swift", disposition: .approved)
        try store.recordExportedSessionURL("/tmp/session-export")
        try store.setNotificationPreferences(.init(
            dndEnabled: true,
            batchBanners: false,
            playChimes: false,
            sensitivePreviews: true,
            mutedEventIDs: ["usage"]
        ))

        let reloaded = SessionPresentationStore(storeURL: url)
        XCTAssertEqual(reloaded.snapshot.titleOverrides[id], "Build polish")
        XCTAssertEqual(reloaded.snapshot.snoozedUntil[id], snoozeDate)
        XCTAssertTrue(reloaded.snapshot.mutedSessionIds.contains(id))
        XCTAssertEqual(reloaded.snapshot.colorTags[id], "green")
        XCTAssertEqual(reloaded.snapshot.messageBookmarks[id], ["m1"])
        XCTAssertEqual(reloaded.snapshot.viewedFiles[id]?.first?.path, "Sources/App.swift")
        XCTAssertEqual(reloaded.snapshot.recentPathActions, ["Sources/App.swift"])
        XCTAssertEqual(reloaded.snapshot.savedPrompts.first?.title, "Fix tests")
        XCTAssertEqual(reloaded.snapshot.externalEditorIdentifier, "finder")
        XCTAssertEqual(reloaded.snapshot.lastDictationTab, .chat)
        XCTAssertEqual(reloaded.snapshot.shortcutOverrides["global.filePicker"], "⌘P")
        XCTAssertEqual(reloaded.snapshot.repoIdentityBadges["/repo/clawdmeter"]?.symbol, "GH")
        XCTAssertEqual(reloaded.snapshot.repoIdentityBadges["/repo/clawdmeter"]?.remoteSlug, "openai/clawdmeter")
        XCTAssertEqual(reloaded.snapshot.syntaxTheme, .graphite)
        XCTAssertEqual(reloaded.snapshot.diffDisplayMode, .split)
        XCTAssertEqual(reloaded.snapshot.collapsedDiffHunks[id], ["Sources/App.swift:12"])
        XCTAssertEqual(reloaded.snapshot.fileReviewDispositions[id]?["Sources/App.swift"], .approved)
        XCTAssertEqual(reloaded.snapshot.exportedSessionURLs, ["/tmp/session-export"])
        XCTAssertTrue(reloaded.snapshot.notificationPreferences.dndEnabled)
        XCTAssertFalse(reloaded.snapshot.notificationPreferences.batchBanners)
        XCTAssertFalse(reloaded.snapshot.notificationPreferences.playChimes)
        XCTAssertTrue(reloaded.snapshot.notificationPreferences.sensitivePreviews)
        XCTAssertEqual(reloaded.snapshot.notificationPreferences.mutedEventIDs, ["usage"])
    }

    func testSessionPresentationSnapshotDecodesLegacyPayloadDefaults() throws {
        let data = Data(#"{"commandRecents":["global.palette"],"promptHistory":["hello"]}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionPresentationSnapshot.self, from: data)

        XCTAssertEqual(decoded.commandRecents, ["global.palette"])
        XCTAssertEqual(decoded.promptHistory, ["hello"])
        XCTAssertEqual(decoded.savedPrompts, [])
        XCTAssertEqual(decoded.recentPathActions, [])
        XCTAssertNil(decoded.externalEditorIdentifier)
        XCTAssertEqual(decoded.repoIdentityBadges, [:])
        XCTAssertEqual(decoded.syntaxTheme, .tahoe)
        XCTAssertEqual(decoded.diffDisplayMode, .unified)
        XCTAssertEqual(decoded.collapsedDiffHunks, [:])
        XCTAssertEqual(decoded.fileReviewDispositions, [:])
        XCTAssertEqual(decoded.exportedSessionURLs, [])
        XCTAssertEqual(decoded.notificationPreferences, NotificationPresentationPreferences())
    }

    func testRepoIdentityResolverParsesRemoteAndGeneratesStableBadge() {
        let ssh = RepoIdentityResolver.badge(repoKey: "/tmp/Clawdmeter", displayName: "Clawdmeter", remoteURL: "git@github.com:owner/repo.git")
        let https = RepoIdentityResolver.badge(repoKey: "/tmp/Clawdmeter", displayName: "Clawdmeter", remoteURL: "https://github.com/owner/repo.git")

        XCTAssertEqual(ssh.symbol, "GH")
        XCTAssertEqual(ssh.remoteHost, "github.com")
        XCTAssertEqual(ssh.remoteSlug, "owner/repo")
        XCTAssertEqual(https.remoteSlug, "owner/repo")
        XCTAssertEqual(ssh.colorHex, https.colorHex)
    }

    func testTextUtilitiesStripAnsiHashAndPreview() {
        XCTAssertEqual(ClawdmeterTextUtilities.stripANSI("\u{001B}[31mred\u{001B}[0m plain"), "red plain")
        XCTAssertEqual(
            ClawdmeterTextUtilities.stripANSI("\u{001B}]0;terminal title\u{0007}\u{001B}[200~paste\u{001B}[201~"),
            "paste"
        )
        XCTAssertEqual(
            ClawdmeterTextUtilities.stripANSI("\u{001B}]8;;https://example.com\u{0007}label\u{001B}]8;;\u{0007}"),
            "label"
        )
        XCTAssertEqual(
            ClawdmeterTextUtilities.stableContentHash("same"),
            ClawdmeterTextUtilities.stableContentHash("same")
        )
        XCTAssertNotEqual(
            ClawdmeterTextUtilities.stableContentHash("same"),
            ClawdmeterTextUtilities.stableContentHash("different")
        )
        XCTAssertEqual(
            ClawdmeterTextUtilities.collapsedWhitespacePreview("  hello\n\nworld\tagain  ", limit: 80),
            "hello world again"
        )
        XCTAssertEqual(
            ClawdmeterTextUtilities.collapsedWhitespacePreview("123456789", limit: 6),
            "12345..."
        )
    }

    func testResolvablePathLinkRejectsOutsideRootAndParsesRanges() throws {
        let root = URL(fileURLWithPath: "/tmp/clawdmeter-root").standardizedFileURL

        let inside = ResolvablePathLinkParser.resolve(
            "Sources/App.swift",
            lineStart: 42,
            lineEnd: 58,
            column: 3,
            repoRoot: root
        )
        XCTAssertEqual(inside?.path, "Sources/App.swift")
        XCTAssertEqual(inside?.lineStart, 42)
        XCTAssertEqual(inside?.lineEnd, 58)
        XCTAssertEqual(inside?.column, 3)

        let outside = ResolvablePathLinkParser.resolve("../secret.swift", lineStart: 1, repoRoot: root)
        XCTAssertNil(outside)
    }

    func testResolvablePathLinkFindsMultipleInlineLinks() {
        let root = URL(fileURLWithPath: "/repo")
        let links = ResolvablePathLinkParser.links(
            in: "See apple/App.swift:12 and ./Tests/AppTests.swift:45-47.",
            repoRoot: root
        )

        XCTAssertEqual(links.map(\.path), ["apple/App.swift", "Tests/AppTests.swift"])
        XCTAssertEqual(links.map(\.lineStart), [12, 45])
        XCTAssertEqual(links[1].lineEnd, 47)
    }
}
