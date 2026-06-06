import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif

private let terminalPtyLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TerminalPtyHost")

enum PtyProcessTerminator {
    static func terminateProcessGroup(pid: pid_t) {
        #if canImport(Darwin)
        guard pid > 0 else { return }
        let initialRelatedPids = relatedPids(of: pid)
        signalProcessTree(pid: pid, relatedPids: initialRelatedPids, signal: SIGHUP)
        signalProcessTree(pid: pid, relatedPids: initialRelatedPids, signal: SIGTERM)
        if waitForExit(pid: pid, relatedPids: initialRelatedPids, timeout: 0.3) { return }

        let refreshedPids = Array(Set(initialRelatedPids + relatedPids(of: pid)))
        signalProcessTree(pid: pid, relatedPids: refreshedPids, signal: SIGKILL)
        _ = waitForExit(pid: pid, relatedPids: refreshedPids, timeout: 0.7)
        #endif
    }

    #if canImport(Darwin)
    private static func signalProcessTree(pid: pid_t, relatedPids: [pid_t], signal: Int32) {
        signalGroupAndProcess(pid: pid, signal: signal)
        for relatedPid in relatedPids {
            signalGroupAndProcess(pid: relatedPid, signal: signal)
        }
    }

    private static func signalGroupAndProcess(pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        _ = Darwin.kill(-pid, signal)
        _ = Darwin.kill(pid, signal)
    }

    private static func waitForExit(pid: pid_t, relatedPids: [pid_t], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var parentExited = false
        while Date() < deadline {
            parentExited = parentExited || reapIfExited(pid: pid)
            if parentExited && relatedPids.allSatisfy({ !processIsLive($0) }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        parentExited = parentExited || reapIfExited(pid: pid)
        return parentExited && relatedPids.allSatisfy { !processIsLive($0) }
    }

    private static func reapIfExited(pid: pid_t) -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            return errno == ECHILD
        }
    }

    private static func processIsLive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) != 0 { return errno != ESRCH }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "stat="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return false }
            let state = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return !state.contains("Z")
        } catch {
            return true
        }
    }

    private static func relatedPids(of root: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,sess="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return [] }
        } catch {
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var childrenByParent: [pid_t: [pid_t]] = [:]
        var sessionMembers = Set<pid_t>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = pid_t(String(parts[0])),
                  let parent = pid_t(String(parts[1])),
                  pid > 0,
                  parent > 0 else {
                continue
            }
            childrenByParent[parent, default: []].append(pid)
            if parts.count >= 3,
               let session = pid_t(String(parts[2])),
               session == root,
               pid != root {
                sessionMembers.insert(pid)
            }
        }

        var seen = Set<pid_t>()
        var queue = childrenByParent[root] ?? []
        var descendants: [pid_t] = []
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            descendants.append(next)
            queue.append(contentsOf: childrenByParent[next] ?? [])
        }
        return Array(Set(descendants).union(sessionMembers))
    }
    #endif
}

