public enum UsageCalculator {
    /// Derives CPU percent from the CPU time each process consumed between two snapshots.
    /// Processes absent from `previous` (or whose PID was reused) report 0% until the next sample.
    public static func usages(previous: [ProcessSnapshot], current: [ProcessSnapshot], elapsedNanos: UInt64) -> [ProcessUsage] {
        let previousByPID = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        return current.map { snapshot in
            var percent = 0.0
            if elapsedNanos > 0,
               let before = previousByPID[snapshot.pid],
               before.name == snapshot.name,
               snapshot.cpuTimeNanos >= before.cpuTimeNanos {
                percent = Double(snapshot.cpuTimeNanos - before.cpuTimeNanos) / Double(elapsedNanos) * 100
            }
            return ProcessUsage(
                pid: snapshot.pid,
                name: snapshot.name,
                path: snapshot.path,
                uid: snapshot.uid,
                cpuPercent: percent,
                memoryBytes: snapshot.memoryBytes
            )
        }
    }
}
