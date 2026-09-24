import Foundation

// Just enough RFC 1035 / 6891 / 7766 to answer a few names locally and relay everything else.

enum DNSType {
    static let a: UInt16 = 1
    static let soa: UInt16 = 6
    static let aaaa: UInt16 = 28
    static let opt: UInt16 = 41
    static let https: UInt16 = 65
    static let any: UInt16 = 255
}

enum DNSRCode {
    static let noError: UInt8 = 0
    static let formErr: UInt8 = 1
    static let servFail: UInt8 = 2
    static let nxDomain: UInt8 = 3
}

enum DNSParseError: Error, Equatable {
    case truncated
    case badLabel
    case badPointer
    case nameTooLong
}

struct DNSQuestion: Equatable, Sendable {
    var labels: [[UInt8]]
    var type: UInt16
    var qclass: UInt16

    /// Dotted name, case preserved (DNS 0x20 randomisation must survive the round trip).
    var name: String { labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ".") }
    /// ASCII-lowercased dotted name for matching and cache keys.
    var key: String { labels.map { String(decoding: $0.map(DNSMessage.asciiLower), as: UTF8.self) }.joined(separator: ".") }
    /// Uncompressed wire encoding of the name.
    var wireName: [UInt8] { DNSMessage.encodeName(labels) }
}

struct DNSRecord: Equatable, Sendable {
    enum Section: Sendable { case answer, authority, additional }
    var section: Section
    var name: String
    var type: UInt16
    var rrclass: UInt16
    var ttl: UInt32
    /// Byte offset of the TTL field (for rewriting TTLs in cached responses).
    var ttlOffset: Int
    var rdata: Range<Int>
}

/// EDNS(0) OPT pseudo-record.
struct DNSOpt: Equatable, Sendable {
    var udpPayloadSize: UInt16
    var extendedRCode: UInt8 = 0
    var version: UInt8 = 0
    var dnssecOK: Bool = false
    var options: [UInt8] = []
}

struct DNSMessage: Sendable {
    var id: UInt16
    var flags: UInt16
    var questions: [DNSQuestion]
    /// Where each question's name sits in the message (in-place bytes, pointer included).
    var questionNameRanges: [Range<Int>]
    /// Answer, authority and additional records, excluding OPT.
    var records: [DNSRecord]
    var opt: DNSOpt?
    var size: Int

    var isResponse: Bool { flags & 0x8000 != 0 }
    var opcode: UInt8 { UInt8((flags >> 11) & 0xF) }
    var truncated: Bool { flags & 0x0200 != 0 }
    var rcode: UInt8 { UInt8(flags & 0xF) }
    var checkingDisabled: Bool { flags & 0x0010 != 0 }

