#if canImport(SwiftUI)
import SwiftUI

/// Cross-platform permission-prompt card lifted from the Mac-only
/// `ChatSoloView.swift:228` per the eng-review T11 + Codex outside-
/// voice P1 #9. Renders a CLI-side permission prompt (Codex
/// "Trust this directory?", Claude per-tool approval, etc.) as a
/// floating panel with header chip + bold question + numbered option
/// rows; the user's selection is dispatched through the platform-
/// supplied `PermissionResponder` so the card doesn't directly depend
/// on Mac-only daemon plumbing.
///
/// Renders inline within the chat transcript (typically pinned to the
/// bottom with `.overlay(alignment: .bottom)`) — the V2 composer
/// disables itself while a prompt is pending so the user can't bury
/// it under more text.
///
/// Visual contract preserved from the v0.8 Mac card:
/// - Yellow rounded "header" chip top-left (provider hint:
///   "Codex trust", "Claude tool", etc.).
/// - Bold title + optional detail body.
/// - Numbered option rows (1-9 keyboard shortcuts).
/// - Recommended option pre-marked, destructive options in red.
/// - No close/skip — permission prompts MUST be answered.
@available(macOS 14, iOS 17, *)
public struct PermissionPromptCard: View {
    public let prompt: PendingPermissionPrompt
    public let sessionId: UUID
    public let responder: PermissionResponder

    @State private var isResponding: Bool = false
    @State private var errorMessage: String?
    @State private var hoveredOptionId: String?

    public init(prompt: PendingPermissionPrompt, sessionId: UUID, responder: PermissionResponder) {
        self.prompt = prompt
        self.sessionId = sessionId
        self.responder = responder
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let detail = prompt.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 1) {
                ForEach(Array(prompt.options.enumerated()), id: \.element.id) { idx, option in
                    optionRow(option: option, index: idx + 1)
                }
            }
            .padding(.bottom, 10)
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: 720)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(strokeColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(prompt.header)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.yellow.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(.yellow.opacity(0.4), lineWidth: 0.5))
            Text(prompt.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if isResponding {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func optionRow(option: PermissionOption, index: Int) -> some View {
        let isHovered = hoveredOptionId == option.id
        let isRecommended = option.isRecommended
        Button(action: ContinuumAnalytics.wrapButton("permission_option_\(option.id)", { respond(optionId: option.id) })) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(option.isDestructive ? Color.red : Color.primary)
                        if isRecommended {
                            Text("recommended")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if index <= 9 {
                    Text("\(index)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(numberBackground, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4).strokeBorder(strokeColor, lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(rowBackground(isHovered: isHovered, isRecommended: isRecommended))
        }
        .buttonStyle(.plain)
        .disabled(isResponding)
#if os(macOS)
        .onHover { hovering in
            hoveredOptionId = hovering ? option.id : (hoveredOptionId == option.id ? nil : hoveredOptionId)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
#endif
    }

    private var cardFill: Color {
#if os(macOS)
        Color(white: 0.12)
#elseif os(watchOS)
        // watchOS doesn't expose UIKit's secondarySystemBackground.
        // Watch is always-dark, so a fixed dark gray matches the iOS
        // dark-mode rendering of secondarySystemBackground (~RGB 28,28,30).
        Color(white: 0.11)
#else
        Color(.secondarySystemBackground)
#endif
    }

    private var strokeColor: Color { Color.white.opacity(0.08) }
    private var numberBackground: Color { Color.white.opacity(0.06) }

    private func rowBackground(isHovered: Bool, isRecommended: Bool) -> Color {
        if isHovered { return Color.white.opacity(0.06) }
        if isRecommended { return Color.white.opacity(0.025) }
        return Color.clear
    }

    private func respond(optionId: String) {
        guard !isResponding else { return }
        isResponding = true
        errorMessage = nil
        let responder = self.responder
        let sessionId = self.sessionId
        let promptId = prompt.id
        Task {
            defer { Task { @MainActor in self.isResponding = false } }
            do {
                try await responder.respond(sessionId: sessionId, promptId: promptId, optionId: optionId)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }
}
#endif
