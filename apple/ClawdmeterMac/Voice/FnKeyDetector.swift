import CoreGraphics

/// Detects the Fn / Globe modifier across Apple Silicon and external keyboards.
enum FnKeyDetector {
    /// `NX_DEVICEFNMASK` on some Apple Silicon layouts (Globe key).
    private static let deviceFnMask: UInt64 = 0x0000_0000_0010_0000

    static func isPressed(in flags: CGEventFlags) -> Bool {
        if flags.contains(.maskSecondaryFn) { return true }
        return flags.rawValue & deviceFnMask != 0
    }

    /// Synthetic Fn/Globe key codes macOS emits alongside modifier events.
    static func isFnKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 63 || keyCode == 179
    }
}
