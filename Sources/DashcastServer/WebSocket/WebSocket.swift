import CryptoKit
import Foundation

// RFC 6455 framing. Server → client frames are unmasked; client → server frames must be masked.

enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool { rawValue & 0x8 != 0 }
}

struct WebSocketFrame: Equatable {
    var fin: Bool
    var opcode: WebSocketOpcode
    var payload: Data

    init(fin: Bool = true, opcode: WebSocketOpcode, payload: Data = Data()) {
        self.fin = fin; self.opcode = opcode; self.payload = payload
    }
}

enum WebSocketError: Error, Equatable {
    case protocolError(String)
    case messageTooBig
    case invalidUTF8

    /// Close status code to send (RFC 6455 §7.4.1).
    var closeCode: UInt16 {
        switch self {
        case .protocolError: return WebSocketCloseCode.protocolError
        case .messageTooBig: return WebSocketCloseCode.messageTooBig
        case .invalidUTF8: return WebSocketCloseCode.invalidPayload
        }
    }
}

enum WebSocketCloseCode {
    static let normal: UInt16 = 1000
    static let goingAway: UInt16 = 1001
    static let protocolError: UInt16 = 1002
    static let invalidPayload: UInt16 = 1007
    static let policyViolation: UInt16 = 1008
    static let messageTooBig: UInt16 = 1009
    static let internalError: UInt16 = 1011

    /// Codes a peer may legitimately put on the wire.
    static func isValidOnWire(_ code: UInt16) -> Bool {
        switch code {
        case 1000...1003, 1007...1014: return true
        case 3000...4999: return true
        default: return false
        }
    }
}

enum WebSocketFrameEncoder {
    /// Frame header for a payload of `length` bytes. Server frames pass `maskKey: nil`.
    static func header(opcode: WebSocketOpcode, fin: Bool = true, payloadLength length: Int, maskKey: [UInt8]? = nil) -> Data {
        var header = Data(capacity: 14)
        header.append((fin ? 0x80 : 0x00) | opcode.rawValue)
        let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
        if length < 126 {
            header.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            header.append(maskBit | 126)
            header.append(UInt8(length >> 8))
            header.append(UInt8(length & 0xFF))
        } else {
            header.append(maskBit | 127)
            let len = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((len >> UInt64(shift)) & 0xFF)) }
        }
        if let maskKey {
            precondition(maskKey.count == 4)
            header.append(contentsOf: maskKey)
        }
        return header
    }

    static func encode(_ frame: WebSocketFrame, maskKey: [UInt8]? = nil) -> Data {
        var data = header(opcode: frame.opcode, fin: frame.fin, payloadLength: frame.payload.count, maskKey: maskKey)
        if let maskKey {
            var masked = [UInt8](frame.payload)
            for i in masked.indices { masked[i] ^= maskKey[i & 3] }
            data.append(contentsOf: masked)
        } else {
            data.append(frame.payload)
        }
        return data
    }

    /// Unmasked binary frame whose payload is `prefix` followed by `payload`, built with a single
    /// allocation (used for media: 16-byte media header + encoded frame).
    static func binaryFrame(prefix: Data, payload: Data) -> Data {
        let length = prefix.count + payload.count
        var data = header(opcode: .binary, payloadLength: length)
        data.reserveCapacity(data.count + length)
        data.append(prefix)
        data.append(payload)
        return data
    }

    static func closePayload(code: UInt16?, reason: String = "") -> Data {
        guard let code else { return Data() }
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        // Control frame payloads are capped at 125 bytes.
        var reasonBytes = Array(reason.utf8)
        if reasonBytes.count > 123 { reasonBytes = Array(reasonBytes.prefix(123)) }
        payload.append(contentsOf: reasonBytes)
        return payload
    }
}

/// Incremental frame decoder. Feed bytes with `append`, then drain frames with `next()`.
struct WebSocketFrameParser {
    var requireMasked: Bool
    var maxPayload: Int

    private var buffer: [UInt8] = []
    private var offset = 0

    init(requireMasked: Bool = true, maxPayload: Int = 1 << 20) {
        self.requireMasked = requireMasked
        self.maxPayload = maxPayload
    }

    var bufferedByteCount: Int { buffer.count - offset }

    mutating func append(_ data: Data) { compactIfNeeded(); buffer.append(contentsOf: data) }
    mutating func append(_ bytes: [UInt8]) { compactIfNeeded(); buffer.append(contentsOf: bytes) }

    private mutating func compactIfNeeded() {
        if offset > 0 && (offset >= buffer.count || offset > 64 * 1024) {
            buffer.removeFirst(offset)
            offset = 0
        }
    }

