import Foundation

// MARK: - Vendor provisioning catalog (wire v24)

public enum VendorProvisioningCategory: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case storageDatabase
    case computeHosting
    case domains

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .storageDatabase: return "Storage and Databases"
        case .computeHosting: return "Compute and Hosting"
        case .domains: return "Domains"
        }
    }
}

public enum VendorProvisioningActionKind: String, Codable, Hashable, Sendable {
    case install
    case authenticate
    case signup
}

public struct VendorProvisioningAction: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: VendorProvisioningActionKind
    public let label: String
    public let command: String?
    public let url: URL?

    public init(
        id: String,
        kind: VendorProvisioningActionKind,
        label: String,
        command: String? = nil,
        url: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.command = command
        self.url = url
    }
}

public struct VendorEnvTemplate: Codable, Hashable, Identifiable, Sendable {
    public let key: String
    public let label: String
    public let kind: VendorEnvVariableKind
    public let isRequired: Bool

    public var id: String { key }

    public init(
        key: String,
        label: String,
        kind: VendorEnvVariableKind = .sensitive,
        isRequired: Bool = true
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
    }
}

public struct VendorProvisioningVendor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let category: VendorProvisioningCategory
    public let cliNames: [String]
    public let mcpAliases: [String]
    public let signupURL: URL?
    public let docsURL: URL?
    public let actions: [VendorProvisioningAction]
    public let envTemplates: [VendorEnvTemplate]

    public init(
        id: String,
        displayName: String,
        category: VendorProvisioningCategory,
        cliNames: [String],
        mcpAliases: [String],
        signupURL: URL? = nil,
        docsURL: URL? = nil,
        actions: [VendorProvisioningAction],
        envTemplates: [VendorEnvTemplate]
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.cliNames = cliNames
        self.mcpAliases = mcpAliases
        self.signupURL = signupURL
        self.docsURL = docsURL
        self.actions = actions
        self.envTemplates = envTemplates
    }

    public var envKeys: [String] {
        envTemplates.map(\.key)
    }
}

