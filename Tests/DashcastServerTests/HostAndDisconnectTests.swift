import DashcastContracts
import Foundation
import XCTest
@testable import DashcastServer

final class DisconnectClassifierTests: XCTestCase {
    private func reason(_ ending: DisconnectClassifier.Ending, _ stillOnNetwork: Bool?) -> DisconnectReason {
        DisconnectClassifier.reason(for: ending, stillOnNetwork: stillOnNetwork)
    }

    func testCleanClosesAreTheBrowser() {
        for present in [true, false, nil] as [Bool?] {
            XCTAssertEqual(reason(.socket(.closedByCar(code: 1001)), present), .browserClosed, "page left/tab closed")
            XCTAssertEqual(reason(.socket(.closedByCar(code: 1000)), present), .browserClosed)
            XCTAssertEqual(reason(.socket(.finishedByCar), present), .browserClosed, "TCP FIN: the car closed its socket")
        }
        XCTAssertFalse(DisconnectClassifier.needsPresenceCheck(.socket(.closedByCar(code: 1001))))
        XCTAssertFalse(DisconnectClassifier.needsPresenceCheck(.socket(.finishedByCar)))
    }

    func testDropsAreTheWiFiOnlyWhenTheCarIsGone() {
        for ending in [DisconnectClassifier.Ending.timedOut, .socket(.failed), .socket(.closedByCar(code: nil)),
                       .socket(.closedByCar(code: 1006))] {
            XCTAssertTrue(DisconnectClassifier.needsPresenceCheck(ending), "\(ending)")
            XCTAssertEqual(reason(ending, false), .leftWiFi, "\(ending)")
            XCTAssertEqual(reason(ending, true), .connectionLost, "\(ending)")
            XCTAssertEqual(reason(ending, nil), .connectionLost, "can't tell → the modest claim")
        }
    }

    func testServerSideEndingsAreConnectionLost() {
        for ending in [DisconnectClassifier.Ending.serverEnded, .socket(.closedByServer)] {
            XCTAssertFalse(DisconnectClassifier.needsPresenceCheck(ending))
            XCTAssertEqual(reason(ending, false), .connectionLost)
        }
    }