    /// Largest UDP response this querier accepts.
    var maxUDPResponseSize: Int { max(512, Int(opt?.udpPayloadSize ?? 512)) }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> DNSMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw DNSParseError.truncated }
        var reader = Reader(bytes: bytes, position: 12)
        let id = reader.u16(at: 0), flags = reader.u16(at: 2)
        let qd = Int(reader.u16(at: 4)), an = Int(reader.u16(at: 6))
        let ns = Int(reader.u16(at: 8)), ar = Int(reader.u16(at: 10))

        var questions: [DNSQuestion] = []
        var ranges: [Range<Int>] = []
        for _ in 0..<qd {
            let start = reader.position
            let labels = try reader.readName()
            ranges.append(start..<reader.position)
            let type = try reader.readU16(), qclass = try reader.readU16()
            questions.append(DNSQuestion(labels: labels, type: type, qclass: qclass))
        }

        var records: [DNSRecord] = []
        var opt: DNSOpt?
        let sections: [(DNSRecord.Section, Int)] = [(.answer, an), (.authority, ns), (.additional, ar)]
        for (section, count) in sections {
            for _ in 0..<count {
                let labels = try reader.readName()
                let type = try reader.readU16(), rrclass = try reader.readU16()
                let ttlOffset = reader.position
                let ttl = try reader.readU32()
                let length = Int(try reader.readU16())
                guard reader.position + length <= bytes.count else { throw DNSParseError.truncated }
                let rdata = reader.position..<(reader.position + length)
                reader.position += length
                if type == DNSType.opt, section == .additional, labels.isEmpty {
                    opt = DNSOpt(udpPayloadSize: rrclass,
                                 extendedRCode: UInt8(ttl >> 24),
                                 version: UInt8((ttl >> 16) & 0xFF),
                                 dnssecOK: ttl & 0x8000 != 0,
                                 options: Array(bytes[rdata]))
                } else {
                    records.append(DNSRecord(section: section,
                                             name: labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "."),
                                             type: type, rrclass: rrclass, ttl: ttl, ttlOffset: ttlOffset, rdata: rdata))
                }
            }
        }
        return DNSMessage(id: id, flags: flags, questions: questions, questionNameRanges: ranges,
                          records: records, opt: opt, size: bytes.count)
    }

    struct Reader {
        let bytes: [UInt8]
        var position: Int

        func u16(at offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }

        mutating func readU16() throws -> UInt16 {
            guard position + 2 <= bytes.count else { throw DNSParseError.truncated }
            defer { position += 2 }
            return u16(at: position)
        }

        mutating func readU32() throws -> UInt32 {
            let high = try readU16(), low = try readU16()
            return UInt32(high) << 16 | UInt32(low)
        }

        /// Reads a possibly-compressed name and leaves `position` just after its in-place bytes.
        /// Every pointer must jump strictly backwards past the previous jump, so loops are impossible.
        mutating func readName() throws -> [[UInt8]] {
            var labels: [[UInt8]] = []
            var cursor = position
            var jumped = false
            var lastTarget = Int.max
            var wireLength = 1
            while true {
                guard cursor < bytes.count else { throw DNSParseError.truncated }
                let length = bytes[cursor]
                switch length & 0xC0 {
                case 0x00:
                    if length == 0 {
                        if !jumped { position = cursor + 1 }
                        return labels
                    }
                    let end = cursor + 1 + Int(length)
                    guard end <= bytes.count else { throw DNSParseError.truncated }
                    wireLength += Int(length) + 1
                    guard wireLength <= 255 else { throw DNSParseError.nameTooLong }
                    labels.append(Array(bytes[(cursor + 1)..<end]))
                    cursor = end
                case 0xC0:
                    guard cursor + 1 < bytes.count else { throw DNSParseError.truncated }
                    let target = Int(length & 0x3F) << 8 | Int(bytes[cursor + 1])
                    guard target < cursor, target < lastTarget else { throw DNSParseError.badPointer }
                    if !jumped { position = cursor + 2 }
                    jumped = true
                    lastTarget = target
                    cursor = target
                default:
                    throw DNSParseError.badLabel
                }
            }
        }
    }

    // MARK: Building

    static func asciiLower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }

    static func labels(_ name: String) -> [[UInt8]] {
        name.split(separator: ".", omittingEmptySubsequences: true).map { Array($0.utf8) }
    }

    static func encodeName(_ labels: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for label in labels {
            out.append(UInt8(min(label.count, 63)))
            out += label.prefix(63)
        }
        out.append(0)
        return out
    }

    static func query(id: UInt16, name: String, type: UInt16, recursionDesired: Bool = true, edns: DNSOpt? = nil) -> Data {
        var w = Writer()
        w.u16(id)
        w.u16(recursionDesired ? 0x0100 : 0)
        w.u16(1); w.u16(0); w.u16(0); w.u16(edns == nil ? 0 : 1)
        w.bytes += encodeName(labels(name))
        w.u16(type); w.u16(1)
        if let edns { w.opt(edns) }
        return Data(w.bytes)
    }

    struct Answer {
        var type: UInt16
        var ttl: UInt32
        var rdata: [UInt8]
    }

    /// A response to `query` echoing its (first) question. Answers point back at the question name.
    /// If the query carried EDNS, the response does too (DO bit echoed, no options).
    static func response(to query: DNSMessage, rcode: UInt8, answers: [Answer] = [],
                         authoritative: Bool = true) -> Data {
        var w = Writer()
        w.u16(query.id)
        var flags: UInt16 = 0x8000 | (query.flags & 0x7800) | (query.flags & 0x0100) | (query.flags & 0x0010) | 0x0080
        if authoritative { flags |= 0x0400 }
        flags |= UInt16(rcode & 0xF)
        w.u16(flags)
        let question = query.questions.first
        w.u16(question == nil ? 0 : 1)
        w.u16(question == nil ? 0 : UInt16(answers.count))
        w.u16(0)
        w.u16(query.opt == nil ? 0 : 1)
        if let question {
            w.bytes += question.wireName
            w.u16(question.type); w.u16(question.qclass)
            for answer in answers {
                w.bytes += [0xC0, 0x0C]
                w.u16(answer.type); w.u16(1)
                w.u32(answer.ttl)
                w.u16(UInt16(answer.rdata.count))
                w.bytes += answer.rdata
            }
        }
        if let opt = query.opt {
            w.opt(DNSOpt(udpPayloadSize: 1232, dnssecOK: opt.dnssecOK))
        }
        return Data(w.bytes)
    }

    static func serverFailure(for query: DNSMessage) -> Data {
        response(to: query, rcode: DNSRCode.servFail, authoritative: false)
    }

    /// FORMERR for bytes that didn't parse (keeps the ID when there is one). nil if not even a header.
    static func formatError(for raw: Data) -> Data? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 2 else { return nil }
        let rd = bytes.count >= 3 ? UInt16(bytes[2] & 0x01) << 8 : 0
        var w = Writer()
        w.bytes += bytes[0..<2]
        w.u16(0x8000 | rd | 0x0080 | UInt16(DNSRCode.formErr))
        w.u16(0); w.u16(0); w.u16(0); w.u16(0)
        return Data(w.bytes)
    }

    struct Writer {
        var bytes: [UInt8] = []
        mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
        mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF)) }
        mutating func opt(_ opt: DNSOpt) {
            bytes.append(0)
            u16(DNSType.opt)
            u16(opt.udpPayloadSize)
            u32(UInt32(opt.extendedRCode) << 24 | UInt32(opt.version) << 16 | (opt.dnssecOK ? 0x8000 : 0))
            u16(UInt16(opt.options.count))
            bytes += opt.options
        }
    }
}

