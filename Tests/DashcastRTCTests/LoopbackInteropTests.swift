import CDataChannel
import DashcastContracts
@testable import DashcastRTC
import XCTest

/// Our offerer → a second libdatachannel peer (answerer, recvonly) over 127.0.0.1, with real H.264
/// (libx264 baseline) and synthetic PCM. The answer's candidates are stripped, so the offerer can
/// only reach the answerer through the peer-reflexive candidate learned from its STUN checks, which
/// is the path the car takes (Chrome hides its host candidates behind mDNS names).
final class LoopbackInteropTests: XCTestCase {
    func testMediaSenderReportsAndPLIOverLoopback() throws {
        let units = try H264Fixture.accessUnits()
        XCTAssertGreaterThan(units.count, 200)
        XCTAssertTrue(units[0].isKeyframe)

        let factory = DataChannelPeerFactory()
        let peer = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: true))
        let events = EventRecorder()
        peer.onEvent = { events.record($0) }
        let feeder = MediaFeeder(units: units)
        feeder.sendVideo = { peer.send(video: $0) }
        feeder.sendAudio = { peer.send(audio: $0) }
        let receiver = LoopbackReceiver()
        defer {
            feeder.stop()
            peer.close()
            receiver.close()
        }

        try peer.start()
        XCTAssertTrue(events.wait(timeout: 5) { EventRecorder.offer(in: $0) != nil }, "no offer")
        let offer = try XCTUnwrap(events.offer)

        // The offer: complete (candidates included), bound to 127.0.0.1 only, codecs as specified.
        XCTAssertTrue(offer.contains("a=sendonly"))
        XCTAssertTrue(offer.contains("a=rtpmap:102 H264/90000"))
        XCTAssertTrue(offer.contains("a=fmtp:102 profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1"))
        XCTAssertTrue(offer.contains("a=rtcp-fb:102 nack pli"))
        XCTAssertTrue(offer.contains("a=rtpmap:111 opus/48000/2"))
        XCTAssertTrue(offer.contains("a=fmtp:111 minptime=10;useinbandfec=1;stereo=1"))
        let candidates = offer.split(separator: "\r\n").filter { $0.hasPrefix("a=candidate") }
        XCTAssertFalse(candidates.isEmpty, "offer must carry its candidates (no trickle)")
        for candidate in candidates {
            XCTAssertTrue(candidate.contains(" 127.0.0.1 "), "unexpected candidate: \(candidate)")
            XCTAssertTrue(candidate.contains("typ host"))
        }
        XCTAssertTrue(offer.contains("a=end-of-candidates"))

        let answer = try receiver.answer(offer: offer)
        let stripped = answer.split(separator: "\r\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("a=candidate") }.joined(separator: "\r\n")
        feeder.start()   // like the engine: media flows before the car answers; the peer drops it until open
        try peer.setRemoteDescription(type: "answer", sdp: stripped)

        XCTAssertTrue(events.wait(timeout: 10) { EventRecorder.connected(in: $0) }, "not connected: \(events.all)")
        let pair = try XCTUnwrap((peer as? DataChannelPeer)?.selectedCandidatePair())
        XCTAssertTrue(pair.remote.contains("typ prflx"), "remote should be peer-reflexive: \(pair.remote)")
        XCTAssertTrue(pair.local.contains("127.0.0.1"), pair.local)

        // Stream 3 s, then have the receiver send a PLI.
        let cpuStart = ProcessCPU.nanos()
        let wallStart = Date()
        let framesAtStart = feeder.totals.videoFrames
        Thread.sleep(forTimeInterval: 3)
        let requestsBefore = events.keyframeRequests
        XCTAssertGreaterThanOrEqual(requestsBefore, 1, "video track open should request an IDR")
        XCTAssertTrue(receiver.requestKeyframe(), "receiver couldn't send a PLI")
        XCTAssertTrue(events.wait(timeout: 2) { EventRecorder.keyframeRequests(in: $0) > requestsBefore }, "PLI → .keyframeRequested")
        Thread.sleep(forTimeInterval: 0.5)
        let wall = Date().timeIntervalSince(wallStart)
        let cpu = Double(ProcessCPU.nanos() - cpuStart) / 1e9
        let frames = feeder.totals.videoFrames - framesAtStart
        feeder.stop()
        Thread.sleep(forTimeInterval: 0.2)

        let stats = receiver.snapshot()
        let videoSSRC = try XCTUnwrap(stats.ssrcByPT[102])
        let audioSSRC = try XCTUnwrap(stats.ssrcByPT[111])
        print("""
        [loopback] \(frames) frames in \(String(format: "%.1f", wall)) s; received RTP video \(stats.rtpByPT[102] ?? 0) \
        (\(stats.bytesByPT[102] ?? 0) B, \(stats.videoTimestamps.count) frames), audio \(stats.rtpByPT[111] ?? 0); \
        SRs video \(stats.srs[videoSSRC]?.count ?? 0), audio \(stats.srs[audioSSRC]?.count ?? 0); \
        keyframe requests \(events.keyframeRequests); process CPU (sender + receiver) \
        \(String(format: "%.1f", cpu / wall * 100))% of one core; selected \(pair.local) ⇄ \(pair.remote)
        """)

        // RTP on both tracks.
        XCTAssertGreaterThan(stats.rtpByPT[102] ?? 0, 80 * 3)
        XCTAssertGreaterThan(stats.videoTimestamps.count, 80)
        XCTAssertGreaterThan(stats.rtpByPT[111] ?? 0, 130)   // 50 packets/s
        // Frame timestamps step by 1/30 s at 90 kHz; audio by 20 ms at 48 kHz (except across the IDR jump).
        let videoSteps = zip(stats.videoTimestamps.dropFirst(), stats.videoTimestamps).map { $0 &- $1 }
        XCTAssertGreaterThan(videoSteps.filter { $0 == 3_000 }.count, videoSteps.count * 9 / 10, "\(videoSteps.prefix(20))")
        let audioSteps = zip(stats.audioTimestamps.dropFirst(), stats.audioTimestamps).map { $0 &- $1 }
        XCTAssertTrue(audioSteps.allSatisfy { $0 == 960 }, "\(audioSteps.prefix(20))")

        // Sender reports on both SSRCs, each mapping its RTP timestamp to the capture time of that
        // exact frame/sample (so the browser's lip sync runs on capture time, not send time).
        let videoSRs = try XCTUnwrap(stats.srs[videoSSRC])
        let audioSRs = try XCTUnwrap(stats.srs[audioSSRC])
        XCTAssertGreaterThanOrEqual(videoSRs.count, 2)
        XCTAssertGreaterThanOrEqual(audioSRs.count, 2)
        // Exact up to RTP quantization: half a tick is 5.6 µs at 90 kHz, 10.4 µs at 48 kHz.
        func nearest(_ micros: UInt64, in pts: [UInt64]) -> Int64 {
            pts.map { abs(Int64($0) - Int64(micros)) }.min() ?? .max
        }
        let videoPTS = feeder.videoPTS
        for sr in videoSRs {
            let distance = nearest(NTPClock.micros(forNTP: sr.ntp), in: videoPTS)
            XCTAssertLessThanOrEqual(distance, 6, "video SR NTP is \(distance) µs from the nearest capture pts")
            XCTAssertTrue(stats.videoTimestamps.contains(sr.rtp), "video SR names an RTP ts that was never sent")
        }
        let lookahead = try OpusEncoder().lookaheadMicros
        let audioPTS = feeder.audioPTS
        for sr in audioSRs {
            let distance = nearest(NTPClock.micros(forNTP: sr.ntp) + lookahead, in: audioPTS)
            XCTAssertLessThanOrEqual(distance, 11, "audio SR NTP (+lookahead) is \(distance) µs from the nearest packet pts")
            XCTAssertTrue(stats.audioTimestamps.contains(sr.rtp))
        }
        print("[loopback] SR→capture error: video \(videoSRs.map { nearest(NTPClock.micros(forNTP: $0.ntp), in: videoPTS) }) µs, audio \(audioSRs.map { nearest(NTPClock.micros(forNTP: $0.ntp) + lookahead, in: audioPTS) }) µs")
        // One capture clock: the latest video and audio SRs are within a second of each other in NTP.
        let skew = abs(Int64(NTPClock.micros(forNTP: videoSRs.last!.ntp)) - Int64(NTPClock.micros(forNTP: audioSRs.last!.ntp)))
        XCTAssertLessThan(skew, 1_100_000)

        // Idempotent close; no events after it.
        peer.close()
        peer.close()
        let count = events.all.count
        peer.send(video: EncodedVideoFrame(pts: DashClock.nowMicros(), isKeyframe: true, codec: .h264, data: units[0].data))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(events.all.count, count)
    }

    func testStartFailsCleanlyWhenTheBindAddressIsMissing() throws {
        // 203.0.113.77 isn't on lo0 on a dev machine without the helper; gathering can't bind.
        let alias = DashcastDefaults.serviceAddress
        try XCTSkipIf(Self.hasLocalAddress(alias), "\(alias) exists here; nothing to test")
        let peer = DataChannelPeerFactory().makePeer(options: RTCPeerOptions(bindAddress: alias, audio: true))
        let events = EventRecorder()
        peer.onEvent = { events.record($0) }
        do {
            try peer.start()
            // Some failures surface asynchronously instead: then there must be no usable offer.
            events.wait(timeout: 2) { EventRecorder.offer(in: $0) != nil }
            if let offer = events.offer {
                XCTAssertFalse(offer.contains("a=candidate"), "offer has candidates on a missing address")
            }
            print("[missing-bind] start() succeeded; events: \(events.all.map { "\($0)".prefix(60) })")
        } catch {
            print("[missing-bind] start() threw: \(error)")
        }
        peer.close()
        peer.close()
    }

    func testCloseBeforeStartAndManyPeers() throws {
        let factory = DataChannelPeerFactory()
        let idle = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: false))
        idle.close()
        XCTAssertThrowsError(try idle.start())

        // Create/teardown churn: every peer gathers and emits exactly one offer; no leaks or crashes.
        for _ in 0 ..< 10 {
            let peer = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: true))
            let events = EventRecorder()
            peer.onEvent = { events.record($0) }
            try peer.start()
            XCTAssertTrue(events.wait(timeout: 5) { EventRecorder.offer(in: $0) != nil })
            peer.close()
        }

        // Dropped without close(): deinit hands the teardown to a background queue; the weak
        // registry means libdatachannel callbacks can't reach the freed object.
        weak var dropped: DataChannelPeer?
        do {
            let peer = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: true)) as! DataChannelPeer
            let events = EventRecorder()
            peer.onEvent = { events.record($0) }
            try peer.start()
            XCTAssertTrue(events.wait(timeout: 5) { EventRecorder.offer(in: $0) != nil })
            dropped = peer
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(dropped, "peer leaked (retain cycle?)")
    }

    static func hasLocalAddress(_ address: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
               String(cString: host) == address {
                return true
            }
        }
        return false
    }
}

