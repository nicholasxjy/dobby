import DobbyCore
import Foundation

// Root helper for Dobby: launched via the admin password prompt, serves the app until it disconnects.
// Usage: DobbyHelper --connect <socket path> --client-pid <app pid>

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

guard let socketPath = value(after: "--connect"), let clientPID = value(after: "--client-pid").flatMap(pid_t.init) else {
    FileHandle.standardError.write(Data("usage: DobbyHelper --connect <socket> --client-pid <pid>\n".utf8))
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
exit(HelperServer.run(socketPath: socketPath, clientPID: clientPID) == .clientDisconnected ? 0 : 1)
