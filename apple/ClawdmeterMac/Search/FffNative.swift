import Foundation

let fffCreateOptionsVersion: UInt32 = 1

struct FffCResult {
    var success: Bool
    var error: UnsafeMutablePointer<CChar>?
    var handle: UnsafeMutableRawPointer?
    var intValue: Int64
}

struct FffCCreateOptions {
    var version: UInt32 = fffCreateOptionsVersion
    var basePath: UnsafePointer<CChar>?
    var frecencyDBPath: UnsafePointer<CChar>? = nil
    var historyDBPath: UnsafePointer<CChar>? = nil
    var enableMmapCache: Bool = true
    var enableContentIndexing: Bool = true
    var watch: Bool = true
    var aiMode: Bool = true
    var logFilePath: UnsafePointer<CChar>? = nil
    var logLevel: UnsafePointer<CChar>? = nil
    var cacheBudgetMaxFiles: UInt64 = 0
    var cacheBudgetMaxBytes: UInt64 = 0
    var cacheBudgetMaxFileSize: UInt64 = 0
    var enableFSRootScanning: Bool = false
    var enableHomeDirScanning: Bool = false
}

struct FffCFileItem {
    var relativePath: UnsafeMutablePointer<CChar>?
    var fileName: UnsafeMutablePointer<CChar>?
    var gitStatus: UnsafeMutablePointer<CChar>?
    var size: UInt64
    var modified: UInt64
    var accessFrecencyScore: Int64
    var modificationFrecencyScore: Int64
    var totalFrecencyScore: Int64
    var isBinary: Bool
}

struct FffCLocation {
    var tag: UInt8
    var line: Int32
    var col: Int32
    var endLine: Int32
    var endCol: Int32
}

struct FffCSearchResult {
    var items: UnsafeMutablePointer<FffCFileItem>?
    var scores: UnsafeMutableRawPointer?
    var count: UInt32
    var totalMatched: UInt32
    var totalFiles: UInt32
    var location: FffCLocation
}

enum FffLibraryError: Error, LocalizedError {
    case libraryNotFound
    case symbolMissing(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotFound:
            return "Bundled FFF search library was not found."
        case .symbolMissing(let symbol):
            return "FFF library is missing symbol \(symbol)."
        case .loadFailed(let message):
            return "Failed to load FFF library: \(message)"
        }
    }
}

final class FffLibrary: @unchecked Sendable {
    static let shared = FffLibrary()

    private let libraryHandle: UnsafeMutableRawPointer?

    private init() {
        guard let path = Self.locateLibraryPath() else {
            libraryHandle = nil
            return
        }
        libraryHandle = dlopen(path, RTLD_NOW)
    }

    var isAvailable: Bool { libraryHandle != nil }

    func createInstance(basePath: String) throws -> OpaquePointer {
        guard let libraryHandle else { throw FffLibraryError.libraryNotFound }
        guard let sym = dlsym(libraryHandle, "fff_create_instance_with") else {
            throw FffLibraryError.symbolMissing("fff_create_instance_with")
        }
        typealias Fn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
        let fn = unsafeBitCast(sym, to: Fn.self)

        return try basePath.withCString { cPath in
            var options = FffCCreateOptions()
            options.version = fffCreateOptionsVersion
            options.basePath = cPath
            options.watch = true
            options.aiMode = true
            options.enableContentIndexing = true
            options.enableMmapCache = true

            let result = withUnsafePointer(to: &options) { optionsPtr in
                fn(UnsafeRawPointer(optionsPtr))
            }
            return try takeInstance(from: result)
        }
    }

    func waitForScan(_ handle: OpaquePointer, timeoutMs: UInt64) throws -> Bool {
        guard let libraryHandle else { throw FffLibraryError.libraryNotFound }
        guard let sym = dlsym(libraryHandle, "fff_wait_for_scan") else {
            throw FffLibraryError.symbolMissing("fff_wait_for_scan")
        }
        typealias Fn = @convention(c) (OpaquePointer?, UInt64) -> OpaquePointer?
        let fn = unsafeBitCast(sym, to: Fn.self)

        guard let result = fn(handle, timeoutMs) else {
            throw FffLibraryError.loadFailed("fff_wait_for_scan returned nil")
        }
        defer { freeResult(result) }
        let envelope = envelope(from: result)
        return envelope.success && envelope.intValue == 1
    }

