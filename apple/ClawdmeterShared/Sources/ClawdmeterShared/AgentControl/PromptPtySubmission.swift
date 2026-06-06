import Foundation

/// Renders user prompts into ordered writes for an interactive raw PTY.
///
/// A raw PTY only accepts bytes, so long or multi-line prompts use bracketed
/// paste to keep embedded newlines literal, followed by a separate carriage
/// return to submit.
public enum PromptPtySubmission {
    public struct Writes: Equatable, Sendable {
        /// C-u (0x15) to clear the input line before a chat multi-turn paste;
        /// nil for code sessions / first turn.
        public let clear: Data?
        /// The prompt bytes, bracketed-paste-wrapped when needed.
        public let payload: Data
        /// The submit keystroke: CR (0x0d). Always present.
        public let submit: Data

        public init(clear: Data?, payload: Data, submit: Data) {
            self.clear = clear
            self.payload = payload
            self.submit = submit
        }
    }

    static let bracketedPasteStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    static let bracketedPasteEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    static let ctrlU = Data([0x15])
    static let carriageReturn = Data([0x0d])

    public static func needsBracketedPaste(forText text: String, isFollowUp: Bool) -> Bool {
        isFollowUp || Data(text.utf8).count > 256 || text.contains("\n")
    }

    public static func writes(forText text: String, isFollowUp: Bool, isChat: Bool) -> Writes {
        let raw = Data(text.utf8)
        let payload: Data
        if needsBracketedPaste(forText: text, isFollowUp: isFollowUp) {
            payload = bracketedPasteStart + raw + bracketedPasteEnd
        } else {
            payload = raw
        }
        return Writes(
            clear: isChat ? ctrlU : nil,
            payload: payload,
            submit: carriageReturn
        )
    }
}
