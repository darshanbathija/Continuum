import SwiftUI

/// First-run disclosure + explicit consent for sending the user's content to
/// third-party AI providers, required by App Store Review guidelines
/// 5.1.1(i) (Data Collection) and 5.1.2(i) (Data Use): the app must disclose
/// WHAT data is sent and to WHOM, and obtain permission BEFORE sending. The
/// gate is shown on first launch and must be accepted before any prompt/file
/// can leave the device. Acceptance is persisted under `defaultsKey`; bump
/// `version` to re-prompt everyone if the disclosure materially changes.
public enum AIDataSharingConsent {
    public static let version = 1
    public static let defaultsKey = "continuum.ai.dataSharingConsent.v\(version)"

    public static let privacyURL = URL(string: "https://darshanbathija.github.io/Continuum/privacy.html")!
    public static let termsURL = URL(string: "https://darshanbathija.github.io/Continuum/terms.html")!

    /// The AI providers user content may be transmitted to. Surfaced in the
    /// disclosure so the "to whom" requirement is met explicitly.
    public static let providers: [String] = [
        "Anthropic (Claude)", "OpenAI (Codex)", "Cursor",
        "xAI (Grok)", "Google (Gemini)", "OpenCode",
    ]

    public static var hasConsented: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

#if os(iOS)
/// The first-run consent screen. Caller presents it (e.g. as a non-dismissible
/// `fullScreenCover`) while `AIDataSharingConsent.hasConsented == false` and
/// flips its binding on agree. iOS-only: the App Store gate is an iPhone/iPad
/// requirement, and this avoids pulling iOS-shaped SwiftUI into the watchOS
/// build of the shared package.
@available(iOS 16.0, *)
public struct AIDataSharingConsentView: View {
    private let onAgree: () -> Void
    @Environment(\.openURL) private var openURL

    public init(onAgree: @escaping () -> Void) {
        self.onAgree = onAgree
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.top, 12)

                    Text("How Continuum uses AI providers")
                        .font(.system(size: 26, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Continuum is a console for AI coding agents. When you send a message or prompt, or attach or reference a file, that content is sent to the AI provider you choose to generate a response. The content is routed through your paired Mac to that provider.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your content may be sent to:")
                            .font(.subheadline.weight(.semibold))
                        ForEach(AIDataSharingConsent.providers, id: \.self) { provider in
                            Label(provider, systemImage: "arrow.up.forward.app")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("Each provider receives your content under the account you configured and handles it under its own terms and privacy policy. Continuum does not run a server that collects your prompts, code, or files, and does not sell your data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 16) {
                        Button("Privacy Policy", action: ContinuumAnalytics.wrapButton("consent_privacy_policy", { openURL(AIDataSharingConsent.privacyURL) }))
                        Button("Terms of Use", action: ContinuumAnalytics.wrapButton("consent_terms_of_use", { openURL(AIDataSharingConsent.termsURL) }))
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            VStack(spacing: 10) {
                Text("By tapping “I Agree”, you consent to sending your prompts and selected files to the AI provider(s) you use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: ContinuumAnalytics.wrapButton("consent_agree", {
                    AIDataSharingConsent.hasConsented = true
                    onAgree()
                })) {
                    Text("I Agree")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .background(.bar)
        }
        .interactiveDismissDisabled(true)
    }
}
#endif
