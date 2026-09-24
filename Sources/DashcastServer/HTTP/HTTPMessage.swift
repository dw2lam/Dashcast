import Foundation

// Minimal HTTP/1.1: enough to serve the client page, /healthz and the WebSocket upgrade.

struct HTTPHeaders: Equatable, Sequence {
    struct Field: Equatable {
        var name: String
        var value: String
    }

    private(set) var fields: [Field] = []

    init(_ pairs: [(String, String)] = []) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }

    mutating func add(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    /// Case-insensitive lookup; repeated headers are joined with ", " (RFC 9110 §5.3).
    subscript(_ name: String) -> String? {
        let matches = fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard !matches.isEmpty else { return nil }
        return matches.map(\.value).joined(separator: ", ")
    }

    /// Comma-separated tokens of a header, lowercased and trimmed (e.g. `Connection: keep-alive, Upgrade`).
    func tokens(_ name: String) -> [String] {
        guard let value = self[name] else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    func makeIterator() -> IndexingIterator<[Field]> { fields.makeIterator() }
}

struct HTTPRequest: Equatable {
    var method: String
    /// Raw request-target as sent.
    var target: String
    /// Percent-decoded path without the query.
    var path: String
    var query: String?
    var version: String
    var headers: HTTPHeaders

    /// HTTP/1.1 defaults to persistent connections; HTTP/1.0 needs `Connection: keep-alive`.
    var keepAlive: Bool {
        let connection = headers.tokens("Connection")
        if connection.contains("close") { return false }
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return true
    }

    var isWebSocketUpgrade: Bool {
        headers.tokens("Upgrade").contains("websocket") && headers.tokens("Connection").contains("upgrade")
    }
}

enum HTTPParseResult: Equatable {
    case incomplete
    /// `consumed` counts every byte of the request, including any (ignored) body.
    case complete(HTTPRequest, consumed: Int)
    case invalid(status: Int, reason: String)
}

enum HTTPRequestParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024

    static func parse(_ bytes: [UInt8]) -> HTTPParseResult {
        bytes.withUnsafeBufferPointer { parse($0) }
    }

    static func parse(_ buffer: UnsafeBufferPointer<UInt8>) -> HTTPParseResult {
        // Find the end of the header block: an empty line (CRLF CRLF, tolerating bare LF).
        var headerEnd: Int?     // index of the first byte after the blank line
        var i = 0
        let n = buffer.count
        while i < n {
            if buffer[i] == 0x0A {
                if i + 1 < n, buffer[i + 1] == 0x0A { headerEnd = i + 2; break }
                if i + 2 < n, buffer[i + 1] == 0x0D, buffer[i + 2] == 0x0A { headerEnd = i + 3; break }
            }
            i += 1
        }
        guard let end = headerEnd else {
            return n > maxHeaderBytes ? .invalid(status: 431, reason: "Request Header Fields Too Large") : .incomplete
        }
        guard end <= maxHeaderBytes else { return .invalid(status: 431, reason: "Request Header Fields Too Large") }

        // Split on LF bytes (a Swift Character treats CRLF as one grapheme, so split bytes, not text).
        var lines: [Substring] = []
        var lineStart = 0
        for j in 0..<end where buffer[j] == 0x0A {
            var lineEnd = j
            if lineEnd > lineStart, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            lines.append(Substring(String(decoding: UnsafeBufferPointer(rebasing: buffer[lineStart..<lineEnd]), as: UTF8.self)))
            lineStart = j + 1
        }
        // RFC 9112 §2.2: ignore empty lines before the request line.
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else { return .invalid(status: 400, reason: "Bad Request") }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .invalid(status: 400, reason: "Bad Request") }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard !method.isEmpty, method.allSatisfy(isTokenChar) else { return .invalid(status: 400, reason: "Bad Request") }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .invalid(status: 505, reason: "HTTP Version Not Supported")
        }
        guard !target.isEmpty else { return .invalid(status: 400, reason: "Bad Request") }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" { return .invalid(status: 400, reason: "Bad Request") } // obs-fold
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, reason: "Bad Request") }
            let name = line[..<colon]
            guard !name.isEmpty, name.allSatisfy(isTokenChar) else { return .invalid(status: 400, reason: "Bad Request") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.add(String(name), value)
        }

        if headers["Transfer-Encoding"] != nil { return .invalid(status: 501, reason: "Not Implemented") }
        var bodyLength = 0
        if let cl = headers["Content-Length"] {
            guard let value = Int(cl.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return .invalid(status: 400, reason: "Bad Request")
            }
            guard value <= maxBodyBytes else { return .invalid(status: 413, reason: "Content Too Large") }
            bodyLength = value
        }
        guard n >= end + bodyLength else { return .incomplete }

        guard let (path, query) = splitTarget(target) else { return .invalid(status: 400, reason: "Bad Request") }
        let request = HTTPRequest(method: method, target: target, path: path, query: query, version: version, headers: headers)
        return .complete(request, consumed: end + bodyLength)
    }

    /// Splits origin-form (`/a/b?x=1`) or absolute-form (`http://host/a?x`) targets.
    static func splitTarget(_ target: String) -> (String, String?)? {
        var rest = Substring(target)
        if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
            let afterScheme = rest[rest.range(of: "://")!.upperBound...]
            if let slash = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) {
                rest = afterScheme[slash...]
                if rest.first == "?" { rest = "/" + rest }
            } else {
                rest = "/"
            }
        } else if target == "*" {
            return ("*", nil)
        }
        guard rest.first == "/" else { return nil }
        var query: String?
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        guard let decoded = String(rest).removingPercentEncoding else { return nil }
        return (decoded, query)
    }

    private static func isTokenChar(_ c: Character) -> Bool {
        guard let a = c.asciiValue, a > 0x20, a < 0x7F else { return false }
        return !"\"(),/:;<=>?@[\\]{}".contains(c)
    }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: HTTPHeaders
    var body: Data

    init(status: Int, reason: String? = nil, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.reason = reason ?? HTTPResponse.reasonPhrase(status)
        self.headers = HTTPHeaders(headers)
        self.body = body
    }

    static func text(_ status: Int, _ text: String, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", contentType)], body: Data(text.utf8))
    }

    /// Serializes the response. `Content-Length`, `Cache-Control: no-store` and `Connection` are added
    /// unless already present (101 responses get neither length nor cache headers).
    func serialized(includeBody: Bool = true, keepAlive: Bool) -> Data {
        var out = "HTTP/1.1 \(status) \(reason)\r\n"
        var headers = headers
        if status != 101 {
            if headers["Content-Length"] == nil { headers.add("Content-Length", String(body.count)) }
            if headers["Cache-Control"] == nil { headers.add("Cache-Control", "no-store") }
            if headers["Connection"] == nil { headers.add("Connection", keepAlive ? "keep-alive" : "close") }
            if headers["X-Content-Type-Options"] == nil { headers.add("X-Content-Type-Options", "nosniff") }
        }
        for field in headers { out += "\(field.name): \(field.value)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        if includeBody { data.append(body) }
        return data
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 301: return "Moved Permanently"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 426: return "Upgrade Required"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status \(status)"
        }
    }
}

enum MIMEType {
    static func forPathExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "wasm": return "application/wasm"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "wav": return "audio/wav"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
