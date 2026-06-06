#if (os(iOS) || os(watchOS)) && canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

private final class WeakWatchSessionDelegate {
    weak var value: (any WCSessionDelegate & AnyObject)?

    init(_ value: any WCSessionDelegate & AnyObject) {
        self.value = value
    }
}

private final class WatchReplyGate {
    private let lock = NSLock()
    private var didReply = false
    private let replyHandler: ([String: Any]) -> Void

    init(_ replyHandler: @escaping ([String: Any]) -> Void) {
        self.replyHandler = replyHandler
    }

    func reply(_ payload: [String: Any]) {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return
        }
        didReply = true
        lock.unlock()
        replyHandler(payload)
    }
}

public final class WatchSessionDelegateMultiplexer: NSObject, WCSessionDelegate {
    public static let shared = WatchSessionDelegateMultiplexer()

    private let lock = NSLock()
    private var delegates: [WeakWatchSessionDelegate] = []

    public func register(_ delegate: any WCSessionDelegate & AnyObject) {
        guard WCSession.isSupported() else { return }
        lock.lock()
        delegates = delegates.filter { $0.value != nil }
        let alreadyRegistered = delegates.contains { box in
            guard let value = box.value else { return false }
            return ObjectIdentifier(value) == ObjectIdentifier(delegate)
        }
        if !alreadyRegistered {
            delegates.append(WeakWatchSessionDelegate(delegate))
        }
        lock.unlock()

        let session = WCSession.default
        let existingDelegate: (any WCSessionDelegate & AnyObject)? = session.delegate
        if let existing = existingDelegate,
           ObjectIdentifier(existing) != ObjectIdentifier(self) {
            lock.lock()
            let hasExisting = delegates.contains { box in
                guard let value = box.value else { return false }
                return ObjectIdentifier(value) == ObjectIdentifier(existing)
            }
            if !hasExisting {
                delegates.append(WeakWatchSessionDelegate(existing))
            }
            lock.unlock()
        }
        session.delegate = self
        session.activate()
    }

    private func currentDelegates() -> [any WCSessionDelegate & AnyObject] {
        lock.lock()
        delegates = delegates.filter { $0.value != nil }
        let values = delegates.compactMap(\.value)
        lock.unlock()
        return values
    }

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        for delegate in currentDelegates() {
            delegate.session(session, activationDidCompleteWith: state, error: error)
        }
    }

#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        for delegate in currentDelegates() {
            delegate.sessionDidBecomeInactive(session)
        }
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        for delegate in currentDelegates() {
            delegate.sessionDidDeactivate(session)
        }
    }
#endif

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        for delegate in currentDelegates() {
            delegate.session?(session, didReceiveApplicationContext: applicationContext)
        }
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        for delegate in currentDelegates() {
            delegate.session?(session, didReceiveUserInfo: userInfo)
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        for delegate in currentDelegates() {
            delegate.session?(session, didReceiveMessage: message)
        }
    }

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let gate = WatchReplyGate(replyHandler)
        for delegate in currentDelegates() {
            delegate.session?(session, didReceiveMessage: message, replyHandler: gate.reply)
        }
    }
}
#endif
