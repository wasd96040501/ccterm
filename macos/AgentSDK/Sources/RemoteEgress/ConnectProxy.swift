import Foundation
import Network

/// A minimal loopback-only HTTP forward proxy used for the "CCTerm runs one"
/// egress mode (design `remote-execution.md` §4 / M2).
///
/// A remote `claude` with no outbound internet borrows the Mac's egress by
/// pointing `HTTPS_PROXY` / `HTTP_PROXY` at an `ssh -R` forwarded port that
/// lands on this proxy. The proxy then dials the real target from the Mac, so
/// the remote's traffic exits through the Mac's network.
///
/// Two request shapes are handled:
///
/// - **`CONNECT host:port`** (HTTPS): reply `200 Connection Established`, then
///   blind-forward bytes both ways. TLS stays end-to-end — the proxy never sees
///   plaintext, so SNI/cert remain the real domain (no base-URL rewrite, no
///   injected cert). This is the load-bearing path for the Anthropic API.
/// - **absolute-form `GET http://host/path`** (plain HTTP): rewrite to
///   origin-form, dial `host:port`, relay. Best-effort, mainly for diagnostics.
///
/// Binds `127.0.0.1` only — never exposes an open relay to the LAN. The actual
/// `ssh -R` forwarder always connects from loopback anyway.
public final class ConnectProxy {

    /// Diagnostics sink. Wired to `appLog` by the app layer; defaults to no-op.
    public var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.ccterm.connect-proxy")
    private var listener: NWListener?
    /// Keeps in-flight connection pairs alive for the duration of the relay.
    private var live = Set<RelayPair>()
    private let liveLock = NSLock()

    public init() {}

    /// The port the listener is bound to once `start` has returned, else nil.
    public private(set) var boundPort: UInt16?