/// A plain libdatachannel answerer: recvonly tracks from the offer, counts decrypted RTP/RTCP.
final class LoopbackReceiver: @unchecked Sendable {
    struct SenderReport { var ntp: UInt64; var rtp: UInt32 }
    struct Stats {
        var rtpByPT: [UInt8: Int] = [:]
        var bytesByPT: [UInt8: Int] = [:]
        var ssrcByPT: [UInt8: UInt32] = [:]
        var srs: [UInt32: [SenderReport]] = [:]
        var videoTimestamps: [UInt32] = []   // one per frame (marker bit)
        var audioTimestamps: [UInt32] = []
    }

    private let lock = NSLock()
    private var stats = Stats()
    private var pc: Int32 = -1
    private var videoTrack: Int32 = -1
    private var tracks: [Int32] = []
    private var gathered = false
    private let gatheredCondition = NSCondition()
    private var retained: Unmanaged<LoopbackReceiver>?

    init() {
        var config = rtcConfiguration()
        config.disableAutoNegotiation = false
        pc = "127.0.0.1".withCString { address in
            config.bindAddress = address
            return rtcCreatePeerConnection(&config)
        }
        let unmanaged = Unmanaged.passRetained(self)
        retained = unmanaged
        rtcSetUserPointer(pc, unmanaged.toOpaque())
        rtcSetGatheringStateChangeCallback(pc) { _, state, pointer in
            guard state == RTC_GATHERING_COMPLETE else { return }
            let me = Unmanaged<LoopbackReceiver>.fromOpaque(pointer!).takeUnretainedValue()
            me.gatheredCondition.lock()
            me.gathered = true
            me.gatheredCondition.broadcast()
            me.gatheredCondition.unlock()
        }
        rtcSetTrackCallback(pc) { _, track, pointer in
            let me = Unmanaged<LoopbackReceiver>.fromOpaque(pointer!).takeUnretainedValue()
            let mid = LibDataChannel.string { rtcGetTrackMid(track, $0, $1) }
            rtcSetMessageCallback(track) { _, _, _, _ in }   // don't queue; the interceptor counts
            me.lock.lock()
            me.tracks.append(track)
            if mid == "video" {
                me.videoTrack = track
                rtcChainRtcpReceivingSession(track)   // lets rtcRequestKeyframe send a PLI
            }
            me.lock.unlock()
        }
        rtcSetMediaInterceptorCallback(pc) { _, message, size, pointer in
            let me = Unmanaged<LoopbackReceiver>.fromOpaque(pointer!).takeUnretainedValue()
            if let message, size > 0 {
                me.inspect(UnsafeRawBufferPointer(start: message, count: Int(size)))
            }
            return UnsafeMutableRawPointer(mutating: message)
        }
    }

