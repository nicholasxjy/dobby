public enum AppBundle {
    /// "/Applications/X.app/Contents/Frameworks/Y.app/Contents/MacOS/Y" -> "/Applications/X.app"
    public static func outermostAppPath(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    public static func displayName(ofAppPath appPath: String) -> String {
        let last = appPath.split(separator: "/").last.map(String.init) ?? appPath
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Name of the app an executable helps, or nil when it is the app's main executable or not part of an app.
    public static func owningAppName(ofExecutable path: String) -> String? {
        guard let appPath = outermostAppPath(in: path) else { return nil }
        let mainExecutableDir = appPath + "/Contents/MacOS/"
        if path.hasPrefix(mainExecutableDir), !path.dropFirst(mainExecutableDir.count).contains("/") {
            return nil
        }
        return displayName(ofAppPath: appPath)
    }
}