    /// Start listening on `127.0.0.1:port`. Pass `0` for an OS-chosen ephemeral
    /// port. Resolves with the bound port once the listener is ready; throws if
    /// the listener fails to come up.
    @discardableResult
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let portObj: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: portObj)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        let bound: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    let p = listener.port?.rawValue ?? 0
                    self?.boundPort = p
                    self?.log("listening on 127.0.0.1:\(p)")
                    cont.resume(returning: p)
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
        return bound
    }

    /// Stop the listener and tear down every in-flight relay.
    public func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        liveLock.lock()
        let pairs = live
        live.removeAll()
        liveLock.unlock()
        for p in pairs { p.cancel() }
        log("stopped")
    }

    // MARK: - Per-connection handling

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readRequestHead(on: client, buffer: Data())
    }

    /// Accumulate bytes from the client until the request head (terminated by
    /// the blank line `\r\n\r\n`) is complete, then dispatch by method.
    private func readRequestHead(on client: NWConnection, buffer: Data) {
        // Cap the head so a misbehaving client can't make us buffer forever.
        if buffer.count > 64 * 1024 {
            log("request head too large — dropping")
            client.cancel()
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }

            if let range = acc.range(of: Data("\r\n\r\n".utf8)) {
                let head = acc.subdata(in: acc.startIndex..<range.lowerBound)
                let leftover = acc.subdata(in: range.upperBound..<acc.endIndex)
                self.dispatch(head: head, leftover: leftover, client: client)
                return
            }

            if let error {
                self.log("client receive error before head complete: \(error)")
                client.cancel()
                return
            }
            if isComplete {
                client.cancel()
                return
            }
            self.readRequestHead(on: client, buffer: acc)
        }
    }

    private func dispatch(head: Data, leftover: Data, client: NWConnection) {
        guard let headText = String(data: head, encoding: .utf8),
            let requestLine = headText.split(separator: "\r\n", maxSplits: 1).first
        else {
            log("malformed request head")
            client.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            log("malformed request line: \(requestLine)")
            client.cancel()
            return
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            handleConnect(authority: target, client: client)
        } else {
            handlePlainHTTP(method: method, absoluteURI: target, head: headText, leftover: leftover, client: client)
        }
    }

    /// `CONNECT host:port` → dial upstream, ack `200`, blind-forward both ways.
    private func handleConnect(authority: String, client: NWConnection) {
        guard let (host, port) = Self.splitHostPort(authority, defaultPort: 443) else {
            log("CONNECT bad authority: \(authority)")
            client.cancel()
            return
        }
        log("CONNECT \(host):\(port)")
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let ack = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(
                    content: ack,
                    completion: .contentProcessed { _ in
                        self.relay(client: client, upstream: upstream)
                    })
            case .failed(let error), .waiting(let error):
                self.log("upstream \(host):\(port) failed: \(error)")
                let resp = Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8)
                client.send(content: resp, completion: .contentProcessed { _ in client.cancel() })
                upstream.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Absolute-form plain HTTP (`GET http://host/path HTTP/1.1`) → dial the
    /// origin, replay the head rewritten to origin-form, then relay.
    private func handlePlainHTTP(
        method: String, absoluteURI: String, head: String, leftover: Data, client: NWConnection
    ) {
        guard absoluteURI.lowercased().hasPrefix("http://"),
            let url = URL(string: absoluteURI), let host = url.host
        else {
            log("plain HTTP unsupported target: \(absoluteURI)")
            let resp = Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)
            client.send(content: resp, completion: .contentProcessed { _ in client.cancel() })
            return
        }
        let port = UInt16(url.port ?? 80)
        let originPath = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")

        // Rewrite only the request line to origin-form; keep the rest of the head verbatim.
        var lines = head.components(separatedBy: "\r\n")
        if !lines.isEmpty {
            lines[0] = "\(method) \(originPath) HTTP/1.1"
        }
        var rewritten = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        rewritten.append(leftover)

        log("HTTP \(method) \(host):\(port)\(originPath)")
        let upstream = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80, using: .tcp)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                upstream.send(
                    content: rewritten,
                    completion: .contentProcessed { _ in
                        self.relay(client: client, upstream: upstream)
                    })
            case .failed(let error), .waiting(let error):
                self.log("upstream \(host):\(port) failed: \(error)")
                client.cancel()
                upstream.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    // MARK: - Bidirectional relay

    private func relay(client: NWConnection, upstream: NWConnection) {
        let pair = RelayPair(client: client, upstream: upstream) { [weak self] pair in
            self?.liveLock.lock()
            self?.live.remove(pair)
            self?.liveLock.unlock()
        }
        liveLock.lock()
        live.insert(pair)
        liveLock.unlock()
        pair.pump(from: client, to: upstream)
        pair.pump(from: upstream, to: client)
    }

    // MARK: - Helpers

    private func log(_ msg: String) { onLog?(msg) }

    /// Split `host:port` (or bare `host`). IPv6 literals are left to the caller's
    /// targets in practice; v1 only needs hostname/IPv4 authorities.
    static func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, NWEndpoint.Port)? {
        guard let colon = s.lastIndex(of: ":") else {
            return (s, NWEndpoint.Port(rawValue: defaultPort) ?? 443)
        }
        let host = String(s[s.startIndex..<colon])
        let portStr = String(s[s.index(after: colon)...])
        guard !host.isEmpty, let portNum = UInt16(portStr), let port = NWEndpoint.Port(rawValue: portNum) else {
            return nil
        }
        return (host, port)
    }
}

/// One client↔upstream connection pair. Owns the two relay pumps and tears both
/// connections down once either side closes, signalling completion exactly once.
private final class RelayPair: Hashable {
    private let client: NWConnection
    private let upstream: NWConnection
    private let onDone: (RelayPair) -> Void
    private var finished = false
    private let lock = NSLock()

    init(client: NWConnection, upstream: NWConnection, onDone: @escaping (RelayPair) -> Void) {
        self.client = client
        self.upstream = upstream
        self.onDone = onDone
    }

    func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        if !isComplete && error == nil {
                            self.pump(from: from, to: to)
                        } else {
                            self.cancel()
                        }
                    })
            } else if isComplete || error != nil {
                self.cancel()
            } else {
                self.pump(from: from, to: to)
            }
        }
    }

    func cancel() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        client.cancel()
        upstream.cancel()
        onDone(self)
    }

    static func == (lhs: RelayPair, rhs: RelayPair) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
