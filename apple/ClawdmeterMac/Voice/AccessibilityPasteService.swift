import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum AccessibilityPasteError: Error, LocalizedError, Equatable {
    case notAuthorized
    case noFocusedElement
    case pasteFailed

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Accessibility permission is required to paste dictated text."
        case .noFocusedElement:
            return "No focused text field was found."
        case .pasteFailed:
            return "Could not paste into the focused field."
        }
    }
}

/// Inserts dictated text into the frontmost app's focused field.
public struct AccessibilityPasteService {
    public init() {}

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func requestTrust(prompt: Bool = true) -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func paste(_ text: String) -> Result<Void, AccessibilityPasteError> {
        guard isTrusted else { return .failure(.notAuthorized) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .success(()) }

        if insertViaAccessibility(text) {
            return .success(())
        }
        if simulateCommandV(text) {
            return .success(())
        }
        copyToPasteboard(text)
        return .failure(.pasteFailed)
    }

    @discardableResult
    public func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }

        let element = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)

        if setSelectedText(text, on: element) {
            return true
        }
        return appendToValue(text, on: element)
    }

    private func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return status == .success
    }

    private func appendToValue(_ text: String, on element: AXUIElement) -> Bool {
        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue) == .success,
              let current = currentValue as? String
        else { return false }
        let combined = current + text
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, combined as CFTypeRef)
        return status == .success
    }

    private func simulateCommandV(_ text: String) -> Bool {
        copyToPasteboard(text)
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return true
    }
}