    func testHostStateMappingAndMessage() {
        XCTAssertEqual(HostState.resolve(systemSleeping: false, locked: false, displayAsleep: false), .active)
        XCTAssertEqual(HostState.resolve(systemSleeping: false, locked: false, displayAsleep: true), .displayAsleep)
        XCTAssertEqual(HostState.resolve(systemSleeping: false, locked: true, displayAsleep: false), .locked)
        XCTAssertEqual(HostState.resolve(systemSleeping: false, locked: true, displayAsleep: true), .locked, "locked beats a dark display")
        XCTAssertEqual(HostState.resolve(systemSleeping: true, locked: true, displayAsleep: true), .sleeping, "asleep beats everything")
        XCTAssertEqual(HostState.resolve(systemSleeping: true, locked: false, displayAsleep: false), .sleeping)
        XCTAssertEqual(ServerMessage.host(.displayAsleep), #"{"t":"host","state":"displayAsleep"}"#)
        XCTAssertEqual(ServerMessage.host(.active), #"{"t":"host","state":"active"}"#)
    }
}

/// A WebSocket client over a plain BSD socket, so a test can drop the TCP connection with a reset
/// (no close frame, no FIN), like a car that drives out of Wi-Fi range.
final class DroppableCarSocket: @unchecked Sendable {
    private let fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        write("GET /ws HTTP/1.1\r\nHost: localhost:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
        var buffer = [UInt8](repeating: 0, count: 4096)
        guard read(fd, &buffer, buffer.count) > 0, String(decoding: buffer, as: UTF8.self).hasPrefix("HTTP/1.1 101") else {
            close(fd); return nil
        }
    }

    private func write(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// One masked text frame (client → server frames must be masked).
    func send(_ text: String) {
        let payload = Array(text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// RST instead of FIN.
    func reset() {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(fd)
    }
}

@MainActor
final class HostAndDisconnectServiceTests: XCTestCase {
    var engine: MockEngine!
    var network: MockNetwork!
    var awake: FakeDisplayAwake!
    var service: DashcastService!

    override func setUp() async throws {
        engine = MockEngine()
        network = MockNetwork()
        awake = FakeDisplayAwake()
    }

    override func tearDown() async throws {
        await service?.stop()
        service = nil
    }

    private func start(settings: ServiceSettings = .init()) async throws -> UInt16 {
        var options = ServerOptions()
        options.devPort = 0
        options.plainHTTPPort = nil
        options.reconnectGracePeriod = 0.3
        service = DashcastService(engine: engine, network: network, settings: settings, options: options, displayAwake: awake)
        await service.start()
        return try XCTUnwrap(service.devPort)
    }

    private func connectCar(_ port: UInt16) async throws -> WSClient {
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        try await client.send(Fixtures.mcu2Hello)
        let configured = await waitUntil(timeout: 5) { !client.texts("config").isEmpty && self.service.state.car != nil }
        XCTAssertTrue(configured, "no config: \(String(describing: client.error))")
        return client
    }

    func testHostStateReachesTheCarAndIsRepeatedForTheNextStream() async throws {
        let port = try await start()
        let client = try await connectCar(port)
        defer { client.close() }

        service.setHostState(.locked)
        XCTAssertEqual(service.state.hostState, .locked)
        let locked = await waitUntil(timeout: 3) { client.texts("host").last?["state"] as? String == "locked" }
        XCTAssertTrue(locked)
        XCTAssertTrue(service.state.log.contains { $0.message.contains("Mac locked") })

        // willSleep: returns only once the message is on its way, well within the notice timeout.
        let before = Date()
        service.setHostState(.sleeping)
        XCTAssertLessThan(Date().timeIntervalSince(before), DashcastService.sleepNoticeTimeout + 0.2)
        let sleeping = await waitUntil(timeout: 3) { client.texts("host").last?["state"] as? String == "sleeping" }
        XCTAssertTrue(sleeping)

        // Unchanged state: nothing new is sent.
        let count = client.texts("host").count
        service.setHostState(.sleeping)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.texts("host").count, count)

        // A car that connects while the Mac is still locked hears it right after its config.
        service.setHostState(.locked)
        let second = try await connectCar(port)
        defer { second.close() }
        let order = await waitUntil(timeout: 3) { second.texts.contains { $0["t"] as? String == "host" } }
        XCTAssertTrue(order)
        let types = second.texts.compactMap { $0["t"] as? String }
        XCTAssertLessThan(try XCTUnwrap(types.firstIndex(of: "config")), try XCTUnwrap(types.firstIndex(of: "host")))
        XCTAssertEqual(second.texts("host").first?["state"] as? String, "locked")

        service.setHostState(.active)
        let active = await waitUntil(timeout: 3) { second.texts("host").last?["state"] as? String == "active" }
        XCTAssertTrue(active)
    }

    func testClosedBrowserIsReportedAndClearedOnReconnect() async throws {
        let port = try await start()
        let client = try await connectCar(port)
        XCTAssertTrue(awake.held, "display kept awake while a car watches")

        client.close()   // close frame 1001, like a tab closing
        let reported = await waitUntil(timeout: 5) { self.service.state.lastDisconnect != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(service.state.lastDisconnect?.reason, .browserClosed)
        XCTAssertEqual(network.presenceQueries, [], "a clean close needs no network check")
        XCTAssertFalse(awake.held, "released when the car leaves")
        XCTAssertEqual(service.state.phase, .waitingForCar)

        let again = try await connectCar(port)
        defer { again.close() }
        XCTAssertNil(service.state.lastDisconnect, "a new car clears the hint")
        XCTAssertTrue(awake.held)

        await service.stop()
        XCTAssertFalse(awake.held)
        XCTAssertNil(service.state.lastDisconnect)
    }

    func testDroppedSocketAsksTheNetworkWhereTheCarWent() async throws {
        let port = try await start()
        for (present, expected) in [(false, DisconnectReason.leftWiFi), (nil, .connectionLost)] as [(Bool?, DisconnectReason)] {
            network.stillOnNetwork = present
            network.presenceQueries = []
            let car = try XCTUnwrap(DroppableCarSocket(port: port))
            car.send(Fixtures.json(Fixtures.mcu2Hello))
            let connected = await waitUntil(timeout: 5) { self.service.state.car != nil }
            XCTAssertTrue(connected)
            car.reset()
            let reported = await waitUntil(timeout: 5) { self.service.state.lastDisconnect != nil }
            XCTAssertTrue(reported)
            XCTAssertEqual(service.state.lastDisconnect?.reason, expected)
            XCTAssertEqual(network.presenceQueries, ["127.0.0.1"])
            // Next round starts from a clean slate (a car connecting clears the hint).
            service.state.lastDisconnect = nil
        }
    }

    func testKeepDisplayAwakeSetting() async throws {
        var settings = ServiceSettings()
        settings.keepDisplayAwake = false
        let port = try await start(settings: settings)
        let client = try await connectCar(port)
        defer { client.close() }
        XCTAssertFalse(awake.held, "setting off: no assertion")

        service.settings.keepDisplayAwake = true
        await service.applySettings()
        XCTAssertTrue(awake.held)
        service.settings.keepDisplayAwake = false
        await service.applySettings()
        XCTAssertFalse(awake.held)
        XCTAssertEqual(awake.changes, [true, false])
    }

    /// Screen Recording revoked mid-cast: casting stops with the message instead of a frozen picture.
    func testPermissionLossStopsCasting() async throws {
        let port = try await start()
        let client = try await connectCar(port)
        defer { client.close() }
        engine.onEvent?(.permissionMissing("Screen Recording stopped working, so casting stopped."))
        let stopped = await waitUntil(timeout: 5) {
            self.service.state.phase == .error("Screen Recording stopped working, so casting stopped.")
        }
        XCTAssertTrue(stopped, "\(service.state.phase)")
        XCTAssertNil(service.devPort, "listeners are down")
        XCTAssertFalse(awake.held)
        let bye = await waitUntil(timeout: 3) { !client.texts("bye").isEmpty }
        XCTAssertTrue(bye, "the car is told")
    }
}
