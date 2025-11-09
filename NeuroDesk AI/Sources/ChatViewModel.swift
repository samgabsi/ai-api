import Foundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    static let apiKeyKeychainKey = "OpenAI.ApiKey"

    @Published var messages: [ChatMessage] = [ChatMessage(role: "system", content: "You are a helpful assistant.")]
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var lastErrorMessage: String?
    @Published var apiKeyPresent: Bool = false

    private let client: OpenAIClient
    private var streamingTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private let chunkFlushSize = 40
    private let punctuationSet = CharacterSet(charactersIn: ".!?,;:\n")

    // File locations
    private let historyURL: URL = {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base?.appendingPathComponent("NeuroDesk AI", isDirectory: true)
        if let dir, !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (dir ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("chat.json")
    }()

    init() {
        client = OpenAIClient(apiKeyProvider: {
            return KeychainHelper.load(key: ChatViewModel.apiKeyKeychainKey)
        })
        self.apiKeyPresent = KeychainHelper.load(key: Self.apiKeyKeychainKey) != nil

        // Load history
        loadHistory()

        // Autosave on changes (debounced)
        $messages
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveHistory()
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    func saveAPIKey(_ key: String) {
        KeychainHelper.save(key: Self.apiKeyKeychainKey, value: key)
        apiKeyPresent = true
    }

    func clearAPIKey() {
        KeychainHelper.delete(key: Self.apiKeyKeychainKey)
        apiKeyPresent = false
    }

    func clearHistory() {
        messages = [ChatMessage(role: "system", content: "You are a helpful assistant.")]
        saveHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        if let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data), !decoded.isEmpty {
            messages = decoded
        }
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    func sendCurrentInput() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputText = ""
        lastErrorMessage = nil
        isSending = true

        let userMsg = ChatMessage(role: "user", content: text)
        messages.append(userMsg)

        let assistantMsg = ChatMessage(role: "assistant", content: "")
        messages.append(assistantMsg)
        let assistantMsgId = assistantMsg.id

        streamingTask?.cancel()
        streamingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.client.preflightCheck()
                let outboundMessages = await MainActor.run { self.messages }
                let stream = try await self.client.streamChat(model: "gpt-4o-mini", messages: outboundMessages, temperature: 0.2)

                var buffer = ""

                @MainActor
                func flushBufferOnMain() {
                    guard !buffer.isEmpty else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        var current = self.messages[idx]
                        current.content += buffer
                        self.messages[idx] = current
                    }
                    buffer = ""
                }

                for try await token in stream {
                    await MainActor.run {
                        buffer.append(token)
                        let bySize = buffer.count >= self.chunkFlushSize
                        let lastChar = buffer.last
                        let endsWithPunct = lastChar.map { String($0).rangeOfCharacter(from: self.punctuationSet) != nil } ?? false
                        if bySize || endsWithPunct || token.hasSuffix("\n") {
                            flushBufferOnMain()
                        }
                    }
                }

                await MainActor.run {
                    if !buffer.isEmpty {
                        flushBufferOnMain()
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Network error: \(error.localizedDescription)"
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        self.messages[idx] = ChatMessage(role: "assistant", content: self.lastErrorMessage ?? "")
                    }
                }
            }
            await MainActor.run {
                self.isSending = false
                self.streamingTask = nil
                self.saveHistory()
            }
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        saveHistory()
    }
}
