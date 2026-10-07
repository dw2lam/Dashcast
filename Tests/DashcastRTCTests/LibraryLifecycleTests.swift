import CDataChannel
import DashcastContracts
@testable import DashcastRTC
import Darwin
import XCTest

/// libdatachannel's threads (pool + usrsctp's 10 ms timer) exist only while a peer does: the factory
/// alone (what the app makes at launch) starts nothing, the last close tears the stack down, and the
/// next peer brings it back and still connects. Runs before LoopbackInteropTests, which then also
/// streams on a re-initialized stack.
final class LibraryLifecycleTests: XCTestCase {
    func testStackStartsWithFirstPeerAndStopsAfterTheLast() throws {
        let savedDelay = LibDataChannel.idleCleanupDelay
        LibDataChannel.idleCleanupDelay = 0.2
        defer { LibDataChannel.idleCleanupDelay = savedDelay }
        LibDataChannel.cleanupNowIfIdle()
        XCTAssertFalse(LibDataChannel.isRunning)
        let idle = Self.threadCount()

        let factory = DataChannelPeerFactory()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(LibDataChannel.isRunning, "the factory alone must not start the stack")
        XCTAssertLessThanOrEqual(Self.threadCount(), idle + 1, "the factory alone starts no threads")

        for cycle in 1...2 {
            let peer = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: true))
            let events = EventRecorder()
            peer.onEvent = { events.record($0) }
            try peer.start()
            XCTAssertTrue(events.wait(timeout: 5) { EventRecorder.offer(in: $0) != nil }, "cycle \(cycle): no offer")
            let receiver = LoopbackReceiver()
            let answer = try receiver.answer(offer: XCTUnwrap(events.offer))
            try peer.setRemoteDescription(type: "answer", sdp: answer)
            XCTAssertTrue(events.wait(timeout: 10) { EventRecorder.connected(in: $0) }, "cycle \(cycle): not connected")
            XCTAssertTrue(LibDataChannel.isRunning)
            let busy = Self.threadCount()
            XCTAssertGreaterThan(busy, idle + 2, "a live peer runs libdatachannel's threads")

            peer.close()
            receiver.close()
            let deadline = Date().addingTimeInterval(5)
            while LibDataChannel.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            XCTAssertFalse(LibDataChannel.isRunning, "cycle \(cycle): stack still up after the last peer closed")
            Thread.sleep(forTimeInterval: 0.1)
            let after = Self.threadCount()
            print("[lifecycle] cycle \(cycle): threads idle \(idle), with a connected peer \(busy), after cleanup \(after)")
            XCTAssertLessThanOrEqual(after, idle + 2, "cycle \(cycle): threads left behind")
        }
    }

    /// A peer created while the idle delay is still running keeps the stack (no cleanup under it).
    func testPeerWithinTheIdleDelayKeepsTheStack() throws {
        let savedDelay = LibDataChannel.idleCleanupDelay
        LibDataChannel.idleCleanupDelay = 0.3
        defer { LibDataChannel.idleCleanupDelay = savedDelay }
        let factory = DataChannelPeerFactory()
        let first = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: false))
        try first.start()
        first.close()
        let second = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: false))
        let events = EventRecorder()
        second.onEvent = { events.record($0) }
        try second.start()
        Thread.sleep(forTimeInterval: 0.6)   // past the first peer's idle delay
        XCTAssertTrue(LibDataChannel.isRunning)
        XCTAssertTrue(events.wait(timeout: 5) { EventRecorder.offer(in: $0) != nil }, "second peer works")
        second.close()
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}
