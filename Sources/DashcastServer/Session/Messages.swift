import DashcastContracts
import Foundation

// JSON text messages (PROTOCOL.md). Client messages are parsed leniently: a slightly different
// client build shouldn't be able to wedge the session.

/// A JSON scalar echoed back verbatim (ping `id`).
enum JSONScalar: Equatable {
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)
    case null

    init(_ any: Any?) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 9e15 { self = .int(Int64(d)) } else { self = .double(d) }
        case let s as String: self = .string(s)
        default: self = .null
        }
    }

    var json: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let v): return JSON.number(v)
        case .string(let s): return JSON.string(s)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}

enum JSON {
    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Shortest round-trip representation; integral values without a fraction.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d.rounded() == d, abs(d) < 9e15 { return String(Int64(d)) }
        return "\(d)"
    }
}

struct AckMessage: Equatable {
    var seq: UInt32
    /// Client receive time converted to server µs.
    var recvAt: Double
    var decodeMs: Double?
    var presented: Bool?
}

enum ClientMessage {
    case hello(ClientHello, TransportCaps)
    case ping(id: JSONScalar, clientTime: JSONScalar)
    case ack(AckMessage)
    case stats(ClientStats)
    case input(InputEvent)
    case keyframe
    case setLatencyMode(LatencyMode)
    case rtcAnswer(type: String, sdp: String)
    case unknown(String)

    static func parse(_ text: String) -> ClientMessage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let t = dict["t"] as? String else { return nil }
        switch t {
        case "hello":
            guard let hello = parseHello(dict) else { return nil }
            let caps = dict["caps"] as? [String: Any] ?? [:]
            return .hello(hello, TransportCaps(secure: caps["secure"] as? Bool, webrtc: caps["webrtc"] as? Bool))
        case "ping":
            return .ping(id: JSONScalar(dict["id"]), clientTime: JSONScalar(dict["clientTime"]))
        case "ack":
            guard let seq = number(dict["seq"]), seq >= 0, seq <= Double(UInt32.max),
                  let recvAt = number(dict["recvAt"]) else { return nil }
            return .ack(AckMessage(seq: UInt32(seq), recvAt: recvAt, decodeMs: number(dict["decodeMs"]),
                                   presented: dict["presented"] as? Bool))
        case "stats":
            return parseStats(dict).map(ClientMessage.stats)
        case "input":
            return parseInput(dict).map(ClientMessage.input)
        case "keyframe":
            return .keyframe
        case "setLatencyMode":
            guard let raw = dict["latencyMode"] as? String, let mode = LatencyMode(rawValue: raw) else { return nil }
            return .setLatencyMode(mode)
        case "rtcAnswer":
            guard let sdp = dict["sdp"] as? String, !sdp.isEmpty else { return nil }
            return .rtcAnswer(type: dict["type"] as? String ?? "answer", sdp: sdp)
        default:
            return .unknown(t)
        }
    }

    static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func parseHello(_ dict: [String: Any]) -> ClientHello? {
        // Normalize into the exact shape of the Contracts types (no public memberwise inits there),
        // filling conservative defaults for anything missing.
        let viewportIn = dict["viewport"] as? [String: Any] ?? [:]
        let capsIn = dict["caps"] as? [String: Any] ?? [:]
        let h264In = capsIn["h264"] as? [String: Any] ?? [:]
        var caps: [String: Any] = [
            "webcodecs": capsIn["webcodecs"] as? Bool ?? false,
            "h264": [
                "high": h264In["high"] as? Bool ?? false,
                "main": h264In["main"] as? Bool ?? false,
                "baseline": h264In["baseline"] as? Bool ?? false,
            ],
            "hevc": capsIn["hevc"] as? Bool ?? false,
            "audioWorklet": capsIn["audioWorklet"] as? Bool ?? false,
        ]
        caps["secure"] = capsIn["secure"] as? Bool ?? false
        caps["webrtc"] = capsIn["webrtc"] as? Bool ?? false
        if let hw = capsIn["hwAccel"] as? String { caps["hwAccel"] = hw }
        if let v = capsIn["offscreenCanvas"] as? Bool { caps["offscreenCanvas"] = v }
        if let v = capsIn["webgl"] as? Bool { caps["webgl"] = v }

        var normalized: [String: Any] = [
            "version": Int(number(dict["version"]) ?? 1),
            "ua": dict["ua"] as? String ?? "",
            "viewport": [
                "w": number(viewportIn["w"]) ?? 1280,
                "h": number(viewportIn["h"]) ?? 720,
                "dpr": number(viewportIn["dpr"]) ?? 1,
            ],
            "caps": caps,
        ]
        if let benchIn = dict["bench"] as? [String: Any] {
            var bench: [String: Any] = [:]
            for key in ["h264_720p_decodeMs", "h264_1080p_decodeMs", "jpegDecodeMs"] {
                if let v = number(benchIn[key]), v >= 0 { bench[key] = v }
            }
            normalized["bench"] = bench
        }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized) else { return nil }
        return try? JSONDecoder().decode(ClientHello.self, from: data)
    }

    static func parseStats(_ dict: [String: Any]) -> ClientStats? {
        var normalized: [String: Any] = [
            "fps": number(dict["fps"]) ?? 0,
            "decodeMs": number(dict["decodeMs"]) ?? 0,
            "dropped": Int(number(dict["dropped"]) ?? 0),
            "queue": Int(number(dict["queue"]) ?? 0),
        ]
        if let v = number(dict["latencyMs"]) { normalized["latencyMs"] = v }
        if let v = number(dict["audioBufferMs"]) { normalized["audioBufferMs"] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized) else { return nil }
        return try? JSONDecoder().decode(ClientStats.self, from: data)
    }

    static func parseInput(_ dict: [String: Any]) -> InputEvent? {
        guard let raw = dict["kind"] as? String, let kind = InputEvent.Kind(rawValue: raw) else { return nil }
        let clamp: (Double?) -> Double = { min(max($0 ?? 0, 0), 1) }
        return InputEvent(kind: kind, x: clamp(number(dict["x"])), y: clamp(number(dict["y"])),
                          dx: number(dict["dx"]), dy: number(dict["dy"]),
                          text: dict["text"] as? String, key: dict["key"] as? String)
    }
}

