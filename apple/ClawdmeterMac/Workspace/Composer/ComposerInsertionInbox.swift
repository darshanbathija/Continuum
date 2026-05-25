import Combine
import Foundation

@MainActor
final class ComposerInsertionInbox: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let autoSend: Bool
    }

    static let shared = ComposerInsertionInbox()

    @Published private(set) var pendingRequest: Request?

    private init() {}

    func enqueue(text: String, autoSend: Bool) {
        pendingRequest = Request(text: text, autoSend: autoSend)
    }

    func consumePendingRequest(id: UUID) -> Request? {
        guard pendingRequest?.id == id else { return nil }
        defer { pendingRequest = nil }
        return pendingRequest
    }
}
