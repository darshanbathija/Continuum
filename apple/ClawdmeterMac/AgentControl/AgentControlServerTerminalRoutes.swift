import Darwin
import Foundation
import Network
import ClawdmeterShared

private struct AddTerminalRequest: Codable {
    let title: String?
}

private struct RenameTerminalRequest: Codable {
    let title: String?
}

extension AgentControlServer {
    func handleGetTerminals(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session.terminalPanes) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// GET /sessions/:id/artifact?path=<relative-or-abs>
    func handleGetArtifact(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard let comps = URLComponents(string: request.path),
              let pathArg = comps.queryItems?.first(where: { $0.name == "path" })?.value,
              !pathArg.isEmpty else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let repoCwd = session.effectiveCwd
        guard !repoCwd.isEmpty, repoCwd.hasPrefix("/") else {
            sendResponse(.internalError, on: connection)
            return
        }
        let absolute: String = pathArg.hasPrefix("/")
            ? pathArg
            : (repoCwd as NSString).appendingPathComponent(pathArg)
        let repoStandard = (repoCwd as NSString).standardizingPath
        let canonical = (absolute as NSString).standardizingPath
        let resolved = (canonical as NSString).resolvingSymlinksInPath
        let repoResolved = (repoStandard as NSString).resolvingSymlinksInPath
        let underCanonicalRepo = canonical.hasPrefix(repoStandard + "/") || canonical == repoStandard
        let underResolvedRepo = resolved.hasPrefix(repoResolved + "/") || resolved == repoResolved
        guard underCanonicalRepo && underResolvedRepo else {
            sendResponse(HTTPResponse(
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain",
                body: Data("path escapes session worktree\n".utf8)
            ), on: connection)
            return
        }
        let url = URL(fileURLWithPath: resolved)
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let code = errno == ELOOP ? 403 : 404
            let reason = errno == ELOOP ? "Forbidden" : "Not Found"
            let body = errno == ELOOP
                ? "symlink at artifact path is not allowed\n"
                : "artifact not found\n"
            sendResponse(HTTPResponse(
                status: code,
                reason: reason,
                contentType: "text/plain",
                body: Data(body.utf8)
            ), on: connection)
            return
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            sendResponse(.internalError, on: connection)
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            sendResponse(HTTPResponse(
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain",
                body: Data("artifact path is not a regular file\n".utf8)
            ), on: connection)
            return
        }
        let size = Int(st.st_size)
        guard size <= 50_000_000 else {
            sendResponse(.notFound, on: connection)
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(.ok(contentType: contentType(for: url), body: data), on: connection)
    }

    /// GET /sessions/:id/markdown-document?path=<relative-or-abs>
    func handleGetMarkdownDocument(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard let comps = URLComponents(string: request.path),
              let pathArg = comps.queryItems?.first(where: { $0.name == "path" })?.value,
              !pathArg.isEmpty else {
            sendResponse(.badRequest(detail: "missing document path"), on: connection)
            return
        }
        guard let path = Self.standardizedMarkdownDocumentPath(pathArg, relativeTo: session.effectiveCwd) else {
            sendResponse(.badRequest(detail: "invalid document path"), on: connection)
            return
        }
        guard GeneratedArtifactDetector.isMarkdownPath(path) else {
            sendResponse(HTTPResponse(
                status: 415,
                reason: "Unsupported Media Type",
                contentType: "text/plain",
                body: Data("document path is not Markdown\n".utf8)
            ), on: connection)
            return
        }

        let resolved = (path as NSString).resolvingSymlinksInPath
        guard Self.isMarkdownDocumentPathAllowed(path, relativeTo: session.effectiveCwd) else {
            sendResponse(HTTPResponse(
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain",
                body: Data("document path escapes allowed roots\n".utf8)
            ), on: connection)
            return
        }
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let code: Int
            let reason: String
            let body: String
            switch errno {
            case EACCES, EPERM, ELOOP:
                code = 403
                reason = "Forbidden"
                body = "document path is not readable\n"
            default:
                code = 404
                reason = "Not Found"
                body = "document not found\n"
            }
            sendResponse(HTTPResponse(
                status: code,
                reason: reason,
                contentType: "text/plain",
                body: Data(body.utf8)
            ), on: connection)
            return
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            sendResponse(.internalError, on: connection)
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            sendResponse(HTTPResponse(
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain",
                body: Data("document path is not a regular file\n".utf8)
            ), on: connection)
            return
        }
        let size = Int(st.st_size)
        guard size <= Self.markdownDocumentMaxBytes else {
            sendResponse(HTTPResponse(
                status: 413,
                reason: "Payload Too Large",
                contentType: "text/plain",
                body: Data("document is larger than 2 MB\n".utf8)
            ), on: connection)
            return
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else {
            sendResponse(.internalError, on: connection)
            return
        }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            sendResponse(HTTPResponse(
                status: 415,
                reason: "Unsupported Media Type",
                contentType: "text/plain",
                body: Data("document is not readable UTF-8 Markdown text\n".utf8)
            ), on: connection)
            return
        }
        sendResponse(.ok(contentType: "text/markdown; charset=utf-8", body: data), on: connection)
    }

    func handleAddTerminal(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid),
              let windowId = session.tmuxWindowId else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection)
            return
        }
        guard session.terminalPanes.count < 7 else {
            sendResponse(HTTPResponse(
                status: 409,
                reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"terminal pane limit reached"}"#.utf8)
            ), on: connection)
            return
        }
        let req = (try? JSONDecoder().decode(AddTerminalRequest.self, from: request.body))
            ?? AddTerminalRequest(title: nil)
        do {
            let paneId = try await tmux.splitWindow(
                windowId: windowId,
                cwd: session.effectiveCwd,
                horizontal: false
            )
            let pane = TerminalPaneRef(paneId: paneId, title: req.title ?? "", isPrimary: false)
            try await registry.addTerminalPane(sessionId: uuid, pane: pane)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(pane) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    func handleDeleteTerminal(sessionId: String, paneId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid),
              let pane = session.terminalPanes.first(where: { $0.id.uuidString == paneId }) else {
            sendResponse(.notFound, on: connection)
            return
        }
        if pane.isPrimary {
            sendResponse(.badRequest, on: connection)
            return
        }
        do {
            try await tmux.killPane(pane.paneId)
            try await registry.removeTerminalPane(sessionId: uuid, paneRefId: pane.id)
            sendJSON(["ok": true], on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    func handleRenameTerminal(
        sessionId: String,
        paneId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let paneUUID = UUID(uuidString: paneId),
              registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard let req = try? JSONDecoder().decode(RenameTerminalRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let title = (req.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let pane = try await registry.renameTerminalPane(
                sessionId: uuid,
                paneRefId: paneUUID,
                title: title
            ) else {
                sendResponse(.notFound, on: connection)
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(pane) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "json": return "application/json"
        case "txt", "log", "md": return "text/plain"
        case "html": return "text/html"
        case "csv": return "text/csv"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}
