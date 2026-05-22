import XCTest
@testable import ClawdmeterLinux

final class LinuxUIWidgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Audit P1 fix: `LinuxUI.adapter` is now get-only (locked behind
        // the setter ban that lets the production adapter be installed
        // exactly once). Use the explicit `configure(adapter:)` entry
        // the production code uses too — tests can re-install the stub
        // freely since it's idempotent.
        LinuxUI.configure(adapter: StubAdapter())
    }

    // MARK: - Each primitive constructs without crashing

    func testWindow() {
        let w = LinuxUI.window(title: "Test")
        XCTAssertEqual(w.title, "Test")
        XCTAssertEqual(w.size.width, 980)
    }

    func testTextStyles() {
        for style: LinuxTextStyle in [.body, .caption, .headline, .title, .monospace] {
            let t = LinuxUI.text("hello", style: style)
            XCTAssertEqual(t.text, "hello")
            XCTAssertEqual(t.style, style)
        }
    }

    func testButtonOnClick() {
        nonisolated(unsafe) var fired = false
        let b = LinuxUI.button("Open", style: .suggested) {
            fired = true
        }
        XCTAssertEqual(b.label, "Open")
        XCTAssertTrue(b.isEnabled)
        b.onClick?()
        XCTAssertTrue(fired)
    }

    func testTextField() {
        let tf = LinuxUI.textField(placeholder: "Search…", isMultiline: false)
        XCTAssertEqual(tf.placeholder, "Search…")
        XCTAssertFalse(tf.isMultiline)
    }

    func testImageSources() {
        let icon = LinuxUI.image(.iconName("clawdmeter"))
        let file = LinuxUI.image(.fileURL(URL(fileURLWithPath: "/tmp/x.png")))
        let bytes = LinuxUI.image(.bytes(Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertNotNil(icon); XCTAssertNotNil(file); XCTAssertNotNil(bytes)
    }

    func testBoxComposes() {
        let label = LinuxUI.text("Hello")
        let button = LinuxUI.button("OK")
        let row = LinuxUI.box(.horizontal, spacing: 8, children: [label, button])
        XCTAssertEqual(row.orientation, .horizontal)
        XCTAssertEqual(row.spacing, 8)
        XCTAssertEqual(row.children.count, 2)
    }

    func testListRowBuilder() {
        nonisolated(unsafe) var selected = -1
        let list = LinuxUI.list(itemCount: 3, rowBuilder: { i in
            return LinuxUI.text("row-\(i)")
        }, onSelect: { i in
            selected = i
        })
        XCTAssertEqual(list.itemCount, 3)
        list.onSelect?(2)
        XCTAssertEqual(selected, 2)
    }

    func testDrawingAreaCallback() {
        nonisolated(unsafe) var callCount = 0
        let area = LinuxUI.drawingArea { width, height, _ in
            callCount += 1
            XCTAssertEqual(width, 32)
            XCTAssertEqual(height, 32)
        }
        // StubDrawingArea's draw closure is invokable for testing.
        area.draw?(32, 32, OpaquePointer(bitPattern: 0x1)!)
        XCTAssertEqual(callCount, 1)
    }

    func testAlertDialogActions() {
        nonisolated(unsafe) var primaryFired = false
        let dlg = LinuxUI.alertDialog(
            title: "Install extension?",
            message: "Clawdmeter needs the AppIndicator extension.",
            actions: [
                ("Open in Browser", true, { primaryFired = true }),
                ("Continue without menu bar", false, {})
            ]
        )
        XCTAssertEqual(dlg.actions.count, 2)
        XCTAssertEqual(dlg.actions[0].label, "Open in Browser")
        XCTAssertTrue(dlg.actions[0].isPrimary)
        dlg.actions[0].handler()
        XCTAssertTrue(primaryFired)
    }
}