/// One direct PTY-backed terminal process. This is the generic terminal
/// counterpart to `ClaudePtyHost`: a child process attached to a pseudo-terminal
/// and byte streams for clients.
actor TerminalPtyHost {
    let id: UUID
    let title: String

    private let argv: [String]
    private let cwd: String?
    private let env: [String: String]
    private let ringCapacity: Int

    private var pty: PseudoTerminal?
    private var childPid: pid_t = 0
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var ring = Data()
    private var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
    private(set) var isRunning = false
    private var onExit: (@Sendable (String) -> Void)?

    init(
        id: UUID = UUID(),
        title: String = "",
        argv: [String],
        cwd: String?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        ringCapacity: Int = 128 * 1024
    ) {
        self.id = id
        self.title = title
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.ringCapacity = ringCapacity
    }

    @discardableResult
    func start(cols: UInt16 = 120, rows: UInt16 = 40) throws -> pid_t {
        guard !isRunning else { return childPid }
        guard let executable = argv.first else {
            throw NSError(domain: "TerminalPtyHost", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty argv"])
        }
        let pty = try PseudoTerminal(cols: cols, rows: rows)
        self.pty = pty
        let pid = try pty.spawn(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            environment: env,
            cwd: cwd
        )
        childPid = pid
        masterFD = pty.masterFD
        isRunning = true
        startReadLoop(masterFD: pty.masterFD)
        startExitWatcher(pid: pid)
        terminalPtyLogger.info("TerminalPtyHost started pid=\(pid) id=\(self.id.uuidString, privacy: .public)")
        return pid
    }

    func setOnExit(_ handler: @escaping @Sendable (String) -> Void) {
        self.onExit = handler
    }

    func outputStream() -> AsyncStream<Data> {
        let subscriberId = UUID()
        let snapshot = ring
        let pair = AsyncStream<Data>.makeStream(of: Data.self)
        if !snapshot.isEmpty {
            pair.continuation.yield(snapshot)
        }
        guard isRunning else {
            pair.continuation.finish()
            return pair.stream
        }
        subscribers[subscriberId] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberId) }
        }
        return pair.stream
    }

    func snapshot() -> Data {
        ring
    }

    @discardableResult
    func writeBytes(_ data: Data) -> Bool {
        guard isRunning, masterFD >= 0 else { return false }
        return Self.writeAll(fd: masterFD, data: data)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        _ = pty?.resize(cols: UInt16(min(cols, Int(UInt16.max))),
                        rows: UInt16(min(rows, Int(UInt16.max))))
    }

    func kill() {
        guard isRunning || pty != nil else { return }
        isRunning = false
        masterFD = -1
        exitSource?.cancel()
        exitSource = nil
        let pidToReap = childPid
        childPid = 0
        if pidToReap > 0 {
            PtyProcessTerminator.terminateProcessGroup(pid: pidToReap)
        }
        if let rs = readSource {
            readSource = nil
            _ = pty?.detachMaster()
            rs.cancel()
        } else {
            pty?.closeMaster()
        }
        pty = nil
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func appendOutput(_ bytes: [UInt8]) {
        let data = Data(bytes)
        ring.append(data)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        for continuation in subscribers.values {
            continuation.yield(data)
        }
    }

    private func startReadLoop(masterFD: Int32) {
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(masterFD, &buf, buf.count)
            guard n > 0 else { return }
            let chunk = Array(buf[0..<n])
            Task { await self?.appendOutput(chunk) }
        }
        src.setCancelHandler { close(masterFD) }
        src.resume()
        readSource = src
    }

    private func startExitWatcher(pid: pid_t) {
        #if canImport(Darwin)
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        src.setEventHandler { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            Task { await self?.handleChildExit(status: status) }
        }
        src.resume()
        exitSource = src
        #endif
    }

    private func handleChildExit(status: Int32) {
        guard isRunning else { return }
        let exitedPid = childPid
        isRunning = false
        masterFD = -1
        childPid = 0
        exitSource?.cancel()
        exitSource = nil
        if exitedPid > 0 {
            PtyProcessTerminator.terminateProcessGroup(pid: exitedPid)
        }
        if let rs = readSource {
            readSource = nil
            _ = pty?.detachMaster()
            rs.cancel()
        } else {
            pty?.closeMaster()
        }
        pty = nil
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        terminalPtyLogger.info("TerminalPtyHost exited status=\(status) id=\(self.id.uuidString, privacy: .public)")
        onExit?(id.uuidString)
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            let total = raw.count
            var eagainWaits = 0
            while off < total {
                let n = write(fd, base + off, total - off)
                if n > 0 { off += n; continue }
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    if e == EAGAIN || e == EWOULDBLOCK {
                        if eagainWaits >= 20 { return false }
                        eagainWaits += 1
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 250)
                        continue
                    }
                }
                return false
            }
            return off == total
        }
    }
}

actor TerminalPtyRegistry {
    static let shared = TerminalPtyRegistry()

    private var hosts: [String: TerminalPtyHost] = [:]

    func host(id: String) async -> TerminalPtyHost? {
        guard let host = hosts[id] else { return nil }
        guard await host.isRunning else {
            hosts[id] = nil
            return nil
        }
        return host
    }

    func spawnShell(cwd: String?, title: String = "") async throws -> TerminalPtyHost {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let host = TerminalPtyHost(
            title: title,
            argv: [shell, "-l"],
            cwd: cwd,
            env: ProcessInfo.processInfo.environment
        )
        try await host.start()
        await host.setOnExit { [weak self] id in
            Task { await self?.dropExited(id: id) }
        }
        hosts[host.id.uuidString] = host
        return host
    }

    func spawnCommand(_ command: String, cwd: String?, title: String = "") async throws -> TerminalPtyHost {
        let host = TerminalPtyHost(
            title: title,
            argv: ["/bin/zsh", "-lc", command],
            cwd: cwd,
            env: ProcessInfo.processInfo.environment
        )
        try await host.start()
        await host.setOnExit { [weak self] id in
            Task { await self?.dropExited(id: id) }
        }
        hosts[host.id.uuidString] = host
        return host
    }

    func kill(id: String) async {
        guard let host = hosts.removeValue(forKey: id) else { return }
        await host.kill()
    }

    private func dropExited(id: String) {
        hosts[id] = nil
    }
}