/// DNS over TCP: every message is prefixed with its 16-bit big-endian length (RFC 1035 §4.2.2).
enum DNSTCPFraming {
    static func frame(_ message: Data) -> Data {
        var out = Data([UInt8(message.count >> 8 & 0xFF), UInt8(message.count & 0xFF)])
        out.append(message)
        return out
    }

    /// Complete messages in `buffer`, plus the unconsumed tail.
    static func split(_ buffer: Data) -> (messages: [Data], remainder: Data) {
        let bytes = [UInt8](buffer)
        var messages: [Data] = []
        var index = 0
        while bytes.count - index >= 2 {
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard bytes.count - index - 2 >= length else { break }
            if length > 0 { messages.append(Data(bytes[(index + 2)..<(index + 2 + length)])) }
            index += 2 + length
        }
        return (messages, Data(bytes[index...]))
    }
}

/// Small response cache for forwarded answers. TTLs count down; the ID and the question's letter
/// case are rewritten per querier.
struct DNSCache {
    struct Entry {
        var response: [UInt8]
        var storedAt: Date
        var expiresAt: Date
        var ttls: [(offset: Int, ttl: UInt32)]
        var nameRange: Range<Int>?
    }

    var entries: [String: Entry] = [:]
    var maxEntries = 512
    var maxTTL: UInt32 = 300
    var negativeTTL: UInt32 = 30

    static func key(for query: DNSMessage) -> String? {
        guard query.opcode == 0, query.questions.count == 1, let q = query.questions.first else { return nil }
        let edns = query.opt == nil ? "-" : (query.opt!.dnssecOK ? "do" : "e")
        return "\(q.key)|\(q.type)|\(q.qclass)|\(edns)|\(query.checkingDisabled ? "cd" : "")"
    }

    mutating func lookup(_ query: DNSMessage, now: Date) -> Data? {
        guard let key = Self.key(for: query), let entry = entries[key] else { return nil }
        let elapsed = UInt32(max(0, now.timeIntervalSince(entry.storedAt)))
        guard now < entry.expiresAt else {
            entries[key] = nil
            return nil
        }
        var bytes = entry.response
        bytes[0] = UInt8(query.id >> 8); bytes[1] = UInt8(query.id & 0xFF)
        if let range = entry.nameRange, let wire = query.questions.first?.wireName, wire.count == range.count {
            bytes.replaceSubrange(range, with: wire)
        }
        for (offset, ttl) in entry.ttls {
            let left = ttl > elapsed ? ttl - elapsed : 0
            bytes[offset] = UInt8(left >> 24); bytes[offset + 1] = UInt8(left >> 16 & 0xFF)
            bytes[offset + 2] = UInt8(left >> 8 & 0xFF); bytes[offset + 3] = UInt8(left & 0xFF)
        }
        return Data(bytes)
    }

    mutating func store(_ response: Data, for query: DNSMessage, now: Date) {
        guard let key = Self.key(for: query),
              let parsed = try? DNSMessage.parse(response),
              !parsed.truncated,
              parsed.rcode == DNSRCode.noError || parsed.rcode == DNSRCode.nxDomain else { return }
        let bytes = [UInt8](response)
        let scored = parsed.records.filter { $0.section != .additional }
        var ttl: UInt32
        if parsed.records.contains(where: { $0.section == .answer }) {
            ttl = scored.map(\.ttl).min() ?? 0
        } else if let soa = scored.first(where: { $0.type == DNSType.soa }), soa.rdata.count >= 4 {
            let tail = Array(bytes[(soa.rdata.upperBound - 4)..<soa.rdata.upperBound])
            let minimum = UInt32(tail[0]) << 24 | UInt32(tail[1]) << 16 | UInt32(tail[2]) << 8 | UInt32(tail[3])
            ttl = min(soa.ttl, minimum)
        } else {
            ttl = negativeTTL
        }
        ttl = min(ttl, maxTTL)
        guard ttl > 0 else { return }
        if entries.count >= maxEntries {
            entries = entries.filter { $0.value.expiresAt > now }
            if entries.count >= maxEntries, let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
                entries[oldest] = nil
            }
        }
        entries[key] = Entry(response: bytes, storedAt: now, expiresAt: now.addingTimeInterval(TimeInterval(ttl)),
                             ttls: parsed.records.map { ($0.ttlOffset, $0.ttl) },
                             nameRange: parsed.questionNameRanges.first)
    }
}
