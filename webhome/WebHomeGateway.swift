import Foundation
import Network

// The fm.res() gateway: a loopback HTTP server in the exact webhtv URL shape,
//   http://127.0.0.1:{port}/webResource?url={encodedUrl}&headers={encodedJson}&credentials=include
// Pages use it for DOM resources (img.src, video.src, subtitles) so the native
// HTTP stack, not the WebView, fetches them with the page's headers.
// Behaviour follows webhtv: only http(s) targets; Range passes through;
// Connection / Transfer-Encoding / Keep-Alive / Content-Length are stripped
// from upstream responses; CORS headers are added. Step 1 serves GET/HEAD
// only (what img/video/subtitle loads need); other methods get 405.
final class WebHomeGateway {
    private var listener: NWListener?
    private(set) var port: Int = 0

    func start() async throws -> Int {
        if port != 0, listener?.state == .ready { return port }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        self.listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data())
            _ = self
        }
        let queue = DispatchQueue(label: "finch.webhome.gateway")
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed, let port = server.port {
                        resumed = true
                        self.port = Int(port.rawValue)
                        continuation.resume(returning: Int(port.rawValue))
                    }
                case .failed(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            server.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// The synchronous fm.res() string for a target URL. Built in JS too, but
    /// native code (fm.play gateway wrapping) uses the same shape.
    func resourceURL(for target: String, headers: [String: String], credentials: String?) -> URL? {
        guard port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/webResource"
        var items = [
            URLQueryItem(name: "url", value: target),
            URLQueryItem(name: "headers", value: (try? JSONSerialization.data(withJSONObject: headers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"),
        ]
        if let credentials, !credentials.isEmpty {
            items.append(URLQueryItem(name: "credentials", value: credentials))
        }
        components.queryItems = items
        return components.url
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                serve(connection, request: bytes)
            } else if error != nil || complete || bytes.count > 65536 {
                connection.cancel()
            } else {
                receive(connection, buffer: bytes)
            }
        }
    }

    private nonisolated static func serve(_ connection: NWConnection, request: Data) {
        let text = String(decoding: request, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2 else { connection.cancel(); return }
        let method = String(fields[0])
        let rawPath = String(fields[1])
        guard let components = URLComponents(string: "http://127.0.0.1" + rawPath),
              components.path == "/webResource",
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: target),
              ["http", "https"].contains(targetURL.scheme?.lowercased() ?? "") else {
            send(connection, status: 404, body: Data("not found".utf8))
            return
        }
        guard method == "GET" || method == "HEAD" else {
            send(connection, status: 405, body: Data("method not allowed".utf8))
            return
        }
        var headers: [String: String] = [:]
        if let encoded = components.queryItems?.first(where: { $0.name == "headers" })?.value,
           let data = encoded.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            headers = object
        }
        // Range passes through verbatim so AVPlayer / img loads can seek.
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = rangeLine.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            headers["Range"] = value
        }
        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = method
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        // The proxy fetch runs async; the NWConnection is captured until the
        // response is sent, then cancelled. No body is expected for GET/HEAD.
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                var responseHeaders: [String: String] = [:]
                if let http = response as? HTTPURLResponse {
                    for (field, value) in http.allHeaderFields {
                        let name = String(describing: field)
                        let lower = name.lowercased()
                        if ["connection", "transfer-encoding", "keep-alive", "content-length"].contains(lower) { continue }
                        responseHeaders[name] = String(describing: value)
                    }
                }
                responseHeaders["Access-Control-Allow-Origin"] = "*"
                responseHeaders["Access-Control-Allow-Headers"] = "*"
                send(connection, status: status, body: method == "HEAD" ? Data() : data, headers: responseHeaders)
            } catch {
                send(connection, status: 502, body: Data("bad gateway".utf8))
            }
        }
    }

    private nonisolated static func send(_ connection: NWConnection, status: Int, body: Data, headers: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (field, value) in headers { head += "\(field): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