    func search(
        _ handle: OpaquePointer,
        query: String,
        limit: Int
    ) throws -> UnsafeMutablePointer<FffCSearchResult> {
        guard let libraryHandle else { throw FffLibraryError.libraryNotFound }
        guard let sym = dlsym(libraryHandle, "fff_search") else {
            throw FffLibraryError.symbolMissing("fff_search")
        }
        typealias Fn = @convention(c) (
            OpaquePointer?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UInt32,
            UInt32,
            UInt32,
            Int32,
            UInt32
        ) -> OpaquePointer?
        let fn = unsafeBitCast(sym, to: Fn.self)

        return try query.withCString { queryPtr in
            guard let result = fn(handle, queryPtr, nil, 0, 0, UInt32(max(limit, 1)), 100, 3) else {
                throw FffLibraryError.loadFailed("fff_search returned nil")
            }
            defer { freeResult(result) }

            let envelope = envelope(from: result)
            guard envelope.success, let payload = envelope.handle else {
                let message = envelope.error.map { String(cString: $0) } ?? "search failed"
                throw FffLibraryError.loadFailed(message)
            }
            return payload.assumingMemoryBound(to: FffCSearchResult.self)
        }
    }

    func destroy(_ handle: OpaquePointer?) {
        guard let libraryHandle, let handle else { return }
        guard let sym = dlsym(libraryHandle, "fff_destroy") else { return }
        typealias Fn = @convention(c) (OpaquePointer?) -> Void
        let fn = unsafeBitCast(sym, to: Fn.self)
        fn(handle)
    }

    func freeSearchResult(_ result: UnsafeMutablePointer<FffCSearchResult>) {
        guard let libraryHandle else { return }
        guard let sym = dlsym(libraryHandle, "fff_free_search_result") else { return }
        typealias Fn = @convention(c) (OpaquePointer?) -> Void
        let fn = unsafeBitCast(sym, to: Fn.self)
        fn(OpaquePointer(result))
    }

    func freeResult(_ result: OpaquePointer?) {
        guard let libraryHandle, let result else { return }
        guard let sym = dlsym(libraryHandle, "fff_free_result") else { return }
        typealias Fn = @convention(c) (OpaquePointer?) -> Void
        let fn = unsafeBitCast(sym, to: Fn.self)
        fn(result)
    }

    static func locateLibraryPath() -> String? {
        let overrideKey = "clawdmeter.libraries.fff"
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("Vendor", isDirectory: true)
                .appendingPathComponent("fff", isDirectory: true)
                .appendingPathComponent("libfff_c.dylib", isDirectory: false)
                .path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        #if DEBUG
        let envKey = "CLAWDMETER_LIB_FFF"
        if let envOverride = ProcessInfo.processInfo.environment[envKey],
           !envOverride.isEmpty,
           FileManager.default.fileExists(atPath: envOverride) {
            return envOverride
        }
        #endif

        return nil
    }

    private func takeInstance(from result: OpaquePointer?) throws -> OpaquePointer {
        guard let result else {
            throw FffLibraryError.loadFailed("fff_create_instance_with returned nil")
        }
        defer { freeResult(result) }
        let envelope = envelope(from: result)
        guard envelope.success, let instance = envelope.handle else {
            let message = envelope.error.map { String(cString: $0) } ?? "unknown error"
            throw FffLibraryError.loadFailed(message)
        }
        return OpaquePointer(instance)
    }

    private func envelope(from result: OpaquePointer) -> FffCResult {
        UnsafeRawPointer(result).assumingMemoryBound(to: FffCResult.self).pointee
    }
}
