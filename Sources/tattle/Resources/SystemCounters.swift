import Darwin
import Foundation

/// Raw kernel counters read in one pass. Rates come from the difference between two
/// snapshots; see `ResourceSample.between`.
struct SystemSnapshot: Sendable {
    var time: Date
    var cpu: CPUTicks
    var memory: MemoryUsage
    var network: NetworkCounters

    /// Reads the counters now. Returns nil if any Mach call fails, which should not
    /// happen on a supported macOS.
    static func read(at time: Date = Date()) -> SystemSnapshot? {
        guard let cpu = CPUTicks.read(), let memory = MemoryUsage.read(),
              let network = NetworkCounters.read() else { return nil }
        return SystemSnapshot(time: time, cpu: cpu, memory: memory, network: network)
    }
}

/// Aggregate scheduler ticks since boot, all cores together.
struct CPUTicks: Equatable, Sendable {
    var busy: UInt64
    var total: UInt64

    static func read() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + nice + idle)
    }
}

struct MemoryUsage: Equatable, Sendable {
    var used: UInt64
    var total: UInt64

    /// "Used" follows Activity Monitor: app memory (internal minus purgeable) plus wired
    /// plus compressed. Cached files are not counted; they are reclaimable.
    static func read() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return MemoryUsage(used: used, total: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Bytes in and out of each interface that carries its own traffic, by name. The kernel's
/// per-interface counters are 32-bit, and they wrap and go away with the interface, so two
/// readings are compared one interface at a time; see `delta(from:)`.
struct NetworkCounters: Equatable, Sendable {
    struct Interface: Equatable, Sendable {
        var bytesIn: UInt32
        var bytesOut: UInt32
    }

    var interfaces: [String: Interface]

    /// Interface names of the virtual kinds whose bytes are counted again on the interface
    /// beneath them: tunnels, bridges and the VM interfaces that join them, VLANs, link
    /// aggregates and virtual Ethernet pairs.
    private static let layeredInterfaces = ["utun", "ipsec", "gif", "stf", "bridge", "vmenet", "vlan", "bond", "feth"]

    static func carriesItsOwnTraffic(_ name: String) -> Bool {
        !layeredInterfaces.contains { name.hasPrefix($0) }
    }

    static func read() -> NetworkCounters? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var interfaces: [String: Interface] = [:]
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            if entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard carriesItsOwnTraffic(name) else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces[name] = Interface(bytesIn: stats.ifi_ibytes, bytesOut: stats.ifi_obytes)
        }
        return NetworkCounters(interfaces: interfaces)
    }

    /// Bytes transferred since `earlier`, over the interfaces in both readings: one that
    /// appeared or vanished in between says nothing about the interval. A counter that went
    /// down wrapped, which the 32-bit subtraction undoes.
    func delta(from earlier: NetworkCounters) -> (bytesIn: UInt64, bytesOut: UInt64) {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        for (name, later) in interfaces {
            guard let before = earlier.interfaces[name] else { continue }
            bytesIn += UInt64(later.bytesIn &- before.bytesIn)
            bytesOut += UInt64(later.bytesOut &- before.bytesOut)
        }
        return (bytesIn, bytesOut)
    }
}
