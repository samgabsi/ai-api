import Foundation

public struct ChatMessage: Identifiable, Codable {
    public var id: UUID = UUID()
    public let role: String
    public var content: String
    public init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public enum OpenAIError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(status: Int, body: String)
    case networkError(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenAI API key missing."
        case .invalidResponse: return "Invalid streaming response."
        case .httpError(let status, let body): return "HTTP \(status): \(body)"
        case .networkError(let underlying): return "Network error: \(underlying.localizedDescription)"
        }
    }
}

// Surface rate limit information parsed from headers when available.
public struct RateLimitInfo: Sendable {
    public let limit: Int?
    public let remaining: Int?
    public let reset: Date?

    public init(limit: Int?, remaining: Int?, reset: Date?) {
        self.limit = limit
        self.remaining = remaining
        self.reset = reset
    }
}

public struct StreamResponse {
    public let stream: AsyncThrowingStream<String, Error>
    public let rateLimit: RateLimitInfo
}

public final class OpenAIClient {
    private let endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let session: URLSession
    private let apiKeyProvider: () -> String?

    public init(apiKeyProvider: @escaping () -> String?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.apiKeyProvider = apiKeyProvider
    }

    public func streamChat(model: String, messages: [ChatMessage], temperature: Double = 0.2) async throws -> StreamResponse {
        guard let apiKey = apiKeyProvider(), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                var collected = Data()
                for try await chunk in bytes { collected.append(chunk) }
                let body = String(decoding: collected, as: UTF8.self)
                throw OpenAIError.httpError(status: http.statusCode, body: body)
            }

            let rate = Self.parseRateLimit(from: http)

            let stream = AsyncThrowingStream<String, Error> { continuation in
                Task {
                    do {
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonLine = line.dropFirst(6)
                            if jsonLine == "[DONE]" { break }
                            if let data = jsonLine.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = obj["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let token = delta["content"] as? String {
                                continuation.yield(token)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: OpenAIError.networkError(underlying: error))
                    }
                }
            }

            return StreamResponse(stream: stream, rateLimit: rate)
        } catch {
            throw OpenAIError.networkError(underlying: error)
        }
    }

    public func preflightCheck() async throws {
        guard let apiKey = apiKeyProvider(), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.missingAPIKey
        }
        print("[OpenAIClient] Using API key prefix: \(apiKey.prefix(8))")
    }

    private static func parseRateLimit(from response: HTTPURLResponse) -> RateLimitInfo {
        func intHeader(_ name: String) -> Int? {
            if let v = response.value(forHTTPHeaderField: name) {
                return Int(v.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        func dateFromResetHeader(_ name: String) -> Date? {
            if let v = response.value(forHTTPHeaderField: name), let ts = TimeInterval(v) {
                return Date(timeIntervalSince1970: ts)
            }
            return nil
        }

        // Common names (varies by provider/plan)
        let limit = intHeader("X-RateLimit-Limit") ?? intHeader("x-ratelimit-limit")
        let remaining = intHeader("X-RateLimit-Remaining") ?? intHeader("x-ratelimit-remaining")
        let reset = dateFromResetHeader("X-RateLimit-Reset") ?? dateFromResetHeader("x-ratelimit-reset")

        return RateLimitInfo(limit: limit, remaining: remaining, reset: reset)
    }
}

