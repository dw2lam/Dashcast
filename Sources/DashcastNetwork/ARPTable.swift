import Darwin
import Foundation

/// The kernel's IPv4 neighbour (ARP) table, read the way `arp -an` does (sysctl, no privileges).
enum ARPTable {
    struct Entry: Equatable {
        var address: String
        var interface: String
        /// Resolved to a hardware address (false = still asking, i.e. nobody answered yet).
        var complete: Bool
    }

    static func entries() -> [Entry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size + 1024)   // the table may grow between calls
        size = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return parse(Array(buffer.prefix(size)))
    }

    /// Route messages: rt_msghdr, then the destination sockaddr_in, then the gateway sockaddr_dl.
    static func parse(_ bytes: [UInt8]) -> [Entry] {
        let header = MemoryLayout<rt_msghdr>.size
        var entries: [Entry] = []
        var offset = 0
        while offset + header <= bytes.count {
            let length = Int(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            guard length >= header, offset + length <= bytes.count else { break }
            defer { offset += length }
            let sin = offset + header
            guard sin + 8 <= offset + length, bytes[sin + 1] == UInt8(AF_INET) else { continue }
            let address = "\(bytes[sin + 4]).\(bytes[sin + 5]).\(bytes[sin + 6]).\(bytes[sin + 7])"
            let sinLength = max(Int(bytes[sin]), 4)
            let sdl = sin + ((sinLength + 3) & ~3)
            // sockaddr_dl: len, family, index (u16), type, nlen, alen, slen, data…
            guard sdl + 8 <= offset + length, bytes[sdl + 1] == UInt8(AF_LINK) else { continue }
            let index = UInt32(UInt16(bytes[sdl + 2]) | UInt16(bytes[sdl + 3]) << 8)
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let interface = if_indextoname(index, &name).map { String(cString: $0) } ?? "if\(index)"
            entries.append(Entry(address: address, interface: interface, complete: bytes[sdl + 6] > 0))
        }
        return entries
    }

    /// Sends a byte to the discard port so the kernel re-resolves an expired or unknown neighbour.
    static func nudge(_ address: String) {
        guard let ip = IPv4.parse(address) else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(9).bigEndian
        target.sin_addr = in_addr(s_addr: ip.bigEndian)
        var byte: UInt8 = 0
        _ = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &byte, 1, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// false when the address has no resolved neighbour entry (it isn't answering on the link);
    /// nil when it has one, which only says it answered at some point.
    static func presence(of address: String, in entries: [Entry]) -> Bool? {
        guard let entry = entries.first(where: { $0.address == address }), entry.complete else { return false }
        return nil
    }
}
