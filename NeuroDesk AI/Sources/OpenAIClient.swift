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

    public func streamChat(model: String, messages: [ChatMessage], temperature: Double = 0.2) async throws -> AsyncThrowingStream<String, Error> {
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

            return AsyncThrowingStream { continuation in
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
}
