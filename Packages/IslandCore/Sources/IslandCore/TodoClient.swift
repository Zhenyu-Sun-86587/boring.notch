import Foundation

public struct TodoProject: Decodable, Sendable, Equatable {
    public let id: Int
    public let title: String
    public let hexColor: String?
    enum CodingKeys: String, CodingKey { case id, title; case hexColor = "hex_color" }
}

public struct TodoTask: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let projectID: Int
    public let title: String
    public let done: Bool
    public let dueDate: String?
    public let description: String?
    public let priority: Int?
    enum CodingKeys: String, CodingKey {
        case id, title, done, description, priority
        case projectID = "project_id", dueDate = "due_date"
    }
    public var due: Date? {
        guard let dueDate, !dueDate.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dueDate) ?? ISO8601DateFormatter().date(from: dueDate)
    }
}

public struct TodoConfiguration: Sendable {
    public let baseURL: URL
    public let token: String
    public let accessClientID: String
    public let accessClientSecret: String
    public let excludedProjectIDs: Set<Int>
    /// baseURL is the instance root, e.g. https://todo.example.com (not /dav or /api/v1).
    public init(baseURL: URL, token: String, accessClientID: String = "", accessClientSecret: String = "",
                excludedProjectIDs: Set<Int> = [3]) {
        self.baseURL = baseURL; self.token = token
        self.accessClientID = accessClientID; self.accessClientSecret = accessClientSecret
        self.excludedProjectIDs = excludedProjectIDs.union([3])
    }
}

public protocol TodoServiceProviding: Sendable {
    func projects() async throws -> [TodoProject]
    func tasks() async throws -> [TodoTask]
    func setCompleted(taskID: Int, completed: Bool) async throws
}

public actor VikunjaClient: TodoServiceProviding {
    private let configuration: TodoConfiguration
    private let transport: any HTTPTransport
    private var apiVersion: Int?
    public init(configuration: TodoConfiguration, transport: any HTTPTransport = SessionTransport()) {
        self.configuration = configuration; self.transport = transport
    }

    private func request(_ path: String, version: Int, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/v\(version)/\(path)"))
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !configuration.token.isEmpty { request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization") }
        if !configuration.accessClientID.isEmpty {
            request.setValue(configuration.accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(configuration.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return request
    }

    private func version() async throws -> Int {
        if let apiVersion { return apiVersion }
        let probe = try await transport.execute(request("openapi.json", version: 2))
        if [404, 405].contains(probe.status) { apiVersion = 1; return 1 }
        let validated = try probe.validated()
        guard let object = try JSONSerialization.jsonObject(with: validated.data) as? [String: Any],
              object["openapi"] != nil else { throw IslandError.invalidResponse }
        apiVersion = 2
        return 2
    }

    private func list<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> [T] {
        let version = try await version()
        var output: [T] = []
        for page in 1...100 {
            var request = request(path, version: version)
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw IslandError.invalidResponse }
            components.queryItems = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: "100")]
            if path == "tasks" {
                components.queryItems?.append(URLQueryItem(name: "filter", value: configuration.excludedProjectIDs.sorted().map { "project != \($0)" }.joined(separator: " && ")))
            }
            request.url = components.url
            let result = try await transport.execute(request).validated()
            if version == 2 {
                let envelope = try JSONDecoder().decode(Page<T>.self, from: result.data)
                output.append(contentsOf: envelope.items)
                if envelope.items.isEmpty || page >= envelope.total_pages { return output }
            } else {
                let items = try JSONDecoder().decode([T].self, from: result.data)
                output.append(contentsOf: items)
                if items.isEmpty || page >= (Int(result.headers["x-pagination-total-pages"] ?? "") ?? (items.count < 100 ? page : page + 1)) { return output }
            }
        }
        throw IslandError.limit("待办结果超过分页上限，请缩小项目范围。")
    }
    private struct Page<T: Decodable>: Decodable { let items: [T]; let total_pages: Int }

    public func projects() async throws -> [TodoProject] {
        try await list("projects", as: TodoProject.self).filter { !configuration.excludedProjectIDs.contains($0.id) && $0.id > 0 }
    }
    public func tasks() async throws -> [TodoTask] {
        let tasks = try await list("tasks", as: TodoTask.self)
        var seen: Set<Int> = []
        return tasks.filter { $0.projectID > 0 && !configuration.excludedProjectIDs.contains($0.projectID) && seen.insert($0.id).inserted }
    }
    public func setCompleted(taskID: Int, completed: Bool) async throws {
        let version = try await version()
        let latest = try await transport.execute(request("tasks/\(taskID)", version: version)).validated()
        let task = try JSONDecoder().decode(TodoTask.self, from: latest.data)
        guard task.id == taskID, task.projectID > 0, !configuration.excludedProjectIDs.contains(task.projectID) else {
            throw IslandError.configuration("禁止修改副本池或无效项目中的任务。")
        }
        var update: URLRequest
        if version == 2 {
            update = request("tasks/\(taskID)", version: version, method: "PATCH",
                             body: try JSONSerialization.data(withJSONObject: ["done": completed]))
            guard let etag = latest.headers["etag"] else {
                throw IslandError.configuration("服务未提供 ETag，无法安全更新任务。")
            }
            update.setValue(etag, forHTTPHeaderField: "If-Match")
        } else {
            guard var object = try JSONSerialization.jsonObject(with: latest.data) as? [String: Any] else { throw IslandError.invalidResponse }
            object["done"] = completed
            update = request("tasks/\(taskID)", version: version, method: "POST", body: try JSONSerialization.data(withJSONObject: object))
        }
        _ = try await transport.execute(update).validated()
    }
}