public enum VendorProvisioningCatalog {
    public static let vendors: [VendorProvisioningVendor] = [
        VendorProvisioningVendor(
            id: "mongodb-atlas",
            displayName: "MongoDB Atlas",
            category: .storageDatabase,
            cliNames: ["atlas"],
            mcpAliases: ["mongodb", "mongodb-atlas", "atlas"],
            signupURL: URL(string: "https://www.mongodb.com/cloud/atlas/register"),
            docsURL: URL(string: "https://www.mongodb.com/docs/atlas/cli/"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install mongodb-atlas"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "atlas auth login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://www.mongodb.com/cloud/atlas/register")),
            ],
            envTemplates: [
                .init(key: "MONGODB_URI", label: "MongoDB connection URI"),
            ]
        ),
        VendorProvisioningVendor(
            id: "upstash",
            displayName: "Upstash",
            category: .storageDatabase,
            cliNames: ["upstash"],
            mcpAliases: ["upstash", "redis"],
            signupURL: URL(string: "https://console.upstash.com/"),
            docsURL: URL(string: "https://upstash.com/docs/redis"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "npm i -g @upstash/cli"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "upstash login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://console.upstash.com/")),
            ],
            envTemplates: [
                .init(key: "UPSTASH_REDIS_REST_URL", label: "Redis REST URL"),
                .init(key: "UPSTASH_REDIS_REST_TOKEN", label: "Redis REST token"),
                .init(key: "UPSTASH_EMAIL", label: "Account email", kind: .plain, isRequired: false),
                .init(key: "UPSTASH_API_KEY", label: "Management API key", isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "supabase",
            displayName: "Supabase",
            category: .storageDatabase,
            cliNames: ["supabase"],
            mcpAliases: ["supabase", "postgres"],
            signupURL: URL(string: "https://supabase.com/dashboard/sign-up"),
            docsURL: URL(string: "https://supabase.com/docs/reference/cli"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install supabase/tap/supabase"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "supabase login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://supabase.com/dashboard/sign-up")),
            ],
            envTemplates: [
                .init(key: "SUPABASE_URL", label: "Project URL", kind: .plain),
                .init(key: "SUPABASE_ANON_KEY", label: "Anon key"),
                .init(key: "SUPABASE_SERVICE_ROLE_KEY", label: "Service role key", isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "fly",
            displayName: "Fly.io",
            category: .computeHosting,
            cliNames: ["fly", "flyctl"],
            mcpAliases: ["fly", "flyio", "fly.io"],
            signupURL: URL(string: "https://fly.io/user/personal_access_tokens"),
            docsURL: URL(string: "https://fly.io/docs/flyctl/"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install flyctl"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "fly auth login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://fly.io/app/sign-up")),
            ],
            envTemplates: [
                .init(key: "FLY_API_TOKEN", label: "API token", isRequired: false),
                .init(key: "FLY_APP_NAME", label: "App name", kind: .plain, isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "railway",
            displayName: "Railway",
            category: .computeHosting,
            cliNames: ["railway"],
            mcpAliases: ["railway"],
            signupURL: URL(string: "https://railway.com/login"),
            docsURL: URL(string: "https://docs.railway.com/reference/cli-api"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install railway"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "railway login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://railway.com/login")),
            ],
            envTemplates: [
                .init(key: "RAILWAY_TOKEN", label: "Project token", isRequired: false),
                .init(key: "RAILWAY_PROJECT_ID", label: "Project ID", kind: .plain, isRequired: false),
                .init(key: "RAILWAY_SERVICE_ID", label: "Service ID", kind: .plain, isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "hetzner",
            displayName: "Hetzner Cloud",
            category: .computeHosting,
            cliNames: ["hcloud"],
            mcpAliases: ["hetzner", "hcloud"],
            signupURL: URL(string: "https://accounts.hetzner.com/signUp"),
            docsURL: URL(string: "https://docs.hetzner.cloud/reference/cloud"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install hcloud"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "hcloud context create"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://accounts.hetzner.com/signUp")),
            ],
            envTemplates: [
                .init(key: "HCLOUD_TOKEN", label: "Cloud API token"),
            ]
        ),
        VendorProvisioningVendor(
            id: "aws",
            displayName: "AWS",
            category: .computeHosting,
            cliNames: ["aws"],
            mcpAliases: ["aws", "amazon-web-services", "amazon"],
            signupURL: URL(string: "https://aws.amazon.com/free/"),
            docsURL: URL(string: "https://docs.aws.amazon.com/cli/"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install awscli"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "aws configure sso"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://aws.amazon.com/free/")),
            ],
            envTemplates: [
                .init(key: "AWS_PROFILE", label: "Profile name", kind: .plain, isRequired: false),
                .init(key: "AWS_REGION", label: "Default region", kind: .plain, isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "gcp",
            displayName: "Google Cloud",
            category: .computeHosting,
            cliNames: ["gcloud"],
            mcpAliases: ["gcp", "google-cloud", "gcloud"],
            signupURL: URL(string: "https://cloud.google.com/free"),
            docsURL: URL(string: "https://cloud.google.com/sdk/docs"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install --cask google-cloud-sdk"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "gcloud auth login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://cloud.google.com/free")),
            ],
            envTemplates: [
                .init(key: "GOOGLE_CLOUD_PROJECT", label: "Project ID", kind: .plain, isRequired: false),
                .init(key: "GOOGLE_APPLICATION_CREDENTIALS", label: "Credentials file path", kind: .plain, isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "azure",
            displayName: "Azure",
            category: .computeHosting,
            cliNames: ["az"],
            mcpAliases: ["azure", "az"],
            signupURL: URL(string: "https://azure.microsoft.com/free"),
            docsURL: URL(string: "https://learn.microsoft.com/cli/azure/"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "brew install azure-cli"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "az login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://azure.microsoft.com/free")),
            ],
            envTemplates: [
                .init(key: "AZURE_TENANT_ID", label: "Tenant ID", kind: .plain, isRequired: false),
                .init(key: "AZURE_SUBSCRIPTION_ID", label: "Subscription ID", kind: .plain, isRequired: false),
                .init(key: "AZURE_CLIENT_ID", label: "Client ID", kind: .plain, isRequired: false),
                .init(key: "AZURE_CLIENT_SECRET", label: "Client secret", isRequired: false),
            ]
        ),
        VendorProvisioningVendor(
            id: "cloudflare",
            displayName: "Cloudflare",
            category: .domains,
            cliNames: ["wrangler"],
            mcpAliases: ["cloudflare", "wrangler", "workers"],
            signupURL: URL(string: "https://dash.cloudflare.com/sign-up"),
            docsURL: URL(string: "https://developers.cloudflare.com/workers/wrangler/"),
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "npm i -g wrangler@latest"),
                .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "wrangler login"),
                .init(id: "signup", kind: .signup, label: "Sign Up", url: URL(string: "https://dash.cloudflare.com/sign-up")),
            ],
            envTemplates: [
                .init(key: "CLOUDFLARE_API_TOKEN", label: "API token"),
                .init(key: "CLOUDFLARE_ACCOUNT_ID", label: "Account ID", kind: .plain, isRequired: false),
                .init(key: "CLOUDFLARE_ZONE_ID", label: "Zone ID", kind: .plain, isRequired: false),
            ]
        ),
    ]

    public static func vendor(id: String) -> VendorProvisioningVendor? {
        vendors.first { $0.id == id }
    }
}

// MARK: - Device status

public enum VendorProvisioningCLIAuthStatus: String, Codable, Hashable, Sendable {
    case unknown
    case notInstalled
    case installed
    case unauthenticated
    case authenticated
    case error
}

public struct VendorProvisioningMCPMatch: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: String
    public let source: String

