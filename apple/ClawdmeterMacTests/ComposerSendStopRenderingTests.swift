import XCTest
import SwiftUI
import AppKit
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class ComposerSendStopRenderingTests: XCTestCase {

    private static let outDir = URL(fileURLWithPath: "/tmp/clawdmeter-composer")

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    func test_idleComposerPrimaryActionIsIconOnlySendWithoutStop() {
        let action = ComposerInputCore.primaryActionDescriptor(
            isReadOnly: false,
            sessionIsRunning: false,
            hasInterruptHandler: true,
            canSendNow: true
        )

        XCTAssertEqual(action.kind, .send)
        XCTAssertTrue(action.isEnabled)
        XCTAssertEqual(action.accessibilityLabel, "Send")
        XCTAssertEqual(action.accessibilityIdentifier, "code.composer.send")
        XCTAssertNil(action.visibleTitle)
        assertNoLegacyActionText(action)
    }

    func test_runningComposerPrimaryActionIsIconOnlyStopWithoutQueueOrSend() {
        let action = ComposerInputCore.primaryActionDescriptor(
            isReadOnly: false,
            sessionIsRunning: true,
            hasInterruptHandler: true,
            canSendNow: true
        )

        XCTAssertEqual(action.kind, .stop)
        XCTAssertTrue(action.isEnabled)
        XCTAssertEqual(action.accessibilityLabel, "Stop")
        XCTAssertEqual(action.accessibilityIdentifier, "code.composer.stop")
        XCTAssertNil(action.visibleTitle)
        assertNoLegacyActionText(action)
    }

    func test_renderedIdleAndRunningComposersAreNonBlankAndDistinct() {
        let idlePNG = renderComposerPNG("composer_idle_send", sessionIsRunning: false)
        let runningPNG = renderComposerPNG("composer_running_stop", sessionIsRunning: true)

        XCTAssertGreaterThan(idlePNG.count, 2_000)
        XCTAssertGreaterThan(runningPNG.count, 2_000)
        XCTAssertNotEqual(idlePNG, runningPNG, "Send and Stop composer states should render differently.")
    }

    func test_primaryActionIsIconOnlyForEveryBundledCodeProviderModel() {
        let cases = bundledCodeProviderModelCases()
        XCTAssertFalse(cases.isEmpty)

        XCTContext.runActivity(named: "Bundled Code composer Send/Stop matrix") { activity in
            activity.add(XCTAttachment(string: cases.map { provider, entry in
                "\(provider.rawValue): \(entry.id)"
            }.joined(separator: "\n")))
        }

        for (provider, entry) in cases {
            let canSend = !entry.id.isEmpty
            let idle = ComposerInputCore.primaryActionDescriptor(
                isReadOnly: false,
                sessionIsRunning: false,
                hasInterruptHandler: true,
                canSendNow: canSend
            )
            assertIconOnlyPrimaryAction(
                idle,
                expectedKind: .send,
                expectedIdentifier: "code.composer.send",
                "\(provider.rawValue) \(entry.id)"
            )

            let running = ComposerInputCore.primaryActionDescriptor(
                isReadOnly: false,
                sessionIsRunning: true,
                hasInterruptHandler: true,
                canSendNow: canSend
            )
            assertIconOnlyPrimaryAction(
                running,
                expectedKind: .stop,
                expectedIdentifier: "code.composer.stop",
                "\(provider.rawValue) \(entry.id)"
            )
        }
    }

    func test_pendingMessageActionsExposeRetryDismissOnlyForFailedAndOfflineStates() {
        XCTAssertEqual(
            ComposerInputCore.pendingActionDescriptors(for: .sending),
            [],
            "Sending state should show spinner feedback only, without retry/dismiss controls."
        )

        XCTAssertEqual(
            ComposerInputCore.pendingActionDescriptors(for: .failed),
            [
                ComposerInputCore.PendingActionDescriptor(
                    kind: .retry,
                    visibleTitle: "Retry",
                    accessibilityIdentifier: "composer.pending.retry"
                ),
                ComposerInputCore.PendingActionDescriptor(
                    kind: .dismiss,
                    visibleTitle: nil,
                    accessibilityIdentifier: "composer.pending.dismiss"
                )
            ],
            "Failed sends must keep explicit Retry and Dismiss controls visible until the user acts."
        )

        XCTAssertEqual(
            ComposerInputCore.pendingActionDescriptors(for: .queuedOffline),
            [
                ComposerInputCore.PendingActionDescriptor(
                    kind: .retry,
                    visibleTitle: "Retry now",
                    accessibilityIdentifier: "composer.pending.retry"
                ),
                ComposerInputCore.PendingActionDescriptor(
                    kind: .dismiss,
                    visibleTitle: nil,
                    accessibilityIdentifier: "composer.pending.dismiss"
                )
            ],
            "Offline queued sends must expose the same stable retry/dismiss targets with offline-specific copy."
        )
    }

    func test_modelFailureActionsExposeRetryAndRetryInNewChat() {
        XCTAssertEqual(
            ComposerInputCore.modelFailureActionDescriptors(),
            [
                ComposerInputCore.ModelFailureActionDescriptor(
                    kind: .retry,
                    visibleTitle: "Retry",
                    accessibilityIdentifier: "transcript.modelFailure.retry"
                ),
                ComposerInputCore.ModelFailureActionDescriptor(
                    kind: .retryInNewChat,
                    visibleTitle: "Retry in new chat",
                    accessibilityIdentifier: "transcript.modelFailure.retryInNewChat"
                )
            ]
        )
    }

    func test_contextUsageRingUsesContextWindowOnly() {
        let info = usageInfo(
            contextUsedTokens: 500_000,
            contextLimitTokens: 1_000_000,
            sessionPct: 99,
            weeklyPct: 97
        )

        let ring = ContextUsageChip.ringDescriptor(for: info)

        XCTAssertEqual(ring.percentText, "50%")
        XCTAssertEqual(ring.fraction, 0.5, accuracy: 0.0001)

        let unknownLimit = ContextUsageChip.ringDescriptor(for: usageInfo(
            contextUsedTokens: 500_000,
            contextLimitTokens: nil,
            sessionPct: 99,
            weeklyPct: 97
        ))
        XCTAssertEqual(unknownLimit.percentText, "0%")
        XCTAssertEqual(unknownLimit.fraction, 0)
    }

    func test_contextUsagePopoverRowsUseSuppliedCodePayloadAndCursorQuota() {
        let cursorQuota = UsageData.CursorQuota(
            totalPct: 63,
            autoPct: 37,
            apiPct: 100,
            resetMins: 3 * 24 * 60,
            resetEpoch: 1_782_259_911,
            includedUsageLabel: "$400 included / period",
            extraUsageLabel: "Free extra usage may vary."
        )
        let rows = ContextUsagePopover.rowDescriptors(for: usageInfo(
            contextUsedTokens: 336_200,
            contextLimitTokens: 1_000_000,
            contextBreakdown: sampleBreakdown(used: 336_200, limit: 1_000_000),
            sessionPct: 12,
            sessionResetMins: 40,
            weeklyPct: 72,
            weeklyResetMins: 120,
            cursorQuota: cursorQuota
        ))

        XCTAssertEqual(rows.map(\.id), [
            "code.context-usage.section.context",
            "code.context-usage.row.free-space",
            "code.context-usage.row.mcp-tools",
            "code.context-usage.row.messages",
            "code.context-usage.row.memory-files",
            "code.context-usage.row.system-tools",
            "code.context-usage.row.skills",
            "code.context-usage.row.system-prompt",
            "code.context-usage.row.plan-header",
            "code.context-usage.row.cursor-included",
            "code.context-usage.row.cursor-extra",
            "code.context-usage.row.cursor-auto",
            "code.context-usage.row.cursor-api",
            "code.context-usage.row.weekly",
        ])
        XCTAssertFalse(rows.contains { $0.id == "code.context-usage.row.session" })
        XCTAssertFalse(rows.contains { $0.id == "code.context-usage.row.cost" })
        XCTAssertEqual(rows.first { $0.id == "code.context-usage.section.context" }?.value, "336.2k / 1.0M")
        XCTAssertEqual(rows.first { $0.id == "code.context-usage.row.cursor-auto" }?.value, "37% · resets 3d")
        XCTAssertEqual(rows.first { $0.id == "code.context-usage.row.cursor-api" }?.kind, .progress(tint: .danger))
        XCTAssertEqual(rows.first { $0.id == "code.context-usage.row.weekly" }?.value, "72% · resets 2h")
        XCTAssertEqual(rows.first { $0.id == "code.context-usage.row.messages" }?.value, "12.7%")

        let genericRows = ContextUsagePopover.rowDescriptors(for: usageInfo(
            contextUsedTokens: 1_000,
            contextLimitTokens: 2_000,
            sessionPct: 56,
            sessionResetMins: 300,
            weeklyPct: 83,
            weeklyResetMins: 2_880,
            cursorQuota: nil
        ))
        XCTAssertNotNil(genericRows.first { $0.id == "code.context-usage.row.session" })
        XCTAssertEqual(genericRows.first { $0.id == "code.context-usage.row.session" }?.value, "56% · resets 5h")
        XCTAssertEqual(genericRows.first { $0.id == "code.context-usage.row.weekly" }?.value, "83% · resets 2d")
    }

    func test_renderedComposerSendStopMatrixCoversEveryBundledCodeProviderModel() {
        let cases = bundledCodeProviderModelCases()
        let ids = Set(cases.map { "\($0.provider.rawValue):\($0.entry.id)" })
        XCTAssertEqual(ids.count, cases.count, "Bundled provider/model entries should be unique in the rendered composer matrix.")

        for (provider, entry) in cases {
            let idlePNG = renderComposerPNG(
                "matrix_\(safeFileName(provider.rawValue))_\(safeFileName(entry.id))_send",
                provider: provider,
                entry: entry,
                sessionIsRunning: false,
                writeToDisk: false
            )
            let runningPNG = renderComposerPNG(
                "matrix_\(safeFileName(provider.rawValue))_\(safeFileName(entry.id))_stop",
                provider: provider,
                entry: entry,
                sessionIsRunning: true,
                writeToDisk: false
            )

            XCTAssertGreaterThan(idlePNG.count, 2_000, "\(provider.rawValue) \(entry.id) Send composer rendered blank")
            XCTAssertGreaterThan(runningPNG.count, 2_000, "\(provider.rawValue) \(entry.id) Stop composer rendered blank")
            XCTAssertNotEqual(idlePNG, runningPNG, "\(provider.rawValue) \(entry.id) Send/Stop states should render differently")
        }
    }

    private func assertNoLegacyActionText(_ action: ComposerInputCore.PrimaryActionDescriptor) {
        let renderedText = [
            action.accessibilityLabel,
            action.accessibilityIdentifier,
            action.visibleTitle,
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        XCTAssertFalse(renderedText.localizedCaseInsensitiveContains("tap to stop"))
        XCTAssertFalse(renderedText.localizedCaseInsensitiveContains("$0.000"))
        XCTAssertFalse(renderedText.localizedCaseInsensitiveContains("live"))
    }

    private func assertIconOnlyPrimaryAction(
        _ action: ComposerInputCore.PrimaryActionDescriptor,
        expectedKind: ComposerInputCore.PrimaryActionDescriptor.Kind,
        expectedIdentifier: String,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(action.kind, expectedKind, context, file: file, line: line)
        XCTAssertTrue(action.isEnabled, context, file: file, line: line)
        XCTAssertEqual(action.accessibilityIdentifier, expectedIdentifier, context, file: file, line: line)
        XCTAssertNil(action.visibleTitle, context, file: file, line: line)
        assertNoLegacyActionText(action)
    }

    private func bundledCodeProviderModelCases() -> [(provider: AgentKind, entry: ModelCatalogEntry)] {
        AgentKind.allCases.flatMap { provider in
            ModelCatalog.bundled.entries(for: provider).map { entry in
                (provider: provider, entry: entry)
            }
        }
    }

    private func usageInfo(
        contextUsedTokens: Int = 0,
        contextLimitTokens: Int? = nil,
        contextBreakdown: ContextWindowBreakdown? = nil,
        sessionPct: Int? = nil,
        sessionResetMins: Int? = nil,
        weeklyPct: Int? = nil,
        weeklyResetMins: Int? = nil,
        cursorQuota: UsageData.CursorQuota? = nil
    ) -> UsageStatusInfo {
        UsageStatusInfo(
            modelDisplay: "Claude Sonnet 4.5",
            effortDisplay: "High",
            contextUsedTokens: contextUsedTokens,
            contextLimitTokens: contextLimitTokens,
            costDollar: Decimal(string: "0.0123") ?? 0,
            contextBreakdown: contextBreakdown,
            sessionPct: sessionPct,
            sessionResetMins: sessionResetMins,
            weeklyPct: weeklyPct,
            weeklyResetMins: weeklyResetMins,
            cursorQuota: cursorQuota
        )
    }

    private func sampleBreakdown(used: Int, limit: Int) -> ContextWindowBreakdown {
        ContextWindowBreakdown(
            usedTokens: used,
            limitTokens: limit,
            entries: [
                .init(id: .freeSpace, tokens: limit - used, limitTokens: limit),
                .init(id: .mcpTools, tokens: 222_000, limitTokens: limit),
                .init(id: .messages, tokens: 127_000, limitTokens: limit),
                .init(id: .memoryFiles, tokens: 31_000, limitTokens: limit),
                .init(id: .systemTools, tokens: 28_000, limitTokens: limit),
                .init(id: .skills, tokens: 6_000, limitTokens: limit),
                .init(id: .systemPrompt, tokens: 5_000, limitTokens: limit),
                .init(id: .customAgents, tokens: 0, limitTokens: limit),
            ]
        )
    }

    private func renderComposerPNG(
        _ name: String,
        provider: AgentKind = .claude,
        entry explicitEntry: ModelCatalogEntry? = nil,
        sessionIsRunning: Bool,
        writeToDisk: Bool = true
    ) -> Data {
        let entry = explicitEntry ?? ModelCatalog.bundled.entries(for: provider).first
        let store = ComposerStore(mode: .bound(sessionId: UUID()))
        store.text = "hello"
        store.agent = provider
        store.modelId = entry?.id
        store.effort = entry?.supportsEffort == true ? .high : nil

        let presentationStore = SessionPresentationStore(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ComposerSendStopRenderingTests-\(UUID().uuidString).json")
        )
        let view = ComposerInputCore(
            store: store,
            presentationStore: presentationStore,
            catalog: .bundled,
            agentForModelPicker: provider,
            modelSupportsEffort: entry?.supportsEffort == true,
            onSend: {},
            onQueue: {},
            onInterrupt: {},
            sessionIsRunning: sessionIsRunning
        )
        .frame(width: 760, height: 180)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .environment(\.colorScheme, .dark)
        .tahoeTheme(TahoeThemeStore.loaded())

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to render \(name)")
            return Data()
        }

        if writeToDisk {
            let url = Self.outDir.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("VISUAL \(name) -> \(url.path) [\(png.count) bytes]")
        }
        return png
    }

    private func safeFileName(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        .map(String.init)
        .joined()
    }
}
