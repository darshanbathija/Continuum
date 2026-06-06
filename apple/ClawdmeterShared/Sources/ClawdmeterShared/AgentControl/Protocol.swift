import Foundation

// AgentControl protocol DTOs (cross-platform).
//
// Wire shape between the Mac daemon (AgentControlServer) and the Mac/iOS
// SwiftUI clients. Every payload is Codable; the server serializes as JSON
// over HTTP and binary WebSocket frames where appropriate.
//
// Per E8: every structured event carries a monotonic `eventSeq` so a
// reconnecting client can request `?since=<seq>` and replay missed events.
// Per E2: these DTOs are Sendable so they cross actor / NIO event loop
// boundaries without copies tripping the type checker.

// Domain DTO definitions live in ProtocolDTOs/*.swift. The split keeps
// the public type names and JSON wire shapes unchanged while making each
// protocol area navigable on its own.
