// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

public final class InstanceLock {
    private let fd: Int32
    public init(directory: URL) throws {
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        try CliprillPaths.prepare(runtime)
        fd = Darwin.open(runtime.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CoreError("ipc", "Cannot open the application lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw CoreError("already_running", "Cliprill is already running for this data directory.")
        }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}

private enum Wire {
    static let maximum = 4_000_000
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CoreError("ipc", "The data directory path is too long for a local socket.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw CoreError("ipc", "Only the current user may connect to Cliprill.") }
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let result = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw CoreError("ipc", "The local connection closed or timed out.") }
            offset += result
        }
        return Data(bytes)
    }
    static func receive(_ fd: Int32) throws -> Data {
        let header = try read(fd, count: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximum else { throw CoreError("ipc", "Local message exceeds the size limit.") }
        return try read(fd, count: count)
    }
    static func send(_ fd: Int32, data: Data) throws {
        guard !data.isEmpty, data.count <= maximum else { throw CoreError("ipc", "Local message exceeds the size limit.") }
        let n = UInt32(data.count)
        let header = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        let bytes = header + data
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw CoreError("ipc", "Cannot write to the local connection.") }
            offset += result
        }
    }
}

public enum IPCClient {
    public static func send(_ request: IPCRequest, directory: URL = CliprillPaths.dataDirectory) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreError("ipc", "Cannot create a local socket.") }
        defer { Darwin.close(fd) }; Wire.configure(fd)
        var address = try Wire.address(CliprillPaths.socketPath(in: directory))
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw CoreError("app_unavailable", "Cliprill is not running. Open Cliprill.app and retry.") }
        try Wire.verifyPeer(fd)
        try Wire.send(fd, data: JSONEncoder().encode(request))
        return try JSONDecoder().decode(IPCResponse.self, from: Wire.receive(fd)).get()
    }
}

public final class IPCServer: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let queue = DispatchQueue(label: "app.cliprill.ipc", qos: .utility)
    private var source: DispatchSourceRead?
    public init(directory: URL) throws {
        path = CliprillPaths.socketPath(in: directory)
        try CliprillPaths.prepare(directory.appendingPathComponent("runtime"))
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { throw CoreError("ipc", "An unexpected file occupies the socket path.") }
            if (try? IPCClient.send(IPCRequest(method: "queue_list"), directory: directory)) != nil {
                throw CoreError("already_running", "A Cliprill server already owns this socket.")
            }
            guard unlink(path) == 0 else { throw CoreError("ipc", "Cannot remove the stale socket.") }
        }
        var address = try Wire.address(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreError("ipc", "Cannot create the application socket.") }
        Wire.configure(fd)
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd); throw CoreError("ipc", "Cannot bind the application socket.")
        }
    }
    public func start(handler: @escaping @Sendable (IPCRequest) async -> IPCResponse) {
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Wire.configure(client)
            do {
                try Wire.verifyPeer(client)
                let request = try JSONDecoder().decode(IPCRequest.self, from: Wire.receive(client))
                Task {
                    let response = await handler(request)
                    // All socket I/O stays off the UI thread.
                    self.queue.async {
                        defer { Darwin.close(client) }
                        do { try Wire.send(client, data: JSONEncoder().encode(response)) }
                        catch { /* The client can safely retry using its idempotency key. */ }
                    }
                }
            } catch {
                try? Wire.send(client, data: JSONEncoder().encode(IPCResponse(error: error)))
                Darwin.close(client)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source; source.resume()
    }
    public func stop() { source?.cancel(); source = nil; unlink(path) }
    deinit { stop() }
}
