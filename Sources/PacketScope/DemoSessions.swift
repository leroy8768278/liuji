import Foundation

enum DemoSessions {
    static func make() -> [CaptureSession] {
        let start = Date()
        return [
            make(start, -9, "GET", "http://api.example.test/v1/overview", 200, 0.049,
                 response: #"{"projects": 3, "active": 2, "region": "local"}"#),
            make(start, -8, "GET", "http://assets.example.test/styles/main.css", 200, 0.013,
                 response: "body { margin: 0; color: #16383b; }", type: "text/css"),
            make(start, -7, "GET", "http://api.example.test/v1/projects?limit=10", 200, 0.072,
                 response: #"{"projects":[{"id":"p_001","name":"工作台","status":"active"},{"id":"p_002","name":"开放平台","status":"active"}],"nextCursor":null}"#),
            make(start, -6, "POST", "http://api.example.test/v1/events", 201, 0.136,
                 request: #"{"event":"page_view","page":"/projects"}"#, response: #"{"accepted":true,"id":"evt_021"}"#),
            make(start, -5, "GET", "http://assets.example.test/favicon.ico", 404, 0.021,
                 response: #"{"error":"resource_not_found"}"#),
            make(start, -4, "CONNECT", "https://auth.example.test:443", 200, 0.214, tunnel: true),
            make(start, -3.8, "CONNECT", "https://auth.example.test:443", 200, 0.485, tunnel: true, device: .phone),
            make(start, -3.5, "CONNECT", "https://media.example.test:443", 200, 0.381, tunnel: true, device: .phone),
            make(start, -3, "GET", "http://api.example.test/v1/metrics", 200, 0.062,
                 response: #"{"requestCount":24,"errorCount":1,"p95Ms":136}"#),
            make(start, -2, "GET", "http://api.example.test/v1/health", 200, 0.007,
                 response: #"{"status":"ready"}"#)
        ]
    }

    private static func make(
        _ start: Date, _ offset: TimeInterval, _ method: String, _ url: String, _ code: Int, _ duration: TimeInterval,
        request: String = "", response: String = "", type: String = "application/json", tunnel: Bool = false,
        device: CaptureDevice = .mac
    ) -> CaptureSession {
        let requestBody = Data(request.utf8)
        let responseBody = Data(response.utf8)
        let host = URL(string: url)?.host ?? ""
        var requestHeaders = [CaptureHeader(name: "Host", value: host)]
        if !tunnel { requestHeaders.append(CaptureHeader(name: "Accept", value: "*/*")) }
        if !requestBody.isEmpty { requestHeaders.append(CaptureHeader(name: "Content-Type", value: "application/json")) }
        let responseHeaders = tunnel ? [] : [
            CaptureHeader(name: "Content-Type", value: type),
            CaptureHeader(name: "Content-Length", value: String(responseBody.count)),
            CaptureHeader(name: "Cache-Control", value: "no-cache")
        ]
        return CaptureSession(
            id: UUID(), startedAt: start.addingTimeInterval(offset), method: method, url: url,
            requestHeaders: requestHeaders, requestBody: requestBody, statusCode: code,
            responseHeaders: responseHeaders, responseBody: responseBody,
            responseBytes: tunnel ? 4_218 : responseBody.count, elapsed: duration, isTunnel: tunnel, finished: true,
            requestHTTPVersion: "HTTP/1.1", responseHTTPVersion: "HTTP/1.1",
            responseStatusText: tunnel ? "Connection Established" : HTTPURLResponse.localizedString(forStatusCode: code),
            requestBodyBytes: requestBody.count, device: device
        )
    }
}
