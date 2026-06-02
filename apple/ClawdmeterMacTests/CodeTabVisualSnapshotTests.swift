import XCTest
import SwiftUI
import AppKit
import ClawdmeterShared
@testable import Clawdmeter

/// Visual analyzer for the Code-tab revamp. Renders the real motion/polish
/// surfaces to PNGs (headless, via `ImageRenderer`) so the rendered design can
/// be eyeballed and diffed without launching the app — the verification path
/// the live runbook can't automate.
///
/// These are still-frame captures: they verify layout, colors, the selected-pill
/// position, disabled styling, button chrome, and skeleton shape — i.e. the
/// things a visual regression would break. They do NOT capture motion *timing*
/// (slide/pulse/cross-fade duration); that remains the on-device runbook.
///
/// Snapshots land in `/tmp/clawdmeter-visual/`. The test also asserts each PNG
/// rendered to a non-trivial size (a blank/failed render is caught in CI).
@MainActor
final class CodeTabVisualSnapshotTests: XCTestCase {

    private static let outDir = URL(fileURLWithPath: "/tmp/clawdmeter-visual")

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    /// Render `view` on a dark workbench-like panel and write `<name>.png`.
    @discardableResult
    private func snapshot<V: View>(_ name: String, width: CGFloat? = nil, _ view: V) -> CGSize {
        let panel = view
            .padding(14)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .environment(\.colorScheme, .dark)
            // Inject the SAME theme the app injects so `t.accent` resolves to the
            // user's chosen Tahoe accent (Halo blue by default) — now that the
            // mode/effort chips follow it, the snapshot proves chips + buttons
            // share one accent.
            .tahoeTheme(TahoeThemeStore.loaded())
        let content: AnyView = width.map { AnyView(panel.frame(width: $0)) } ?? AnyView(panel)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to render \(name)")
            return .zero
        }
        let url = Self.outDir.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        XCTAssertGreaterThan(png.count, 300, "\(name): PNG suspiciously small — likely a blank render")
        XCTAssertGreaterThan(image.size.width, 0)
        print("VISUAL \(name) -> \(url.path) [\(png.count) bytes, \(Int(image.size.width))x\(Int(image.size.height))]")
        return image.size
    }

    // MARK: - P3 segmented chips (sliding pill)

    func test_modePicker_local()    { snapshot("mode_picker_local",    ModePicker(mode: .local,    agent: .claude, onChange: { _ in })) }
    func test_modePicker_worktree() { snapshot("mode_picker_worktree", ModePicker(mode: .worktree, agent: .claude, onChange: { _ in })) }

    func test_effortDial_high()        { snapshot("effort_dial_high",        EffortDial(selected: .high,   supportsEffort: true,  onChange: { _ in })) }
    func test_effortDial_low()         { snapshot("effort_dial_low",         EffortDial(selected: .low,    supportsEffort: true,  onChange: { _ in })) }
    func test_effortDial_unsupported() { snapshot("effort_dial_unsupported", EffortDial(selected: .medium, supportsEffort: false, onChange: { _ in })) }

    // MARK: - P4 loading skeleton

    func test_skeletonLines() {
        snapshot("skeleton_lines", width: 360, SkeletonLines(count: 5, label: "Loading diff…"))
    }

    // MARK: - P2 primary / ghost buttons (rest state)

    func test_tahoeButtons() {
        snapshot("tahoe_buttons", HStack(spacing: 10) {
            TahoeGhostButton(action: {}) { Text("Refine plan") }
            TahoeAccentButton(action: {}) { Text("Approve plan") }
        })
    }

    // MARK: - Representative header chip cluster (mode + effort together)

    func test_headerChipStrip() {
        snapshot("header_chip_strip", HStack(spacing: 10) {
            ModePicker(mode: .worktree, agent: .claude, onChange: { _ in })
            EffortDial(selected: .high, supportsEffort: true, onChange: { _ in })
        })
    }

    /// One sheet contact-sheet assertion so a `--only-testing` run of this file
    /// leaves an obvious pass/fail + a directory the analyst can open.
    func test_zzz_allSnapshotsLanded() {
        let expected = [
            "mode_picker_local", "mode_picker_worktree",
            "effort_dial_high", "effort_dial_low", "effort_dial_unsupported",
            "skeleton_lines", "tahoe_buttons", "header_chip_strip",
        ]
        // Re-render synchronously so this test is order-independent.
        test_modePicker_local(); test_modePicker_worktree()
        test_effortDial_high(); test_effortDial_low(); test_effortDial_unsupported()
        test_skeletonLines(); test_tahoeButtons(); test_headerChipStrip()
        for name in expected {
            let url = Self.outDir.appendingPathComponent("\(name).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing snapshot \(name)")
        }
        print("VISUAL: \(expected.count) snapshots in \(Self.outDir.path)")
    }
}
