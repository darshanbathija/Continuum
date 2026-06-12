import Combine
import Foundation

@MainActor
final class ComposerInsertionInbox: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let autoSend: Bool
        let attachmentURL: URL?
        let attachmentDisplayName: String?

        init(
            text: String,
            autoSend: Bool,
            attachmentURL: URL? = nil,
            attachmentDisplayName: String? = nil
        ) {
            self.text = text
            self.autoSend = autoSend
            self.attachmentURL = attachmentURL
            self.attachmentDisplayName = attachmentDisplayName
        }
    }

    static let shared = ComposerInsertionInbox()

    @Published private(set) var pendingRequest: Request?

    private init() {}

    func enqueue(
        text: String,
        autoSend: Bool,
        attachmentURL: URL? = nil,
        attachmentDisplayName: String? = nil
    ) {
        pendingRequest = Request(
            text: text,
            autoSend: autoSend,
            attachmentURL: attachmentURL,
            attachmentDisplayName: attachmentDisplayName
        )
    }

    func consumePendingRequest(id: UUID) -> Request? {
        guard pendingRequest?.id == id else { return nil }
        defer { pendingRequest = nil }
        return pendingRequest
    }
}