enum ServerMessage {
    struct Config: Equatable {
        var transport: MediaTransport
        var codecString: String
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
        var tierID: String
        var latencyMode: LatencyMode
        var audio: Bool
        var inputEnabled: Bool
        var serverTime: UInt64
    }

    static func config(_ c: Config) -> String {
        let audio = c.audio ? "{\"sampleRate\":48000,\"channels\":2}" : "null"
        return "{\"t\":\"config\",\"transport\":\(JSON.string(c.transport.rawValue)),\"codec\":\(JSON.string(c.codecString)),\"width\":\(c.width),\"height\":\(c.height)"
            + ",\"fps\":\(c.fps),\"bitrateKbps\":\(c.bitrateKbps),\"tier\":\(JSON.string(c.tierID))"
            + ",\"latencyMode\":\(JSON.string(c.latencyMode.rawValue)),\"audio\":\(audio)"
            + ",\"inputEnabled\":\(c.inputEnabled),\"serverTime\":\(c.serverTime)}"
    }

    static func pong(id: JSONScalar, clientTime: JSONScalar, serverTime: UInt64) -> String {
        "{\"t\":\"pong\",\"id\":\(id.json),\"clientTime\":\(clientTime.json),\"serverTime\":\(serverTime)}"
    }

    static func mode(_ mode: LatencyMode) -> String {
        "{\"t\":\"mode\",\"latencyMode\":\(JSON.string(mode.rawValue))}"
    }

    static func rtcOffer(sdp: String) -> String {
        "{\"t\":\"rtcOffer\",\"sdp\":\(JSON.string(sdp))}"
    }

    static func bye(_ reason: String) -> String {
        "{\"t\":\"bye\",\"reason\":\(JSON.string(reason))}"
    }
}
