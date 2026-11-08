import Darwin
import Foundation

/// Bytes per second, using the same binary units as memory throughout Dobby.
public struct NetworkRate: Equatable, Sendable {
    public let upload: Double
    public let download: Double

    public init(upload: Double, download: Double) {
        self.upload = upload
        self.download = download
    }

    public static let zero = NetworkRate(upload: 0, download: 0)
    public var total: Double { upload + download }
}

public struct NetworkCounters: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }

    public func rate(since previous: Self, seconds: Double) -> NetworkRate {
        guard seconds > 0 else { return .zero }
        // A counter can reset when an interface reconnects or a process restarts.
        return NetworkRate(
            upload: sent >= previous.sent ? Double(sent - previous.sent) / seconds : 0,
            download: received >= previous.received ? Double(received - previous.received) / seconds : 0
        )
    }
}

public enum NetworkStats {
    /// Physical Ethernet / Wi-Fi and PPP interfaces. Skip loopback, bridges and VPN tunnels so
    /// the same packet isn't counted again on a virtual interface. Counters are 64-bit.
    public static func interfaces() -> [UInt16: NetworkCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            var result: [UInt16: NetworkCounters] = [:]
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { return nil }
                defer { offset += length }
                guard header.ifm_type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size else { continue }
                let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(info.ifm_index), &name) != nil else { continue }
                let interface = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard interface.hasPrefix("en") || info.ifm_data.ifi_type == IFT_PPP else { continue }
                result[info.ifm_index] = NetworkCounters(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
            }
            return result
        }
    }

    /// Difference each interface separately: additions, removals and resets must not cause spikes.
    public static func rate(previous: [UInt16: NetworkCounters], current: [UInt16: NetworkCounters], seconds: Double) -> NetworkRate {
        var upload = 0.0
        var download = 0.0
        for (id, counters) in current {
            guard let old = previous[id] else { continue }
            let rate = counters.rate(since: old, seconds: seconds)
            upload += rate.upload
            download += rate.download
        }
        return NetworkRate(upload: upload, download: download)
    }
}

/// Uses macOS's socket accounting without installing a privileged service. Only run for the open Network tab.
public enum NetworkProcessSampler {
    enum SamplingError: Error { case unavailable, invalidOutput }

    public static func sample(seconds: Int) async throws -> [pid_t: NetworkRate] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "2", "-s", String(seconds), "-n", "-x", "-t", "external", "-J", "bytes_in,bytes_out"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        return try await withTaskCancellationHandler {
            let output = await Task.detached(priority: .utility) {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return data
            }.value
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw SamplingError.unavailable }
            return try rates(from: String(decoding: output, as: UTF8.self), seconds: Double(seconds))
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// nettop repeats its header for each sample; the final dot separates a process name from its PID.
    static func rates(from output: String, seconds: Double) throws -> [pid_t: NetworkRate] {
        var snapshots: [[pid_t: NetworkCounters]] = []
        for line in output.split(whereSeparator: \.isNewline) {
            var columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if columns.last == "" { columns.removeLast() }
            if columns == ["", "bytes_in", "bytes_out"] {
                snapshots.append([:])
                continue
            }
            guard !snapshots.isEmpty, columns.count >= 3,
                  let sent = UInt64(columns[columns.count - 1]),
                  let received = UInt64(columns[columns.count - 2]) else { throw SamplingError.invalidOutput }
            let label = columns.dropLast(2).joined(separator: ",").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let suffix = label.split(separator: ".").last, let pid = pid_t(suffix), pid > 0 else {
                throw SamplingError.invalidOutput
            }
            snapshots[snapshots.count - 1][pid] = NetworkCounters(received: received, sent: sent)
        }
        guard snapshots.count == 2 else { throw SamplingError.invalidOutput }
        return snapshots[1].reduce(into: [pid_t: NetworkRate]()) { result, entry in
            result[entry.key] = snapshots[0][entry.key].map { entry.value.rate(since: $0, seconds: seconds) } ?? .zero
        }
    }
}