    public init(id: UUID = UUID(), name: String, kind: String, source: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
    }
}

public struct VendorProvisioningStatus: Codable, Hashable, Sendable {
    public let vendorId: String
    public let cliStatus: VendorProvisioningCLIAuthStatus
    public let installedBinary: String?
    public let version: String?
    public let accountLabel: String?
    public let projectLabel: String?
    public let message: String?
    public let mcpMatches: [VendorProvisioningMCPMatch]
    public let checkedAt: Date

    public init(
        vendorId: String,
        cliStatus: VendorProvisioningCLIAuthStatus,
        installedBinary: String? = nil,
        version: String? = nil,
        accountLabel: String? = nil,
        projectLabel: String? = nil,
        message: String? = nil,
        mcpMatches: [VendorProvisioningMCPMatch] = [],
        checkedAt: Date = Date()
    ) {
        self.vendorId = vendorId
        self.cliStatus = cliStatus
        self.installedBinary = installedBinary
        self.version = version
        self.accountLabel = accountLabel
        self.projectLabel = projectLabel
        self.message = message
        self.mcpMatches = mcpMatches
        self.checkedAt = checkedAt
    }
}

public struct VendorProvisioningVendorsResponse: Codable, Hashable, Sendable {
    public let vendors: [VendorProvisioningVendor]

    public init(vendors: [VendorProvisioningVendor]) {
        self.vendors = vendors
    }
}

public struct VendorProvisioningCheckResponse: Codable, Hashable, Sendable {
    public let vendors: [VendorProvisioningVendor]
    public let statuses: [VendorProvisioningStatus]
    public let checkedAt: Date

    public init(
        vendors: [VendorProvisioningVendor],
        statuses: [VendorProvisioningStatus],
        checkedAt: Date = Date()
    ) {
        self.vendors = vendors
        self.statuses = statuses
        self.checkedAt = checkedAt
    }
}

// MARK: - Actions

public struct VendorProvisioningActionRequest: Codable, Hashable, Sendable {
    public let actionId: String

    public init(actionId: String) {
        self.actionId = actionId
    }
}

public struct VendorProvisioningActionResponse: Codable, Hashable, Sendable {
    public let vendorId: String
    public let actionId: String
    public let launched: Bool
    public let command: String?
    public let url: URL?
    public let terminalWindowId: String?
    public let terminalPaneId: String?
    public let message: String

    public init(
        vendorId: String,
        actionId: String,
        launched: Bool,
        command: String? = nil,
        url: URL? = nil,
        terminalWindowId: String? = nil,
        terminalPaneId: String? = nil,
        message: String
    ) {
        self.vendorId = vendorId
        self.actionId = actionId
        self.launched = launched
        self.command = command
        self.url = url
        self.terminalWindowId = terminalWindowId
        self.terminalPaneId = terminalPaneId
        self.message = message
    }
}

// MARK: - Env preview/import

