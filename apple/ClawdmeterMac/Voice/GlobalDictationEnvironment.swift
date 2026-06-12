import SwiftUI

private struct GlobalDictationCoordinatorKey: EnvironmentKey {
    static let defaultValue: GlobalDictationCoordinator? = nil
}

extension EnvironmentValues {
    var globalDictationCoordinator: GlobalDictationCoordinator? {
        get { self[GlobalDictationCoordinatorKey.self] }
        set { self[GlobalDictationCoordinatorKey.self] = newValue }
    }
}
