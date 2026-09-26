import Darwin
import XCTest
@testable import DashcastNetwork

final class CarPresenceTests: XCTestCase {
    /// One route message the way the kernel lays it out: rt_msghdr, sockaddr_in, sockaddr_dl.
    private func message(_ ip: [UInt8], ifIndex: UInt16, macLength: UInt8) -> [UInt8] {
        let header = MemoryLayout<rt_msghdr>.size
        var sin = [UInt8](repeating: 0, count: 16)
        sin[0] = 16; sin[1] = UInt8(AF_INET)
        sin.replaceSubrange(4..<8, with: ip)
        var sdl = [UInt8](repeating: 0, count: 20)
        sdl[0] = 20; sdl[1] = UInt8(AF_LINK)
        sdl[2] = UInt8(ifIndex & 0xFF); sdl[3] = UInt8(ifIndex >> 8)
        sdl[6] = macLength
        let length = header + sin.count + sdl.count
        var head = [UInt8](repeating: 0, count: header)
        head[0] = UInt8(length & 0xFF); head[1] = UInt8(length >> 8)
        return head + sin + sdl
    }

    func testParsesResolvedAndPendingNeighbours() {
        let lo0 = UInt16(if_nametoindex("lo0"))
        let bytes = message([192, 168, 2, 3], ifIndex: lo0, macLength: 6) + message([192, 168, 2, 9], ifIndex: lo0, macLength: 0)
        XCTAssertEqual(ARPTable.parse(bytes), [
            .init(address: "192.168.2.3", interface: "lo0", complete: true),
            .init(address: "192.168.2.9", interface: "lo0", complete: false),
        ])
        XCTAssertEqual(ARPTable.parse(Array(bytes.prefix(20))), [], "a truncated table is ignored")
    }

    /// Read-only: the real table parses into plausible entries.
    func testReadsThisMacsTable() {
        for entry in ARPTable.entries() {
            XCTAssertTrue(IPv4.isValid(entry.address), entry.address)
            XCTAssertFalse(entry.interface.isEmpty)
        }
    }

    func testPresenceFromTheTable() {
        let table: [ARPTable.Entry] = [.init(address: "192.168.2.3", interface: "bridge100", complete: true),
                                       .init(address: "192.168.2.4", interface: "bridge100", complete: false)]
        XCTAssertNil(ARPTable.presence(of: "192.168.2.3", in: table), "resolved: can't tell it left")
        XCTAssertEqual(ARPTable.presence(of: "192.168.2.4", in: table), false, "nobody answers")
        XCTAssertEqual(ARPTable.presence(of: "192.168.2.5", in: table), false, "gone from the table")
    }

    @MainActor
    func testManagerNudgesThenReadsOnlyForLocalSubnets() async {
        let world = FakeWorld()
        world.snapshot = InterfaceSnapshot(addresses: [
            InterfaceAddress(name: "bridge100", address: "192.168.2.1", netmask: "255.255.255.0"),
            InterfaceAddress(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0"),
        ])
        var nudged: [String] = []
        var environment = makeEnvironment(world: world)
        environment.neighbours = { [.init(address: "192.168.2.3", interface: "bridge100", complete: true)] }
        environment.nudgeNeighbour = { nudged.append($0) }
        environment.neighbourSettle = .milliseconds(20)
        let manager = NetworkManager(environment: environment)

        let stillThere = await manager.isStillOnNetwork("192.168.2.3")
        XCTAssertNil(stillThere)
        XCTAssertEqual(nudged, ["192.168.2.3", "192.168.2.3"])
        let gone = await manager.isStillOnNetwork("192.168.2.7")
        XCTAssertEqual(gone, false)

        nudged = []
        for address in ["10.0.0.5", "127.0.0.1", "not an ip"] {
            let answer = await manager.isStillOnNetwork(address)
            XCTAssertNil(answer, "\(address): not on a link we can see")
        }
        XCTAssertEqual(nudged, [], "never pokes addresses off our subnets")
    }
}