public enum VendorEnvVariableKind: String, Codable, Hashable, Sendable {
    case sensitive
    case plain
    case system
}

public enum VendorEnvConflictStrategy: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case skip
    case overwrite
    case createDisabledDrafts

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skip: return "Skip existing"
        case .overwrite: return "Overwrite existing"
        case .createDisabledDrafts: return "Create disabled drafts"
        }
    }
}

public struct VendorEnvCandidate: Codable, Hashable, Identifiable, Sendable {
    public let key: String
    public let value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct VendorEnvPreviewRequest: Codable, Hashable, Sendable {
    public let currentWorkspaceId: UUID?
    public let workspaceIds: [UUID]
    public let envText: String?
    public let candidates: [VendorEnvCandidate]

    public init(
        currentWorkspaceId: UUID? = nil,
        workspaceIds: [UUID] = [],
        envText: String? = nil,
        candidates: [VendorEnvCandidate] = []
    ) {
        self.currentWorkspaceId = currentWorkspaceId
        self.workspaceIds = workspaceIds
        self.envText = envText
        self.candidates = candidates
    }

    private enum CodingKeys: String, CodingKey {
        case currentWorkspaceId
        case workspaceIds
        case envText
        case candidates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentWorkspaceId = try c.decodeIfPresent(UUID.self, forKey: .currentWorkspaceId)
        workspaceIds = try c.decodeIfPresent([UUID].self, forKey: .workspaceIds) ?? []
        envText = try c.decodeIfPresent(String.self, forKey: .envText)
        candidates = try c.decodeIfPresent([VendorEnvCandidate].self, forKey: .candidates) ?? []
    }
}

public struct VendorEnvPreviewItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let line: Int
    public let key: String?
    public let status: String
    public let message: String
    public let canImport: Bool

    public init(
        id: UUID = UUID(),
        line: Int,
        key: String?,
        status: String,
        message: String,
        canImport: Bool
    ) {
        self.id = id
        self.line = line
        self.key = key
        self.status = status
        self.message = message
        self.canImport = canImport
    }
}

public struct VendorEnvPreviewResponse: Codable, Hashable, Sendable {
    public let vendorId: String
    public let workspaceId: UUID
    public let previews: [VendorEnvPreviewItem]

    public init(vendorId: String, workspaceId: UUID, previews: [VendorEnvPreviewItem]) {
        self.vendorId = vendorId
        self.workspaceId = workspaceId
        self.previews = previews
    }
}

public struct VendorEnvImportRequest: Codable, Hashable, Sendable {
    public let currentWorkspaceId: UUID?
    public let workspaceIds: [UUID]
    public let selectedSetIds: [UUID]
    public let envText: String?
    public let candidates: [VendorEnvCandidate]
    public let conflictStrategy: VendorEnvConflictStrategy

    public init(
        currentWorkspaceId: UUID? = nil,
        workspaceIds: [UUID] = [],
        selectedSetIds: [UUID] = [],
        envText: String? = nil,
        candidates: [VendorEnvCandidate] = [],
        conflictStrategy: VendorEnvConflictStrategy = .skip
    ) {
        self.currentWorkspaceId = currentWorkspaceId
        self.workspaceIds = workspaceIds
        self.selectedSetIds = selectedSetIds
        self.envText = envText
        self.candidates = candidates
        self.conflictStrategy = conflictStrategy
    }
}

public struct VendorEnvImportResponse: Codable, Hashable, Sendable {
    public let vendorId: String
    public let batchId: UUID
    public let workspaceIds: [UUID]
    public let importedCount: Int
    public let overwrittenCount: Int
    public let skippedCount: Int
    public let invalidCount: Int
    public let actor: String?
    public let materializedCurrentRepo: Bool

    public init(
        vendorId: String,
        batchId: UUID,
        workspaceIds: [UUID],
        importedCount: Int,
        overwrittenCount: Int,
        skippedCount: Int,
        invalidCount: Int,
        actor: String?,
        materializedCurrentRepo: Bool
    ) {
        self.vendorId = vendorId
        self.batchId = batchId
        self.workspaceIds = workspaceIds
        self.importedCount = importedCount
        self.overwrittenCount = overwrittenCount
        self.skippedCount = skippedCount
        self.invalidCount = invalidCount
        self.actor = actor
        self.materializedCurrentRepo = materializedCurrentRepo
    }
}

