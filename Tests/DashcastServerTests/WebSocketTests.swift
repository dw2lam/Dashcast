import XCTest
@testable import DashcastServer

final class WebSocketTests: XCTestCase {
    let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

    func testAcceptKeyMatchesRFC6455Example() {
        XCTAssertEqual(WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testRFCMaskedHelloExample() throws {
        // RFC 6455 §5.7: a single-frame masked text message containing "Hello".
        var parser = WebSocketFrameParser()
        parser.append([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
        let frame = try XCTUnwrap(try parser.next())
        XCTAssertTrue(frame.fin)
        XCTAssertEqual(frame.opcode, .text)
        XCTAssertEqual(String(data: frame.payload, encoding: .utf8), "Hello")
        XCTAssertNil(try parser.next())
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testServerFramesAreUnmasked() {
        let data = WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .text, payload: Data("Hello".utf8)))
        XCTAssertEqual([UInt8](data), [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F])   // RFC unmasked example
    }

    func testPayloadLengthEncodings() throws {
        for length in [0, 125, 126, 127, 1000, 65535, 65536, 200_000] {
            let payload = Data((0..<length).map { UInt8($0 & 0xFF) })
            let header = WebSocketFrameEncoder.header(opcode: .binary, payloadLength: length)
            switch length {
            case ..<126: XCTAssertEqual(header.count, 2); XCTAssertEqual(header[1], UInt8(length))
            case 126...65535: XCTAssertEqual(header.count, 4); XCTAssertEqual(header[1], 126)
            default: XCTAssertEqual(header.count, 10); XCTAssertEqual(header[1], 127)
            }
            // Round trip, masked (client → server) and unmasked (server → client).
            var masked = WebSocketFrameParser(requireMasked: true, maxPayload: 1 << 20)
            masked.append(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .binary, payload: payload), maskKey: mask))
            XCTAssertEqual(try masked.next()?.payload, payload, "masked length \(length)")
            var plain = WebSocketFrameParser(requireMasked: false, maxPayload: 1 << 20)
            plain.append(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .binary, payload: payload)))
            XCTAssertEqual(try plain.next()?.payload, payload, "unmasked length \(length)")
        }
    }

    func test16And64BitLengthsExactBytes() throws {
        let h16 = WebSocketFrameEncoder.header(opcode: .binary, payloadLength: 0x1234)
        XCTAssertEqual([UInt8](h16), [0x82, 126, 0x12, 0x34])
        let h64 = WebSocketFrameEncoder.header(opcode: .binary, payloadLength: 0x0102_0304)
        XCTAssertEqual([UInt8](h64), [0x82, 127, 0, 0, 0, 0, 0x01, 0x02, 0x03, 0x04])
        let masked = WebSocketFrameEncoder.header(opcode: .text, payloadLength: 300, maskKey: mask)
        XCTAssertEqual([UInt8](masked), [0x81, 0x80 | 126, 0x01, 0x2C] + mask)
    }

    func testIncrementalByteByByteParsing() throws {
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        let wire = [UInt8](WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .binary, payload: payload), maskKey: mask))
        var parser = WebSocketFrameParser()
        var got: WebSocketFrame?
        var i = 0
        while i < wire.count {
            let end = min(i + 997, wire.count)
            parser.append(Array(wire[i..<end]))
            if let f = try parser.next() { got = f }
            i = end
        }
        XCTAssertEqual(got?.payload, payload)
    }

    func testUnmaskedClientFrameIsProtocolError() {
        var parser = WebSocketFrameParser(requireMasked: true)
        parser.append(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .text, payload: Data("hi".utf8))))
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual(($0 as? WebSocketError)?.closeCode, 1002) }
    }

    func testControlFrameRules() {
        var parser = WebSocketFrameParser()
        parser.append(WebSocketFrameEncoder.encode(WebSocketFrame(fin: false, opcode: .ping, payload: Data()), maskKey: mask))
        XCTAssertThrowsError(try parser.next())

        var parser2 = WebSocketFrameParser()
        parser2.append(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .ping, payload: Data(count: 126)), maskKey: mask))
        XCTAssertThrowsError(try parser2.next())

        var parser3 = WebSocketFrameParser()
        parser3.append([0xC1, 0x80] + mask)   // RSV1 set
        XCTAssertThrowsError(try parser3.next())

        var parser4 = WebSocketFrameParser()
        parser4.append([0x83, 0x80] + mask)   // reserved opcode 3
        XCTAssertThrowsError(try parser4.next())
    }

    func testOversizedFrameIsMessageTooBig() {
        var parser = WebSocketFrameParser(requireMasked: true, maxPayload: 100)
        parser.append(WebSocketFrameEncoder.header(opcode: .binary, payloadLength: 101, maskKey: mask))
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual(($0 as? WebSocketError)?.closeCode, 1009) }
    }

    func testFragmentedMessageReassembledWithInterleavedPing() throws {
        let frames = [
            WebSocketFrame(fin: false, opcode: .text, payload: Data("Hel".utf8)),
            WebSocketFrame(fin: true, opcode: .ping, payload: Data("p".utf8)),
            WebSocketFrame(fin: false, opcode: .continuation, payload: Data("lo, ".utf8)),
            WebSocketFrame(fin: true, opcode: .continuation, payload: Data("wörld".utf8)),
        ]
        var parser = WebSocketFrameParser()
        for f in frames { parser.append(WebSocketFrameEncoder.encode(f, maskKey: mask)) }
        var assembler = WebSocketMessageAssembler()
        var messages: [WebSocketMessageAssembler.Message] = []
        while let f = try parser.next() { if let m = try assembler.push(f) { messages.append(m) } }
        XCTAssertEqual(messages, [.ping(Data("p".utf8)), .text("Hello, wörld")])
    }

    func testFragmentationErrors() {
        var a = WebSocketMessageAssembler()
        XCTAssertThrowsError(try a.push(WebSocketFrame(fin: true, opcode: .continuation, payload: Data())))
        var b = WebSocketMessageAssembler()
        XCTAssertNoThrow(try b.push(WebSocketFrame(fin: false, opcode: .binary, payload: Data([1]))))
        XCTAssertThrowsError(try b.push(WebSocketFrame(fin: true, opcode: .text, payload: Data("x".utf8))))
        var c = WebSocketMessageAssembler(maxMessageSize: 4)
        XCTAssertNoThrow(try c.push(WebSocketFrame(fin: false, opcode: .binary, payload: Data([1, 2, 3]))))
        XCTAssertThrowsError(try c.push(WebSocketFrame(fin: true, opcode: .continuation, payload: Data([4, 5])))) {
            XCTAssertEqual($0 as? WebSocketError, .messageTooBig)
        }
    }

    func testInvalidUTF8TextIs1007() {
        var a = WebSocketMessageAssembler()
        XCTAssertThrowsError(try a.push(WebSocketFrame(opcode: .text, payload: Data([0xC3, 0x28])))) {
            XCTAssertEqual(($0 as? WebSocketError)?.closeCode, 1007)
        }
    }

    func testClosePayloads() throws {
        XCTAssertEqual(try WebSocketMessageAssembler.parseClose(Data()), .close(code: nil, reason: ""))
        XCTAssertEqual(try WebSocketMessageAssembler.parseClose(WebSocketFrameEncoder.closePayload(code: 1000, reason: "bye")),
                       .close(code: 1000, reason: "bye"))
        XCTAssertThrowsError(try WebSocketMessageAssembler.parseClose(Data([0x03])))
        XCTAssertThrowsError(try WebSocketMessageAssembler.parseClose(WebSocketFrameEncoder.closePayload(code: 1005)))
        XCTAssertEqual(WebSocketFrameEncoder.closePayload(code: 1001, reason: String(repeating: "x", count: 300)).count, 125)
    }

    func testBinaryFramePrefixConcatenation() throws {
        let prefix = Data([1, 2, 3])
        let payload = Data(repeating: 9, count: 200)
        var parser = WebSocketFrameParser(requireMasked: false)
        parser.append(WebSocketFrameEncoder.binaryFrame(prefix: prefix, payload: payload))
        let frame = try XCTUnwrap(try parser.next())
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertEqual(frame.payload, prefix + payload)
    }

    func testHandshakeValidation() {
        func request(_ extra: String) -> HTTPRequest {
            let raw = "GET /ws HTTP/1.1\r\nHost: localhost:8080\r\n\(extra)\r\n"
            guard case .complete(let r, _) = HTTPRequestParser.parse(Array(raw.utf8)) else { fatalError() }
            return r
        }
        let good = request("Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n")
        XCTAssertEqual(WebSocketHandshake.validate(good), .success("dGhlIHNhbXBsZSBub25jZQ=="))
        let response = String(decoding: WebSocketHandshake.response(forKey: "dGhlIHNhbXBsZSBub25jZQ==").serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertFalse(response.contains("Content-Length"))

        let badVersion = request("Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n")
        XCTAssertEqual(WebSocketHandshake.validate(badVersion), .failure(.unsupportedVersion))
        let badKey = request("Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: short\r\nSec-WebSocket-Version: 13\r\n")
        guard case .failure(.badRequest) = WebSocketHandshake.validate(badKey) else { return XCTFail() }
    }
}
