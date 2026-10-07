import Foundation
import Testing
@testable import DobbyCore

@Suite struct PortListTests {
    let entries = [
        SocketEntry(pid: 10, proto: .tcp, address: "127.0.0.1", port: 3000),
        SocketEntry(pid: 10, proto: .tcp, address: "::1", port: 3000),
        SocketEntry(pid: 11, proto: .tcp, address: "127.0.0.1", port: 8080),
        SocketEntry(pid: 11, proto: .tcp, address: "*", port: 8080),
        SocketEntry(pid: 12, proto: .udp, address: "192.168.1.5", port: 5353),
        SocketEntry(pid: 12, proto: .tcp, address: "*", port: 22),
        SocketEntry(pid: 13, proto: .udp, address: "*", port: 22),
    ]
    let processes: [pid_t: ProcessUsage] = [
        10: usage(10, "node", path: "/opt/homebrew/bin/node"),
        11: usage(11, "Docker", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", uid: 0, owner: "root"),
    ]

    @Test func mergesAddressFamiliesAndSortsByPort() {
        let bindings = PortList.bindings(from: entries, processes: processes)
        #expect(bindings.map(\.port) == [22, 22, 3000, 5353, 8080])
        #expect(bindings.map(\.proto) == [.tcp, .udp, .tcp, .udp, .tcp])

        let node = bindings[2]
        #expect(node.pid == 10)
        #expect(node.name == "node")
        #expect(node.addresses == ["127.0.0.1", "::1"])
        #expect(node.exposure == .loopback)
    }

    @Test func classifiesExposure() {
        let bindings = PortList.bindings(from: entries, processes: processes)
        #expect(bindings.first { $0.port == 8080 }?.exposure == .allInterfaces)
        #expect(bindings.first { $0.port == 5353 }?.exposure == .specific)
    }

    @Test func fallsBackToPIDWhenProcessNameUnknown() {
        let bindings = PortList.bindings(from: entries, processes: processes)
        #expect(bindings.first { $0.pid == 12 }?.name == "PID 12")
        #expect(bindings.first { $0.pid == 11 }?.appBundlePath == "/Applications/Docker.app")
        #expect(bindings.first { $0.pid == 11 }?.ownerName == "root")
    }

    @Test func idsAreUniquePerProcessProtocolAndPort() {
        let ids = PortList.bindings(from: entries, processes: processes).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func filtersByPortNamePIDOrColonPrefixedPort() {
        let bindings = PortList.bindings(from: entries, processes: processes)
        #expect(PortList.filtered(bindings, query: "300").map(\.port) == [3000])
        #expect(PortList.filtered(bindings, query: ":8080").map(\.pid) == [11])
        #expect(PortList.filtered(bindings, query: "NODE").map(\.port) == [3000])
        #expect(PortList.filtered(bindings, query: "udp").map(\.port) == [22, 5353])
        #expect(PortList.filtered(bindings, query: "").count == 5)
    }
}

/// Opens real sockets and checks the libproc-based scanner reports exactly the listening ones.
@Suite(.serialized) struct PortScannerLiveTests {
    private func makeSocket(_ type: Int32, ipv6: Bool, loopback: Bool) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, type, 0)
        try #require(fd >= 0)
        var bound: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = loopback ? inet_addr("127.0.0.1") : INADDR_ANY
            bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        try #require(bound == 0)
        if type == SOCK_STREAM { try #require(listen(fd, 4) == 0) }
        return (fd, localPort(fd))
    }

    private func localPort(_ fd: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
    }

    private func mine(_ port: UInt16) -> [SocketEntry] {
        PortScanner().scan().filter { $0.pid == getpid() && $0.port == port }
    }

    @Test func findsLoopbackTCPListener() throws {
        let (fd, port) = try makeSocket(SOCK_STREAM, ipv6: false, loopback: true)
        defer { close(fd) }
        #expect(mine(port) == [SocketEntry(pid: getpid(), proto: .tcp, address: "127.0.0.1", port: port)])
    }

    @Test func reportsIPv6WildcardAsStar() throws {
        let (fd, port) = try makeSocket(SOCK_STREAM, ipv6: true, loopback: false)
        defer { close(fd) }
        #expect(mine(port) == [SocketEntry(pid: getpid(), proto: .tcp, address: "*", port: port)])
    }

    @Test func findsBoundUDPSocket() throws {
        let (fd, port) = try makeSocket(SOCK_DGRAM, ipv6: false, loopback: true)
        defer { close(fd) }
        #expect(mine(port) == [SocketEntry(pid: getpid(), proto: .udp, address: "127.0.0.1", port: port)])
    }

    @Test func ignoresConnectionsAndClosedListeners() throws {
        let (listener, port) = try makeSocket(SOCK_STREAM, ipv6: false, loopback: true)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(connected == 0)
        let accepted = accept(listener, nil, nil)
        defer { close(client); close(accepted) }

        // Only the listener counts; the accepted socket shares the local port but is ESTABLISHED.
        #expect(mine(port).count == 1)
        close(listener)
        #expect(mine(port).isEmpty)
    }

    @Test func endingTheOwningProcessFreesThePort() throws {
        // Reserve a free port number, then let a child process listen on it.
        let (probe, port) = try makeSocket(SOCK_STREAM, ipv6: false, loopback: true)
        close(probe)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        child.arguments = ["-l", "127.0.0.1", String(port)]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        var found: [SocketEntry] = []
        for _ in 0..<50 where found.isEmpty {
            usleep(20_000)
            found = PortScanner().scan().filter { $0.port == port && $0.proto == .tcp }
        }
        #expect(found.map(\.pid) == [child.processIdentifier])

        try ProcessTerminator().terminate(child.processIdentifier, mode: .quit)
        child.waitUntilExit()
        #expect(PortScanner().scan().filter { $0.port == port && $0.proto == .tcp }.isEmpty)
    }
}
