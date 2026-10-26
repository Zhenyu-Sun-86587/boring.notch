import Foundation

public enum IslandError: LocalizedError, Sendable, Equatable {
    case configuration(String), http(Int), authentication, invalidResponse, limit(String), changedFile

    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .limit(let message): return message
        case .http(let status): return "服务器返回 HTTP \(status)。"
        case .authentication: return "服务需要认证，请检查 API Key 或 Cloudflare Access 配置。"
        case .invalidResponse: return "服务返回了无法识别的数据。"
        case .changedFile: return "文件正在被其他应用修改，请稍后重试。"
        }
    }
}

public struct HTTPResult: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data; self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
    }

    public func validated() throws -> HTTPResult {
        if [301, 302, 303, 307, 308, 401, 403].contains(status) { throw IslandError.authentication }
        guard (200..<300).contains(status) else { throw IslandError.http(status) }
        if let contentType = headers["content-type"], contentType.contains("text/html") {
            throw IslandError.authentication
        }
        return self
    }
}

public protocol HTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> HTTPResult
}

/// Credentials are never forwarded to a redirect destination, including an Access login page.
public final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct SessionTransport: HTTPTransport {
    public init() {}
    public func execute(_ request: URLRequest) async throws -> HTTPResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw IslandError.invalidResponse }
        return HTTPResult(data: data, status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) {
            if let key = $1.key as? String { $0[key] = String(describing: $1.value) }
        })
    }
}

public enum ServiceURL {
    public static func parse(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw IslandError.configuration("请先在设置中填写有效的 HTTP(S) 服务地址。")
        }
        return url
    }
}