// MARK: - Guided onboarding

public enum VendorProvisioningInstallPhase: String, Sendable, Equatable {
    case idle
    case installing
    case failed
    case succeeded
}

public struct VendorProvisioningOnboardingGuide: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable {
        case unchecked
        case installingCLI
        case installCLI
        case authenticate
        case configureEnv
        case complete
    }

    public let step: Step
    public let guidance: String
    public let statusLabel: String
    public let showsInstall: Bool
    public let showsAuthenticate: Bool
    public let showsSignup: Bool
    public let showsAddEnv: Bool
    public let primaryActionKind: VendorProvisioningActionKind?

    public static func resolve(
        status: VendorProvisioningStatus?,
        installPhase: VendorProvisioningInstallPhase = .idle
    ) -> VendorProvisioningOnboardingGuide {
        switch installPhase {
        case .installing:
            return VendorProvisioningOnboardingGuide(
                step: .installingCLI,
                guidance: "Installing the CLI in the background…",
                statusLabel: "Installing",
                showsInstall: false,
                showsAuthenticate: false,
                showsSignup: false,
                showsAddEnv: false,
                primaryActionKind: nil
            )
        case .failed:
            return VendorProvisioningOnboardingGuide(
                step: .installCLI,
                guidance: "Step 1 of 3 · Install the CLI, then sign in.",
                statusLabel: "Install Failed",
                showsInstall: true,
                showsAuthenticate: false,
                showsSignup: true,
                showsAddEnv: false,
                primaryActionKind: .install
            )
        case .succeeded:
            return guideForCLIInstalled(status: status, afterInstall: true)
        case .idle:
            break
        }

        switch status?.cliStatus {
        case .none, .unknown:
            return VendorProvisioningOnboardingGuide(
                step: .unchecked,
                guidance: "Run Check Device to detect installed CLIs on this Mac.",
                statusLabel: "Unchecked",
                showsInstall: false,
                showsAuthenticate: false,
                showsSignup: true,
                showsAddEnv: false,
                primaryActionKind: nil
            )
        case .notInstalled:
            return VendorProvisioningOnboardingGuide(
                step: .installCLI,
                guidance: "Step 1 of 3 · Install the CLI, then sign in.",
                statusLabel: "Not Installed",
                showsInstall: true,
                showsAuthenticate: false,
                showsSignup: true,
                showsAddEnv: false,
                primaryActionKind: .install
            )
        case .installed, .unauthenticated, .error:
            return guideForCLIInstalled(status: status, afterInstall: false)
        case .authenticated:
            return VendorProvisioningOnboardingGuide(
                step: .configureEnv,
                guidance: "Step 3 of 3 · Import deployment env variables into repo sets (optional).",
                statusLabel: "Authenticated",
                showsInstall: false,
                showsAuthenticate: false,
                showsSignup: false,
                showsAddEnv: true,
                primaryActionKind: nil
            )
        }
    }

    private static func guideForCLIInstalled(
        status: VendorProvisioningStatus?,
        afterInstall: Bool
    ) -> VendorProvisioningOnboardingGuide {
        if status?.cliStatus == .authenticated {
            return resolve(status: status)
        }

        let authGuidance = afterInstall
            ? "CLI installed. Step 2 of 3 · Sign in to your account."
            : "Step 2 of 3 · Sign in to your account."

        let statusLabel: String
        switch status?.cliStatus {
        case .error:
            statusLabel = "Needs Auth"
        case .installed:
            statusLabel = "Needs Auth"
        default:
            statusLabel = "Needs Auth"
        }

        return VendorProvisioningOnboardingGuide(
            step: .authenticate,
            guidance: authGuidance,
            statusLabel: statusLabel,
            showsInstall: false,
            showsAuthenticate: true,
            showsSignup: true,
            showsAddEnv: false,
            primaryActionKind: .authenticate
        )
    }
}

public extension VendorProvisioningStatus {
    var isCLIInstalled: Bool {
        switch cliStatus {
        case .installed, .unauthenticated, .authenticated, .error:
            return true
        case .notInstalled:
            return false
        case .unknown:
            return installedBinary != nil
        }
    }
}
