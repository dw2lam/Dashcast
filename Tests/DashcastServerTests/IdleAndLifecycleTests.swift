import DashcastContracts
import Foundation
import XCTest
@testable import DashcastServer

/// The service runs for as long as the Mac's hotspot is up, usually with no car: it must cost nothing
/// then, and start/stop/refresh must never leave it half on.
@MainActor
final class IdleAndLifecycleTests: XCTestCase {
    var engine: MockEngine!
    var network: MockNetwork!
    var service: DashcastService!

    override func setUp() async throws {
        engine = MockEngine()
        network = MockNetwork()
    }

    override func tearDown() async throws {
        await service?.stop()
        service = nil
    }

    func makeService() -> DashcastService {
        var options = ServerOptions()
        options.devPort = 0
        options.plainHTTPPort = nil
        options.reconnectGracePeriod = 0.2
        return DashcastService(engine: engine, network: network, options: options, displayAwake: FakeDisplayAwake())
    }

    /// No car: neither the hub's 4 Hz timer nor the HTTP idle sweep runs. A car arms both; once it
    /// leaves, both go quiet again.
    func testIdleServiceArmsNoTimers() async throws {
        service = makeService()
        await service.start()
        let port = try XCTUnwrap(service.devPort)
        try await Task.sleep(nanoseconds: 600_000_000)
        var idle = await service.debugIdleState()
        XCTAssertEqual(idle.listeners, ["dev"])
        XCTAssertFalse(idle.hubTimer, "no socket, no hub timer")
        XCTAssertFalse(idle.sweepTimer, "no connection, no sweep")
        XCTAssertEqual(service.debugSessionSnapshot().ticks, 0)

        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        try await client.send(Fixtures.mcu2Hello)
        let configured = await waitUntil(timeout: 5) { !client.texts("config").isEmpty && client.binaries.count > 3 }
        XCTAssertTrue(configured)
        let busy = await service.debugIdleState()
        XCTAssertTrue(busy.hubTimer)
        XCTAssertTrue(busy.sweepTimer)

        // Media is flowing: an H.264 access unit behind the 16-byte header.
        let video = client.binaries.filter { MediaHeader($0)?.type == .videoH264 }
        let first = try XCTUnwrap(video.first)
        XCTAssertEqual(Array(first[MediaHeader.size..<MediaHeader.size + 4]), [0, 0, 0, 1])
        XCTAssertTrue([6005, 1505].contains(first.count - MediaHeader.size), "\(first.count)")

        client.close()
        let quiet = await waitUntil(timeout: 3) { self.service.state.car == nil }
        XCTAssertTrue(quiet)
        var settled = false
        for _ in 0..<40 {
            idle = await service.debugIdleState()
            if !idle.hubTimer && !idle.sweepTimer { settled = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "timers disarm once the car is gone: \(idle)")
        let ticks = service.debugSessionSnapshot().ticks
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(service.debugSessionSnapshot().ticks, ticks)
    }

    /// stop() arriving while start() waits on the DNS responder used to leave the dev listener up
    /// and the phase at "waiting for car" on a stopped service.
    func testStopDuringStartLeavesNothingListening() async throws {
        network.localServicesDelay = .milliseconds(150)
        service = makeService()
        let starting = Task { await self.service.start() }
        try await Task.sleep(nanoseconds: 30_000_000)
        await service.stop()
        await starting.value
        XCTAssertEqual(service.state.phase, .idle)
        XCTAssertNil(service.devPort)
        let idle = await service.debugIdleState()
        XCTAssertEqual(idle.listeners, [])
        XCTAssertEqual(network.localServicesStarts, 1)
        XCTAssertEqual(network.localServicesStops, 1)

        // And it starts again cleanly.
        network.localServicesDelay = .zero
        await service.start()
        XCTAssertEqual(service.state.phase, .waitingForCar)
        let port = try XCTUnwrap(service.devPort)
        let reply = await rawHTTP(port: port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
    }

    /// A burst of network changes (Internet Sharing coming up) reads the status once, not per event.
    func testNetworkChangeBurstReadsStatusOnce() async throws {
        service = makeService()
        for _ in 0..<6 {
            network.simulateNetworkChange()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let refreshed = await waitUntil(timeout: 2) { self.network.statusReads > 0 }
        XCTAssertTrue(refreshed)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(network.statusReads, 1)
    }

    /// Overlapping refreshes (the Car Hotspot window polls while a change is being handled) share
    /// one read, plus at most one more so every caller sees a status read after it asked.
    func testOverlappingRefreshesShareOneRead() async throws {
        service = makeService()
        async let a: Void = service.refreshNetwork()
        async let b: Void = service.refreshNetwork()
        async let c: Void = service.refreshNetwork()
        _ = await (a, b, c)
        XCTAssertLessThanOrEqual(network.statusReads, 2)
        XCTAssertGreaterThanOrEqual(network.statusReads, 1)
        let before = network.statusReads
        await service.refreshNetwork()
        XCTAssertEqual(network.statusReads, before + 1, "a later call always reads again")
    }
}

/// Slowloris: a client trickling an endless request is dropped even though it's never idle.
final class SlowRequestTests: XCTestCase {
    final class NoopDelegate: WebSocketDelegate {
        func webSocketDidOpen(_ connection: ServerConnection) {}
        func webSocket(_ connection: ServerConnection, didReceiveText text: String) {}
        func webSocket(_ connection: ServerConnection, didReceivePong payload: Data) {}
        func webSocketDidDrain(_ connection: ServerConnection) {}
        func webSocketDidClose(_ connection: ServerConnection, reason: String) {}
    }

    func testTricklingRequestIsDropped() throws {
        let queue = DispatchQueue(label: "slow")
        let server = HTTPServer(queue: queue, pages: ClientPageProvider(directory: nil), allowedHosts: ["localhost"])
        let delegate = NoopDelegate()
        server.webSocketDelegate = delegate
        server.requestTimeout = 0.5
        server.sweepInterval = 0.2
        let bound = expectation(description: "listening")
        var port: UInt16 = 0
        queue.async {
            server.startListener(name: "t", role: .app, host: "127.0.0.1", port: 0, tls: nil) { result in
                port = (try? result.get()) ?? 0
                bound.fulfill()
            }
        }
        wait(for: [bound], timeout: 3)
        XCTAssertNotEqual(port, 0)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        let start = Date()
        var dropped = false
        _ = "GET / HTTP/1.1\r\nHost: localhost\r\n".withCString { write(fd, $0, strlen($0)) }
        // One header byte every 100 ms keeps it from ever being idle.
        while Date().timeIntervalSince(start) < 4 {
            Thread.sleep(forTimeInterval: 0.1)
            var byte: UInt8 = 0x58
            if write(fd, &byte, 1) < 0 { dropped = true; break }
            var count: Int32 = 0
            queue.sync { count = Int32(server.connectionCount) }
            if count == 0 { dropped = true; break }
        }
        XCTAssertTrue(dropped, "a request still incomplete after requestTimeout is cut off")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        queue.sync { server.stopAll() }
    }
}
