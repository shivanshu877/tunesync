import Foundation
import Network
import CommonCrypto

public protocol BridgeDelegate: AnyObject, Sendable {
    /// Called on the bridge's queue when a web client sends a SyncMessage.
    func bridge(_ bridge: Bridge, didReceive message: SyncMessage, fromClient id: String)
    /// Called when web client count changes.
    func bridge(_ bridge: Bridge, clientsChanged count: Int)
}

public final class Bridge: @unchecked Sendable {
    public weak var delegate: BridgeDelegate?
    public let port: UInt16
    public let room: String

    private let queue = DispatchQueue(label: "com.tunesync.bridge")
    private var listener: NWListener?
    private var clients: [String: NWConnection] = [:]
    private var nextClientNum = 0

    public init(port: UInt16 = 8732, room: String) {
        self.port = port
        self.room = room
    }

    public func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNew(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in clients { c.cancel() }
        clients.removeAll()
        notifyClientsChanged()
    }

    public var clientCount: Int {
        return queue.sync { clients.count }
    }

    public func broadcastToClients(_ message: SyncMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        queue.async { [self] in
            for (_, c) in clients {
                sendWebSocketText(c, data: data)
            }
        }
    }

    private func handleNew(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, accumulated: Data())
    }

    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buffer = accumulated
            if let d = data { buffer.append(d) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = buffer.prefix(upTo: range.lowerBound)
                self.routeRequest(conn, headerBytes: Data(header))
            } else if buffer.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.readRequest(conn, accumulated: buffer)
            }
        }
    }

    private func routeRequest(_ conn: NWConnection, headerBytes: Data) {
        guard let header = String(data: headerBytes, encoding: .utf8) else {
            conn.cancel(); return
        }
        let lines = header.split(separator: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let path = String(parts[1])

        if path == "/ws" {
            handleWebSocketUpgrade(conn, headerLines: lines)
            return
        }

        if let body = BridgeAssets.body(for: path) {
            let mime = BridgeAssets.mimeType(for: path == "/" ? "/index.html" : path)
            let response =
                "HTTP/1.1 200 OK\r\n" +
                "Content-Type: \(mime)\r\n" +
                "Content-Length: \(body.count)\r\n" +
                "Cache-Control: no-store\r\n" +
                "Connection: close\r\n\r\n"
            var full = Data(response.utf8)
            full.append(body)
            conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
        } else {
            let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func handleWebSocketUpgrade(_ conn: NWConnection, headerLines: [Substring]) {
        var key: String? = nil
        for line in headerLines {
            let lower = line.lowercased()
            if lower.hasPrefix("sec-websocket-key:") {
                let v = line.split(separator: ":", maxSplits: 1).last ?? ""
                key = v.trimmingCharacters(in: .whitespaces)
            }
        }
        guard let secKey = key else { conn.cancel(); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = sha1Base64(secKey + magic)
        let upgrade =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(upgrade.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let id = "web-\(self.nextClientNum)"
            self.nextClientNum += 1
            self.clients[id] = conn
            self.notifyClientsChanged()
            self.sendWelcome(conn)
            self.readWSFrame(conn, clientId: id)
        })
    }

    private func sendWelcome(_ conn: NWConnection) {
        struct Welcome: Encodable { let kind = "welcome"; let room: String }
        if let data = try? JSONEncoder().encode(Welcome(room: room)) {
            sendWebSocketText(conn, data: data)
        }
    }

    private func readWSFrame(_ conn: NWConnection, clientId: String) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.removeClient(clientId, conn: conn)
                return
            }
            guard let buf = data, buf.count >= 2 else {
                self.readWSFrame(conn, clientId: clientId); return
            }
            let opcode = buf[0] & 0x0F
            let masked = (buf[1] & 0x80) != 0
            var len = Int(buf[1] & 0x7F)
            var idx = 2
            if len == 126 {
                guard buf.count >= 4 else { self.readWSFrame(conn, clientId: clientId); return }
                len = Int(buf[2]) << 8 | Int(buf[3])
                idx = 4
            } else if len == 127 {
                guard buf.count >= 10 else { self.readWSFrame(conn, clientId: clientId); return }
                len = 0
                for k in 2..<10 { len = (len << 8) | Int(buf[k]) }
                idx = 10
            }
            var maskKey: [UInt8] = [0,0,0,0]
            if masked {
                guard buf.count >= idx + 4 else { self.readWSFrame(conn, clientId: clientId); return }
                maskKey = [buf[idx], buf[idx+1], buf[idx+2], buf[idx+3]]
                idx += 4
            }
            guard buf.count >= idx + len else { self.readWSFrame(conn, clientId: clientId); return }
            var payload = Data(buf[idx..<(idx+len)])
            if masked {
                for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            }
            if opcode == 0x8 {
                self.removeClient(clientId, conn: conn)
                return
            }
            if opcode == 0x9 {
                self.sendWebSocketPong(conn, data: payload)
            } else if opcode == 0x1 {
                self.handleClientPayload(payload, clientId: clientId)
            }
            self.readWSFrame(conn, clientId: clientId)
        }
    }

    private func handleClientPayload(_ data: Data, clientId: String) {
        guard let msg = try? JSONDecoder().decode(SyncMessage.self, from: data) else { return }
        delegate?.bridge(self, didReceive: msg, fromClient: clientId)
    }

    private func removeClient(_ id: String, conn: NWConnection) {
        clients.removeValue(forKey: id)
        conn.cancel()
        notifyClientsChanged()
    }

    private func notifyClientsChanged() {
        let count = clients.count
        delegate?.bridge(self, clientsChanged: count)
    }

    private func sendWebSocketText(_ conn: NWConnection, data: Data) {
        var frame = Data()
        frame.append(0x81)
        let len = data.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        frame.append(data)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendWebSocketPong(_ conn: NWConnection, data: Data) {
        var frame = Data()
        frame.append(0x8A)
        frame.append(UInt8(data.count))
        frame.append(data)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sha1Base64(_ s: String) -> String {
        let data = Data(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}
