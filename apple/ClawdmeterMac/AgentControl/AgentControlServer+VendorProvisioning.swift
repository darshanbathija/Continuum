import Foundation
import Network
import ClawdmeterShared

/// Wire v24 vendor provisioning handlers.
///
/// These routes are deliberately thin. The service owns CLI probing,
/// Terminal-visible action launch, MCP matching, and PR 201 repo-env import
/// adaptation. Handlers only decode/encode wire DTOs and preserve the existing
/// `RepoEnvError.manualConflicts` 409 shape.
extension AgentControlServer {
    func handleGetVendorProvisioningVendors(connection: NWConnection) {
        guard let vendorProvisioningService else {
            sendVendorProvisioningError("vendor_provisioning_unavailable", status: 503, on: connection)
            return
        }
        sendCodableValue(vendorProvisioningService.vendorsResponse(), on: connection)
    }

    func handleCheckVendorProvisioning(connection: NWConnection) async {
        guard let vendorProvisioningService else {
            sendVendorProvisioningError("vendor_provisioning_unavailable", status: 503, on: connection)
            return
        }
        let response = await vendorProvisioningService.checkDevice()
        sendCodableValue(response, on: connection)
    }

    func handleVendorProvisioningAction(
        vendorId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let vendorProvisioningService else {
            sendVendorProvisioningError("vendor_provisioning_unavailable", status: 503, on: connection)
            return
        }
        guard let body = try? JSONDecoder().decode(VendorProvisioningActionRequest.self, from: request.body) else {
            sendVendorProvisioningError("bad_request", detail: "Invalid vendor action request.", status: 400, on: connection)
            return
        }
        do {
            let response = try await vendorProvisioningService.performAction(
                vendorId: vendorId,
                actionId: body.actionId
            )
            sendCodableValue(response, on: connection)
        } catch {
            sendVendorProvisioningError(error, on: connection)
        }
    }

    func handleVendorEnvPreview(
        vendorId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) {
        guard let vendorProvisioningService else {
            sendVendorProvisioningError("vendor_provisioning_unavailable", status: 503, on: connection)
            return
        }
        guard let body = try? JSONDecoder().decode(VendorEnvPreviewRequest.self, from: request.body) else {
            sendVendorProvisioningError("bad_request", detail: "Invalid vendor env preview request.", status: 400, on: connection)
            return
        }
        do {
            let response = try vendorProvisioningService.previewEnv(vendorId: vendorId, request: body)
            sendCodableValue(response, on: connection)
        } catch {
            sendVendorProvisioningError(error, on: connection)
        }
    }

    func handleVendorEnvImport(
        vendorId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) {
        guard let vendorProvisioningService else {
            sendVendorProvisioningError("vendor_provisioning_unavailable", status: 503, on: connection)
            return
        }
        guard let body = try? JSONDecoder().decode(VendorEnvImportRequest.self, from: request.body) else {
            sendVendorProvisioningError("bad_request", detail: "Invalid vendor env import request.", status: 400, on: connection)
            return
        }
        do {
            let response = try vendorProvisioningService.importEnv(vendorId: vendorId, request: body)
            sendCodableValue(response, on: connection)
        } catch {
            if sendRepoEnvConflict(error, on: connection) { return }
            sendVendorProvisioningError(error, on: connection)
        }
    }

    private func sendCodableValue<T: Encodable>(_ value: T, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    }

    private func sendVendorProvisioningError(
        _ error: Error,
        on connection: NWConnection
    ) {
        let status: Int
        let code: String
        switch error {
        case VendorProvisioningError.unknownVendor(_):
            status = 404
            code = "unknown_vendor"
        case VendorProvisioningError.unknownAction(_, _):
            status = 404
            code = "unknown_vendor_action"
        case VendorProvisioningError.unsupportedAction(_):
            status = 400
            code = "unsupported_vendor_action"
        case VendorProvisioningError.noWorkspaces:
            status = 409
            code = "no_workspaces"
        case VendorProvisioningError.workspaceNotFound(_):
            status = 404
            code = "workspace_not_found"
        case VendorProvisioningError.emptyEnvPayload:
            status = 400
            code = "empty_env_payload"
        default:
            status = 500
            code = "vendor_provisioning_failed"
        }
        sendVendorProvisioningError(
            code,
            detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            status: status,
            on: connection
        )
    }

    private func sendVendorProvisioningError(
        _ code: String,
        detail: String? = nil,
        status: Int,
        on connection: NWConnection
    ) {
        var object: [String: Any] = ["error": code]
        if let detail {
            object["detail"] = detail
        }
        let body = (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"error":"vendor_provisioning_failed"}"#.utf8)
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 503: reason = "Service Unavailable"
        default: reason = "Internal Server Error"
        }
        sendResponse(
            HTTPResponse(status: status, reason: reason, contentType: "application/json", body: body),
            on: connection
        )
    }
}
