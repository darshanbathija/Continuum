import SwiftUI

/// Device picker for new-session flows (R1 1C). Works on Mac + iOS.
public struct ExecutionHostPickerSection: View {
    public let hosts: [ExecutionHost]
    public let localHostId: UUID?
    @Binding public var selectedHostId: UUID?
    public var title: String = "Run on"

    public init(
        hosts: [ExecutionHost],
        localHostId: UUID?,
        selectedHostId: Binding<UUID?>,
        title: String = "Run on"
    ) {
        self.hosts = hosts
        self.localHostId = localHostId
        self._selectedHostId = selectedHostId
        self.title = title
    }

    public var body: some View {
        if hosts.count > 1 {
            Picker(title, selection: Binding(
                get: { selectedHostId ?? localHostId ?? hosts.first?.id ?? UUID() },
                set: { newValue in
                    if newValue == localHostId {
                        selectedHostId = nil
                    } else {
                        selectedHostId = newValue
                    }
                }
            )) {
                ForEach(hosts) { host in
                    Text(hostPickerLabel(host)).tag(host.id)
                }
            }
        }
    }

    private func hostPickerLabel(_ host: ExecutionHost) -> String {
        let healthSuffix: String = {
            switch host.health {
            case .healthy: return ""
            case .degraded: return " · degraded"
            case .unreachable: return " · unreachable"
            case .unknown, .provisioning: return " · …"
            }
        }()
        if host.kind == .localMac { return host.displayName + healthSuffix }
        return host.displayName + healthSuffix
    }
}
