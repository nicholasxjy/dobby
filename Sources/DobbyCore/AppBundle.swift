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
}
