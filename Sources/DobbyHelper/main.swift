import DobbyCore
import Foundation

// Root helper for Dobby: launched via the admin password prompt, serves that app generation until disconnect.
// Usage: DobbyHelper --connect <socket path> --client-pid <pid> --client-start-time <start token>

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

guard let socketPath = value(after: "--connect"),
      let clientPID = value(after: "--client-pid").flatMap(pid_t.init), clientPID > 1,
      let clientStartTime = value(after: "--client-start-time").flatMap(UInt64.init), clientStartTime > 0 else {
    FileHandle.standardError.write(Data("usage: DobbyHelper --connect <socket> --client-pid <pid> --client-start-time <start token>\n".utf8))
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
let clientIdentity = ProcessIdentity(pid: clientPID, startTime: clientStartTime)
exit(HelperServer.run(socketPath: socketPath, clientIdentity: clientIdentity) == .clientDisconnected ? 0 : 1)