    mutating func next() throws -> WebSocketFrame? {
        let available = buffer.count - offset
        guard available >= 2 else { return nil }
        let b0 = buffer[offset], b1 = buffer[offset + 1]
        let fin = b0 & 0x80 != 0
        guard b0 & 0x70 == 0 else { throw WebSocketError.protocolError("reserved bits set") }
        guard let opcode = WebSocketOpcode(rawValue: b0 & 0x0F) else {
            throw WebSocketError.protocolError("unknown opcode \(b0 & 0x0F)")
        }
        let masked = b1 & 0x80 != 0
        if requireMasked && !masked { throw WebSocketError.protocolError("client frame not masked") }

        var headerLength = 2
        var length = UInt64(b1 & 0x7F)
        if length == 126 {
            guard available >= 4 else { return nil }
            length = UInt64(buffer[offset + 2]) << 8 | UInt64(buffer[offset + 3])
            headerLength = 4
        } else if length == 127 {
            guard available >= 10 else { return nil }
            length = 0
            for i in 0..<8 { length = length << 8 | UInt64(buffer[offset + 2 + i]) }
            guard length & (1 << 63) == 0 else { throw WebSocketError.protocolError("64-bit length MSB set") }
            headerLength = 10
        }
        if opcode.isControl {
            guard fin else { throw WebSocketError.protocolError("fragmented control frame") }
            guard length <= 125 else { throw WebSocketError.protocolError("control frame too long") }
        }
        guard length <= UInt64(maxPayload) else { throw WebSocketError.messageTooBig }

        var maskKey: (UInt8, UInt8, UInt8, UInt8)?
        if masked {
            guard available >= headerLength + 4 else { return nil }
            let m = offset + headerLength
            maskKey = (buffer[m], buffer[m + 1], buffer[m + 2], buffer[m + 3])
            headerLength += 4
        }
        let total = headerLength + Int(length)
        guard available >= total else { return nil }

        let start = offset + headerLength
        var payload = [UInt8](buffer[start..<(start + Int(length))])
        if let (k0, k1, k2, k3) = maskKey {
            let key = [k0, k1, k2, k3]
            for i in payload.indices { payload[i] ^= key[i & 3] }
        }
        offset += total
        return WebSocketFrame(fin: fin, opcode: opcode, payload: Data(payload))
    }
}

/// Reassembles fragmented data messages; control frames pass straight through.
struct WebSocketMessageAssembler {
    enum Message: Equatable {
        case text(String)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        case close(code: UInt16?, reason: String)
    }

    var maxMessageSize: Int
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments = Data()

    init(maxMessageSize: Int = 1 << 20) { self.maxMessageSize = maxMessageSize }

    mutating func push(_ frame: WebSocketFrame) throws -> Message? {
        switch frame.opcode {
        case .ping: return .ping(frame.payload)
        case .pong: return .pong(frame.payload)
        case .close: return try Self.parseClose(frame.payload)
        case .text, .binary:
            guard fragmentOpcode == nil else { throw WebSocketError.protocolError("new message inside a fragmented one") }
            if frame.fin { return try Self.finish(opcode: frame.opcode, payload: frame.payload) }
            guard frame.payload.count <= maxMessageSize else { throw WebSocketError.messageTooBig }
            fragmentOpcode = frame.opcode
            fragments = frame.payload
            return nil
        case .continuation:
            guard let opcode = fragmentOpcode else { throw WebSocketError.protocolError("continuation without a start frame") }
            guard fragments.count + frame.payload.count <= maxMessageSize else { throw WebSocketError.messageTooBig }
            fragments.append(frame.payload)
            guard frame.fin else { return nil }
            let payload = fragments
            fragmentOpcode = nil
            fragments = Data()
            return try Self.finish(opcode: opcode, payload: payload)
        }
    }

    private static func finish(opcode: WebSocketOpcode, payload: Data) throws -> Message {
        if opcode == .text {
            guard let text = String(data: payload, encoding: .utf8) else { throw WebSocketError.invalidUTF8 }
            return .text(text)
        }
        return .binary(payload)
    }

    static func parseClose(_ payload: Data) throws -> Message {
        if payload.isEmpty { return .close(code: nil, reason: "") }
        guard payload.count >= 2 else { throw WebSocketError.protocolError("1-byte close payload") }
        let bytes = [UInt8](payload)
        let code = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard WebSocketCloseCode.isValidOnWire(code) else { throw WebSocketError.protocolError("invalid close code \(code)") }
        guard let reason = String(bytes: bytes[2...], encoding: .utf8) else { throw WebSocketError.invalidUTF8 }
        return .close(code: code, reason: reason)
    }
}

enum WebSocketHandshake {
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` = base64(SHA-1(key + GUID)).
    static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    enum Failure: Error, Equatable {
        case badRequest(String)
        case unsupportedVersion
    }

    /// Validates an upgrade request and returns the client key.
    static func validate(_ request: HTTPRequest) -> Result<String, Failure> {
        guard request.method == "GET" else { return .failure(.badRequest("method must be GET")) }
        guard request.version == "HTTP/1.1" else { return .failure(.badRequest("HTTP/1.1 required")) }
        guard request.isWebSocketUpgrade else { return .failure(.badRequest("missing Upgrade/Connection headers")) }
        guard request.headers["Sec-WebSocket-Version"]?.trimmingCharacters(in: .whitespaces) == "13" else {
            return .failure(.unsupportedVersion)
        }
        guard let key = request.headers["Sec-WebSocket-Key"]?.trimmingCharacters(in: .whitespaces),
              let raw = Data(base64Encoded: key), raw.count == 16 else {
            return .failure(.badRequest("invalid Sec-WebSocket-Key"))
        }
        return .success(key)
    }

    static func response(forKey key: String) -> HTTPResponse {
        HTTPResponse(status: 101, headers: [
            ("Upgrade", "websocket"),
            ("Connection", "Upgrade"),
            ("Sec-WebSocket-Accept", acceptKey(for: key)),
        ])
    }
}
