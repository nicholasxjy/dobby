import Darwin

public enum PortProtocol: String, Sendable, Codable {
    case tcp, udp
}

/// One listening TCP socket or bound, unconnected UDP socket. `address` is "*" for the wildcard.
public struct SocketEntry: Equatable, Sendable, Codable {
    public let pid: pid_t
    public let proto: PortProtocol
    public let address: String
    public let port: UInt16

    public init(pid: pid_t, proto: PortProtocol, address: String, port: UInt16) {
        self.pid = pid
        self.proto = proto
        self.address = address
        self.port = port
    }
}

/// Who can reach a port.
public enum PortExposure: Sendable {
    /// Only this Mac (127.0.0.1 / ::1).
    case loopback
    /// Every network interface (0.0.0.0 / ::), i.e. reachable from the network.
    case allInterfaces
    /// Specific non-loopback addresses.
    case specific
}

/// A port held by a process, merged across IPv4/IPv6 sockets.
public struct PortBinding: Identifiable, Equatable, Sendable {
    public let pid: pid_t
    public let name: String
    public let path: String?
    public let ownerName: String?
    public let proto: PortProtocol
    public let port: UInt16
    public let addresses: [String]

    public var id: String { "\(pid)/\(proto.rawValue)/\(port)" }

    public var exposure: PortExposure {
        if addresses.contains("*") { return .allInterfaces }
        if addresses.allSatisfy({ $0 == "127.0.0.1" || $0 == "::1" }) { return .loopback }
        return .specific
    }

    public var appBundlePath: String? {
        path.flatMap(AppBundle.outermostAppPath(in:))
    }
}

public enum PortList {
    /// Merges sockets that share process, protocol and port; sorts by port, then TCP first, then PID.
    public static func bindings(from entries: [SocketEntry], processes: [pid_t: ProcessUsage]) -> [PortBinding] {
        struct Key: Hashable { let pid: pid_t; let proto: PortProtocol; let port: UInt16 }
        var addresses: [Key: Set<String>] = [:]
        for entry in entries {
            addresses[Key(pid: entry.pid, proto: entry.proto, port: entry.port), default: []].insert(entry.address)
        }
        return addresses.map { key, addresses in
            let process = processes[key.pid]
            return PortBinding(
                pid: key.pid,
                name: process?.name ?? "PID \(key.pid)",
                path: process?.path,
                ownerName: process?.ownerName,
                proto: key.proto,
                port: key.port,
                addresses: addresses.sorted()
            )
        }
        .sorted { a, b in
            if a.port != b.port { return a.port < b.port }
            if a.proto != b.proto { return a.proto == .tcp }
            return a.pid < b.pid
        }
    }

    /// Matches port number prefix (":3000" or "3000"), protocol, process name or PID prefix.
    public static func filtered(_ bindings: [PortBinding], query: String) -> [PortBinding] {
        var needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return bindings }
        if needle.hasPrefix(":") { needle.removeFirst() }
        return bindings.filter { binding in
            String(binding.port).hasPrefix(needle)
                || binding.proto.rawValue.caseInsensitiveCompare(needle) == .orderedSame
                || binding.name.localizedCaseInsensitiveContains(needle)
                || String(binding.pid).hasPrefix(needle)
        }
    }
}

/// Finds listening sockets by walking each process's file descriptors via libproc.
/// Like the process sampler, only the current user's processes are visible without root.
public struct PortScanner {
    public init() {}

    public func scan() -> [SocketEntry] {
        allPIDs().flatMap(sockets(of:))
    }

    private func sockets(of pid: pid_t) -> [SocketEntry] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }

        return fds.prefix(Int(used) / stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .compactMap { entry(pid: pid, fd: $0.proc_fd) }
    }

    private func entry(pid: pid_t, fd: Int32) -> SocketEntry? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let socket = info.psi

        let proto: PortProtocol
        let inet: in_sockinfo
        switch socket.soi_kind {
        case Int32(SOCKINFO_TCP):
            guard socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            proto = .tcp
            inet = socket.soi_proto.pri_tcp.tcpsi_ini
        case Int32(SOCKINFO_IN) where socket.soi_protocol == IPPROTO_UDP:
            inet = socket.soi_proto.pri_in
            // Connected UDP sockets are clients, not services holding a port.
            guard inet.insi_fport == 0 else { return nil }
            proto = .udp
        default:
            return nil
        }

        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
        guard port != 0 else { return nil }
        return SocketEntry(pid: pid, proto: proto, address: Self.localAddress(inet), port: port)
    }

    private static func localAddress(_ inet: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = inet.insi_laddr.ina_46.i46a_addr4
            if addr.s_addr == 0 { return "*" }
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
        } else {
            var addr = inet.insi_laddr.ina_6
            if withUnsafeBytes(of: addr, { $0.allSatisfy { $0 == 0 } }) { return "*" }
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
