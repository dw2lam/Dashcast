import XCTest
@testable import DashcastNetwork

final class DNSMessageTests: XCTestCase {
    private func hex(_ string: String) -> Data {
        let clean = string.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            bytes.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    func testQueryRoundTripWithEDNS() throws {
        let raw = DNSMessage.query(id: 0xBEEF, name: "Car.DavidLam.online", type: DNSType.a,
                                   edns: DNSOpt(udpPayloadSize: 4096, dnssecOK: true, options: [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]))
        let query = try DNSMessage.parse(raw)
        XCTAssertEqual(query.id, 0xBEEF)
        XCTAssertFalse(query.isResponse)
        XCTAssertEqual(query.flags & 0x0100, 0x0100)
        XCTAssertEqual(query.questions.count, 1)
        XCTAssertEqual(query.questions[0].name, "Car.DavidLam.online", "case preserved")
        XCTAssertEqual(query.questions[0].key, "car.davidlam.online")
        XCTAssertEqual(query.questions[0].type, DNSType.a)
        XCTAssertEqual(query.opt, DNSOpt(udpPayloadSize: 4096, dnssecOK: true, options: [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(query.maxUDPResponseSize, 4096)
        XCTAssertTrue(query.records.isEmpty, "OPT isn't an ordinary record")
    }

    func testLocalAnswerEncoding() throws {
        let query = try DNSMessage.parse(DNSMessage.query(id: 7, name: "cAr.davidlam.ONLINE", type: DNSType.a,
                                                          edns: DNSOpt(udpPayloadSize: 1232, dnssecOK: true)))
        let data = DNSMessage.response(to: query, rcode: DNSRCode.noError,
                                       answers: [.init(type: DNSType.a, ttl: 60, rdata: [203, 0, 113, 77])])
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes[0..<12]), [0, 7, 0x85, 0x80, 0, 1, 0, 1, 0, 0, 0, 1],
                       "id 7; QR AA RD RA; 1 question, 1 answer, 1 additional (OPT)")
        let parsed = try DNSMessage.parse(data)
        XCTAssertEqual(parsed.questions[0].name, "cAr.davidlam.ONLINE")
        XCTAssertEqual(parsed.records.count, 1)
        let answer = parsed.records[0]
        XCTAssertEqual(answer.name, "cAr.davidlam.ONLINE", "compression pointer to the question")
        XCTAssertEqual(answer.type, DNSType.a)
        XCTAssertEqual(answer.ttl, 60)
        XCTAssertEqual(Array(bytes[answer.rdata]), [203, 0, 113, 77])
        XCTAssertEqual(Array(bytes[(answer.ttlOffset - 6)..<(answer.ttlOffset - 4)]), [0xC0, 0x0C])
        XCTAssertEqual(parsed.opt?.dnssecOK, true, "DO bit echoed")
        XCTAssertEqual(parsed.opt?.udpPayloadSize, 1232)
        XCTAssertEqual(parsed.opt?.options, [], "no options echoed")
    }

    func testNoEDNSInNoEDNSOut() throws {
        let query = try DNSMessage.parse(DNSMessage.query(id: 1, name: "x.test", type: DNSType.aaaa))
        let parsed = try DNSMessage.parse(DNSMessage.response(to: query, rcode: DNSRCode.noError))
        XCTAssertNil(parsed.opt)
        XCTAssertEqual(parsed.rcode, 0)
        XCTAssertTrue(parsed.records.isEmpty)
    }

    /// A real-shaped response (apple.com A) with compression pointers in answers and authority.
    func testParsesCompressedResponse() throws {
        let data = hex("""
        1234 8180 0001 0002 0001 0001
        05 6170706c65 03 636f6d 00 0001 0001
        c00c 0001 0001 0000012c 0004 11fdb72e
        c00c 0001 0001 0000003c 0004 11fdb72f
        c00c 0002 0001 00000e10 0006 036e7331 c00c
        00 0029 04d0 00008000 0000
        """)
        let message = try DNSMessage.parse(data)
        XCTAssertTrue(message.isResponse)
        XCTAssertEqual(message.questions[0].name, "apple.com")
        XCTAssertEqual(message.records.map(\.name), ["apple.com", "apple.com", "apple.com"])
        XCTAssertEqual(message.records.map(\.ttl), [300, 60, 3600])
        XCTAssertEqual(message.records.map(\.section), [.answer, .answer, .authority])
        XCTAssertEqual(message.opt?.udpPayloadSize, 1232)
        XCTAssertEqual(message.opt?.dnssecOK, true)

        // The NS rdata "ns1" + pointer decodes through the pointer.
        var reader = DNSMessage.Reader(bytes: [UInt8](data), position: message.records[2].rdata.lowerBound)
        XCTAssertEqual(try reader.readName().map { String(decoding: $0, as: UTF8.self) }, ["ns1", "apple", "com"])
        XCTAssertEqual(reader.position, message.records[2].rdata.upperBound)
    }

    func testRejectsPointerLoopsAndTruncation() {
        // Pointer to itself.
        XCTAssertThrowsError(try DNSMessage.parse(hex("0001 0100 0001 0000 0000 0000 c00c 0001 0001"))) {
            XCTAssertEqual($0 as? DNSParseError, .badPointer)
        }
        // Two names pointing at each other: 12 → "a" + ptr(17); 17 → "b" + ptr(12).
        XCTAssertThrowsError(try DNSMessage.parse(hex("0001 0100 0001 0000 0000 0000 0161 c011 0001 0001 0162 c00c")))
        // Label runs past the end.
        XCTAssertThrowsError(try DNSMessage.parse(hex("0001 0100 0001 0000 0000 0000 0561 62"))) {
            XCTAssertEqual($0 as? DNSParseError, .truncated)
        }
        XCTAssertThrowsError(try DNSMessage.parse(Data([0, 1, 2])))
        // Extended label types (0x40/0x80) aren't valid.
        XCTAssertThrowsError(try DNSMessage.parse(hex("0001 0100 0001 0000 0000 0000 41 00 0001 0001"))) {
            XCTAssertEqual($0 as? DNSParseError, .badLabel)
        }
    }

    func testFormatErrorAndServfail() throws {
        let formErr = try XCTUnwrap(DNSMessage.formatError(for: Data([0xAB, 0xCD, 0x01, 0x00, 0xFF])))
        XCTAssertEqual([UInt8](formErr), [0xAB, 0xCD, 0x81, 0x81, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(DNSMessage.formatError(for: Data([1])))

        let query = try DNSMessage.parse(DNSMessage.query(id: 9, name: "example.com", type: DNSType.a))
        let servfail = try DNSMessage.parse(DNSMessage.serverFailure(for: query))
        XCTAssertEqual(servfail.id, 9)
        XCTAssertEqual(servfail.rcode, DNSRCode.servFail)
        XCTAssertEqual(servfail.flags & 0x0400, 0, "not authoritative")
        XCTAssertEqual(servfail.questions.first?.key, "example.com")
    }

    func testTCPFraming() {
        let a = Data([1, 2, 3]), b = Data(repeating: 7, count: 300)
        let stream = DNSTCPFraming.frame(a) + DNSTCPFraming.frame(b)
        XCTAssertEqual([UInt8](DNSTCPFraming.frame(b).prefix(2)), [0x01, 0x2C])

        let whole = DNSTCPFraming.split(stream)
        XCTAssertEqual(whole.messages, [a, b])
        XCTAssertTrue(whole.remainder.isEmpty)

        // Arriving in awkward pieces: split mid-length-prefix and mid-body.
        var buffer = Data()
        var received: [Data] = []
        for chunk in [stream.prefix(1), stream.dropFirst(1).prefix(5), stream.dropFirst(6).prefix(100), stream.dropFirst(106)] {
            buffer.append(Data(chunk))
            let (messages, rest) = DNSTCPFraming.split(buffer)
            received += messages
            buffer = rest
        }
        XCTAssertEqual(received, [a, b])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCacheRewritesIDCaseAndTTL() throws {
        var cache = DNSCache()
        let t0 = Date()
        let query = try DNSMessage.parse(DNSMessage.query(id: 1, name: "apple.com", type: DNSType.a))
        let response = hex("""
        0001 8180 0001 0001 0000 0000
        05 6170706c65 03 636f6d 00 0001 0001
        c00c 0001 0001 0000012c 0004 11fdb72e
        """)
        cache.store(response, for: query, now: t0)

        let again = try DNSMessage.parse(DNSMessage.query(id: 0x4242, name: "ApPlE.cOm", type: DNSType.a))
        let hit = try XCTUnwrap(cache.lookup(again, now: t0.addingTimeInterval(100)))
        let parsed = try DNSMessage.parse(hit)
        XCTAssertEqual(parsed.id, 0x4242)
        XCTAssertEqual(parsed.questions[0].name, "ApPlE.cOm", "0x20 case echoed back")
        XCTAssertEqual(parsed.records[0].ttl, 200)
        XCTAssertNil(cache.lookup(again, now: t0.addingTimeInterval(301)), "expired")

        // A different type, or an EDNS query, is a different cache entry.
        XCTAssertNil(cache.lookup(try DNSMessage.parse(DNSMessage.query(id: 1, name: "apple.com", type: DNSType.aaaa)), now: t0))
        XCTAssertNil(cache.lookup(try DNSMessage.parse(DNSMessage.query(id: 1, name: "apple.com", type: DNSType.a,
                                                                        edns: DNSOpt(udpPayloadSize: 1232))), now: t0))
    }

    func testCacheSkipsServfailTruncatedAndZeroTTL() throws {
        var cache = DNSCache()
        let query = try DNSMessage.parse(DNSMessage.query(id: 1, name: "x.test", type: DNSType.a))
        cache.store(DNSMessage.serverFailure(for: query), for: query, now: Date())
        var truncated = [UInt8](DNSMessage.response(to: query, rcode: 0, answers: [.init(type: 1, ttl: 60, rdata: [1, 2, 3, 4])]))
        truncated[2] |= 0x02
        cache.store(Data(truncated), for: query, now: Date())
        cache.store(DNSMessage.response(to: query, rcode: 0, answers: [.init(type: 1, ttl: 0, rdata: [1, 2, 3, 4])]), for: query, now: Date())
        XCTAssertTrue(cache.entries.isEmpty)

        // NXDOMAIN with an SOA: cached for min(SOA TTL, SOA minimum).
        let nx = hex("""
        0001 8183 0001 0000 0001 0000
        01 78 04 74657374 00 0001 0001
        c00e 0006 0001 00000e10 0016 00 00 00000001 00000002 00000003 00000004 0000002a
        """)
        cache.store(nx, for: query, now: Date())
        XCTAssertEqual(cache.entries.values.first.map { $0.expiresAt.timeIntervalSince($0.storedAt) }, 42)
    }

    func testSystemResolverFiltering() {
        XCTAssertEqual(SystemResolvers.filter(["127.0.0.1", "100.100.100.100", svc, "::1", "fd7a:115c:a1e0::53", "100.100.100.100"],
                                              excluding: [svc]),
                       ["100.100.100.100", "fd7a:115c:a1e0::53"])
        XCTAssertEqual(SystemResolvers.filter(["127.0.0.53"], excluding: []), ["1.1.1.1"])
        XCTAssertEqual(SystemResolvers.filter([], excluding: []), ["1.1.1.1"])
    }
}
