import Foundation

/// Read-only API client. Every call is a GET. 401 -> AuthError (so the gate can
/// route to Setup). 204 -> nil. Any other non-2xx or transport failure -> APIError.

struct AuthError: Error {}

enum APIError: Error, LocalizedError {
    case httpStatus(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .message(let m): return m
        }
    }
}

/// Thrown internally for a 204 No Content so the generic decoder is skipped.
private struct NoContent: Error {}

enum APIClient {
    // NOTE: no global keyDecodingStrategy. Typed structs carry their own
    // CodingKeys so that untyped JSONValue dicts (info/metrics/executions/
    // payload) keep the server's raw keys — JsonView shows verbatim JSON.
    private static let decoder = JSONDecoder()

    /// GET `path`, decoding the JSON body as `T`.
    static func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await fetchData(path)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.message("Malformed response: \(friendly(error))")
        }
    }

    /// GET `path`, returning nil on 204 (no body) instead of decoding.
    static func getOptional<T: Decodable>(_ path: String) async throws -> T? {
        do {
            let data = try await fetchData(path)
            return try decoder.decode(T.self, from: data)
        } catch is NoContent {
            return nil
        } catch {
            throw APIError.message("Malformed response: \(friendly(error))")
        }
    }

    /// GET that returns raw rows wrapped in `{ rows: [...] }`.
    static func getRows<T: Decodable>(_ path: String) async throws -> [T] {
        let list: RowList<T> = try await get(path)
        return list.rows
    }

    // MARK: - Transport

    private static func fetchData(_ path: String) async throws -> Data {
        let base = Credentials.baseURL
        guard let url = makeURL(base: base, path: path) else {
            throw APIError.message("Invalid server URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !Credentials.token.isEmpty {
            request.setValue("Bearer " + Credentials.token, forHTTPHeaderField: "Authorization")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.message(
                "Cannot reach the dashboard API. Check the server URL and that the host is reachable from this device."
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("Unexpected response from server.")
        }
        if http.statusCode == 401 { throw AuthError() }
        if http.statusCode == 204 { throw NoContent() }
        if !(200...299).contains(http.statusCode) {
            throw APIError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Compose the base + path. Accepts a path starting with "/" or not; also
    /// appends any query string already present in `path`.
    static func makeURL(base: String, path: String) -> URL? {
        let trimmedPath = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + trimmedPath) else { return nil }
        return url
    }

    /// Build a GET path with optional query params (skips nil/empty values).
    /// Uses URLComponents so values are percent-encoded correctly (a value
    /// containing "&" or "=" does not corrupt the query string).
    static func buildPath(_ base: String, params: [(String, String?)]) -> String {
        let items = params.compactMap { (k, v) -> URLQueryItem? in
            guard let v, !v.isEmpty else { return nil }
            return URLQueryItem(name: k, value: v)
        }
        guard !items.isEmpty else { return base }
        var comp = URLComponents(string: base) ?? URLComponents()
        comp.queryItems = items
        return comp.string ?? base
    }

    private static func friendly(_ error: Error) -> String {
        if let dec = error as? DecodingError {
            return String(describing: dec)
        }
        return error.localizedDescription
    }
}
