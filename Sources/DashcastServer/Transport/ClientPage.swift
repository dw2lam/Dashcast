import Foundation

/// Finds the built web client and serves `index.html` (plus any sibling assets).
///
/// Lookup order: explicit directory (tests/app), `Bundle.main.resourceURL/client`,
/// `$DASHCAST_CLIENT_DIR`, then `Web/dist` found by walking up from the executable and the current
/// directory. Falls back to an inline page explaining that the client isn't built.
/// Files are re-read on every request so a rebuilt client shows up without restarting.
final class ClientPageProvider {
    struct Page {
        var data: Data
        var contentType: String
        /// Where it came from (for logs).
        var source: String
    }

    private let explicitDirectory: URL?
    private var cachedDirectory: URL?

    init(directory: URL?) {
        explicitDirectory = directory
    }

    func indexPage() -> Page {
        if let dir = resolveDirectory(), let data = try? Data(contentsOf: dir.appendingPathComponent("index.html")) {
            return Page(data: data, contentType: MIMEType.forPathExtension("html"), source: dir.path)
        }
        return Page(data: Data(Self.fallbackHTML.utf8), contentType: MIMEType.forPathExtension("html"), source: "inline fallback")
    }

    /// A static file below the client directory (no traversal, no dotfiles), or nil.
    func staticFile(path: String) -> Page? {
        guard let dir = resolveDirectory() else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") || $0.contains("\\") }) else { return nil }
        let url = components.reduce(dir) { $0.appendingPathComponent(String($1)) }
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else { return nil }
        return Page(data: data, contentType: MIMEType.forPathExtension(url.pathExtension), source: resolved)
    }

    func resolveDirectory() -> URL? {
        if let cached = cachedDirectory, Self.hasIndex(cached) { return cached }
        cachedDirectory = Self.candidateDirectories(explicit: explicitDirectory).first(where: Self.hasIndex)
        return cachedDirectory
    }

    static func hasIndex(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path)
    }

    static func candidateDirectories(explicit: URL?) -> [URL] {
        var dirs: [URL] = []
        if let explicit { dirs.append(explicit) }
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("client", isDirectory: true)) }
        if let env = ProcessInfo.processInfo.environment["DASHCAST_CLIENT_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true))
        }
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL { starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
        if let arg0 = CommandLine.arguments.first, arg0.hasPrefix("/") {
            starts.append(URL(fileURLWithPath: arg0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        for start in starts {
            var dir = start.standardizedFileURL
            for _ in 0..<12 {
                dirs.append(dir.appendingPathComponent("Web/dist", isDirectory: true))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return dirs
    }

    static let fallbackHTML = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Dashcast</title>
    <style>
      :root { color-scheme: dark; }
      body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0b0b0c;
             color: #e8e8ea; font: 18px/1.5 -apple-system, system-ui, sans-serif; }
      main { max-width: 34rem; padding: 2rem; }
      h1 { font-size: 1.6rem; margin: 0 0 .5rem; }
      code { background: #1c1c1f; padding: .1rem .35rem; border-radius: 4px; }
      p { color: #a8a8ad; }
    </style>
    </head>
    <body>
    <main>
      <h1>Dashcast is running</h1>
      <p>The in-car web client hasn't been built, so there's nothing to stream to yet.</p>
      <p>Build it with <code>cd Web &amp;&amp; npm run build</code>, or point
         <code>DASHCAST_CLIENT_DIR</code> at a folder containing <code>index.html</code>.</p>
      <p>Health check: <a href="/healthz" style="color:#8ab4ff">/healthz</a></p>
    </main>
    </body>
    </html>
    """
}