    func answer(offer: String) throws -> String {
        guard rtcSetRemoteDescription(pc, offer, "offer") >= 0 else { throw NSError(domain: "receiver", code: 1) }
        gatheredCondition.lock()
        let deadline = Date().addingTimeInterval(5)
        while !gathered, gatheredCondition.wait(until: deadline) {}
        gatheredCondition.unlock()
        return try XCTUnwrap(LibDataChannel.string { rtcGetLocalDescription(pc, $0, $1) })
    }

    func requestKeyframe() -> Bool {
        let track = lock.withLock { videoTrack }
        return track >= 0 && rtcRequestKeyframe(track) >= 0
    }

    func snapshot() -> Stats { lock.withLock { stats } }

    func close() {
        let (pc, tracks) = lock.withLock { (self.pc, self.tracks) }
        guard pc >= 0 else { return }
        tracks.forEach { rtcDeleteTrack($0) }
        rtcDeletePeerConnection(pc)
        lock.withLock { self.pc = -1 }
        Thread.sleep(forTimeInterval: 0.1)   // let in-flight callbacks finish before the release
        retained?.release()
        retained = nil
    }

    private func inspect(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 8, bytes[0] >> 6 == 2 else { return }
        func u32(_ at: Int) -> UInt32 {
            (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16) | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
        }
        lock.lock()
        defer { lock.unlock() }
        if (192 ... 223).contains(bytes[1]) {   // RTCP compound
            var offset = 0
            while offset + 8 <= bytes.count {
                let type = bytes[offset + 1]
                let length = (((Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])) + 1) * 4
                if type == 200, offset + 20 <= bytes.count {
                    let ssrc = u32(offset + 4)
                    let ntp = UInt64(u32(offset + 8)) << 32 | UInt64(u32(offset + 12))
                    stats.srs[ssrc, default: []].append(SenderReport(ntp: ntp, rtp: u32(offset + 16)))
                }
                offset += length
            }
            return
        }
        guard bytes.count >= 12 else { return }
        let pt = bytes[1] & 0x7F
        let marker = bytes[1] & 0x80 != 0
        let timestamp = u32(4)
        stats.rtpByPT[pt, default: 0] += 1
        stats.bytesByPT[pt, default: 0] += bytes.count
        stats.ssrcByPT[pt] = u32(8)
        if pt == 102, marker { stats.videoTimestamps.append(timestamp) }
        if pt == 111 { stats.audioTimestamps.append(timestamp) }
    }
}
