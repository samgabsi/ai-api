import Foundation
import UniformTypeIdentifiers

public struct ChatMessage: Identifiable, Codable {
    public var id: UUID = UUID()
    public let role: String
    public var content: String
    public var attachments: [ChatImageAttachment]? = nil
    public init(id: UUID = UUID(), role: String, content: String, attachments: [ChatImageAttachment]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
    }
}

public struct ChatImageAttachment: Identifiable, Codable {
    public let id: UUID
    public let filename: String
    public let bytes: Int
    public let mimeType: String
    public let dataBase64: String

    public init(id: UUID = UUID(), filename: String, bytes: Int, mimeType: String, dataBase64: String) {
        self.id = id
        self.filename = filename
        self.bytes = bytes
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
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

    private func base64ImageURL(from upload: BashImageUpload) -> String {
        let mime = upload.mimeType ?? "image/png"
        let b64 = upload.data.base64EncodedString()
        return "data:\(mime);base64,\(b64)"
    }

    public func streamChat(model: String, messages: [ChatMessage], images: [BashImageUpload], temperature: Double = 0.2) async throws -> StreamResponse {
        guard let apiKey = apiKeyProvider(), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build message payload allowing multimodal for the last user message when images are present
        var wireMessages: [[String: Any]] = []
        for (idx, msg) in messages.enumerated() {
            if idx == messages.count - 1 && msg.role == "user" && !images.isEmpty {
                var contentParts: [[String: Any]] = []
                let textPart: [String: Any] = [
                    "type": "text",
                    "text": msg.content
                ]
                contentParts.append(textPart)
                for img in images {
                    let url = base64ImageURL(from: img)
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": url]
                    ])
                }
                wireMessages.append([
                    "role": msg.role,
                    "content": contentParts
                ])
            } else {
                wireMessages.append([
                    "role": msg.role,
                    "content": msg.content
                ])
            }
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": wireMessages,
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
