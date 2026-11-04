import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A small HTTP/1.1 file server on 127.0.0.1 for tests: GET only, `Range: bytes=N-`, an ETag so downloads can resume, and an optional
/// stall that holds a response part-way until the test opens its gate. Tests/TinyHTTPServer.swift is the same file for the package tests.
final class TinyHTTPServer: @unchecked Sendable {
    struct Request: Equatable { let path: String; let range: String? }
#if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
#else
    private static let streamType = SOCK_STREAM
#endif

    private let lock = NSLock()
    private var files: [String: Data]
    private var stalls: [String: (after: Int, gate: DispatchSemaphore)] = [:]
    private var gates: [String: DispatchSemaphore] = [:]
    private var stalledPaths: Set<String> = []
    private var log: [Request] = []
    private let listener: Int32
    private(set) var port: UInt16 = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }

    /// `files` is keyed by the request path without the leading slash.
    init(files: [String: Data]) throws {
        self.files = files
        signal(SIGPIPE, SIG_IGN)
        listener = socket(AF_INET, Self.streamType, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, Darwin_or_Glibc_listen(listener) == 0 else { close(listener); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        let fd = listener
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                guard let self else { close(client); return }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
    }

    deinit { stop() }

    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    /// Holds the response for `path` after `after` body bytes until `release(_:)`. Applies to the first matching request only.
    func stall(_ path: String, after: Int) { lock.lock(); stalls[path] = (after, DispatchSemaphore(value: 0)); lock.unlock() }
    func release(_ path: String) { lock.lock(); let gate = gates[path]; lock.unlock(); gate?.signal() }
    /// Whether a response is being held right now.
    func isStalled(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stalledPaths.contains(path) }

    func replace(_ path: String, with data: Data) { lock.lock(); files[path] = data; lock.unlock() }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var head = Data()
        var byte = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(client, &byte, byte.count, 0)
            if n <= 0 { return }
            head.append(contentsOf: byte[0..<n])
            if head.count > 65536 { return }
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return send(client, status: "405 Method Not Allowed", headers: [], body: Data()) }
        let path = String(parts[1].dropFirst())
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        lock.lock()
        log.append(Request(path: path, range: range))
        let file = files[path]
        let stall = stalls[path]
        if let stall { stalls[path] = nil; gates[path] = stall.gate }
        lock.unlock()
        guard let file else { return send(client, status: "404 Not Found", headers: [], body: Data("not found".utf8)) }

        let etag = "\"\(file.count)-\(path.hashValue & 0xffff)\""
        var start = 0
        if let range, range.hasPrefix("bytes="), let first = Int(range.dropFirst(6).split(separator: "-").first ?? "") { start = min(first, file.count) }
        let body = file.subdata(in: start..<file.count)
        var headers = ["Accept-Ranges: bytes", "ETag: \(etag)", "Last-Modified: Mon, 02 Nov 2026 00:00:00 GMT", "Content-Type: application/octet-stream"]
        if start > 0 { headers.append("Content-Range: bytes \(start)-\(file.count - 1)/\(file.count)") }
        var hold: (after: Int, hold: () -> Void)?
        if let stall {
            hold = (stall.after, { [self] in
                lock.lock(); stalledPaths.insert(path); lock.unlock()
                _ = stall.gate.wait(timeout: .now() + 30)
                lock.lock(); stalledPaths.remove(path); lock.unlock()
            })
        }
        send(client, status: start > 0 ? "206 Partial Content" : "200 OK", headers: headers, body: body, stall: hold)
    }

    private func send(_ client: Int32, status: String, headers: [String], body: Data, stall: (after: Int, hold: () -> Void)? = nil) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for header in headers { head += header + "\r\n" }
        head += "\r\n"
        guard write(client, Data(head.utf8)) else { return }
        var sent = 0, stalled = false
        while sent < body.count {
            var end = min(sent + 16384, body.count)
            if let stall, !stalled, sent < stall.after { end = min(end, stall.after) }
            guard write(client, body.subdata(in: sent..<end)) else { return }
            sent = end
            if let stall, !stalled, sent >= stall.after { stalled = true; stall.hold() }
        }
    }

    private func write(_ client: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in send_(client, raw.baseAddress! + offset, data.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

private func send_(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.send(fd, pointer, count, 0)
    #else
    Glibc.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
    #endif
}

private func Darwin_or_Glibc_listen(_ fd: Int32) -> Int32 { listen(fd, 16) }
