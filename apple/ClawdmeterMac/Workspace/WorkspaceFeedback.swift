import Foundation
import ClawdmeterShared

/// One place to surface the outcome of a Code-tab action.
///
/// The audit found the workbench's core "wiring feels broken" complaint was
/// really *silent feedback*: actions like interrupt, mode/model/effort swap, and
/// approve-plan called the daemon with `try?` / `_ = await` and discarded the
/// result, so a working control looked identical whether it succeeded or failed.
/// Every such site now routes a one-line outcome through here.
///
/// Posts the shared `TransientToast` via the existing
/// `.clawdmeterShowTransientToast` host in `MacRootView` — so auto-dismiss, the
/// countdown ring, and VoiceOver come for free. Safe to call from any actor;
/// the host observes on the main queue.
enum WorkspaceFeedback {
    /// A discrete action landed (plan approved, mode switched, merged).
    static func success(_ title: String, detail: String? = nil) {
        post(TransientToast(title: title, detail: detail, duration: 3, severity: .success))
    }

    /// An action failed — never let this be silent. Lives a little longer than
    /// a success so the user can read why.
    static func failure(_ title: String, detail: String? = nil) {
        post(TransientToast(title: title, detail: detail, duration: 6, severity: .failure))
    }

    /// Neutral acknowledgment.
    static func info(_ title: String, detail: String? = nil) {
        post(TransientToast(title: title, detail: detail, duration: 3, severity: .info))
    }

    static func post(_ toast: TransientToast) {
        NotificationCenter.default.post(
            name: .clawdmeterShowTransientToast,
            object: nil,
            userInfo: ["toast": toast]
        )
    }
}
