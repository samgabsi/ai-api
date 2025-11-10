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

    // Model selection (wired to SettingsView later)
    @Published var selectedModel: String = "gpt-4o-mini"

    // Rate limit state exposed to UI (server-truth if available)
    @Published var rateLimitLimit: Int?
    @Published var rateLimitRemaining: Int?
    @Published var rateLimitReset: Date?

    // Client-side fallback counters (configurable via Settings)
    @Published var fallbackUsedInWindow: Int = 0
    @Published var fallbackLimitInWindow: Int = 60
    @Published var fallbackWindowEndsAt: Date = Date()
    @Published var fallbackWindowSeconds: Int = 60 // configurable
    @Published var blockWhenOutOfCalls: Bool = true

    // Thresholds for color warnings
    let warnThreshold: Double = 0.75   // 75% used
    let criticalThreshold: Double = 0.90 // 90% used

    // Sudo prompt plumbing for the UI to present when needed
    @Published var needsSudoPasswordPrompt: Bool = false
    @Published var pendingSudoRequestDescription: String = ""
    var onSudoPasswordProvided: ((String?) -> Void)?

    // Backward-compat alias for older UI code expecting this name
    var pendingSudoPasswordPrompt: Bool {
        get { needsSudoPasswordPrompt }
        set { needsSudoPasswordPrompt = newValue }
    }

    // In-memory sudo password cache (not persisted)
    private var sudoPasswordCache: String?

    private let client: OpenAIClient
    private var streamingTask: Task<Void, Never>?

    // Streaming flush configuration
    private let chunkFlushSize = 40
    private let punctuationSet = CharacterSet(charactersIn: ".!?,;:\n")
    private let chunkFlushInterval: TimeInterval = 0.15 // time-based flush

    // Persistence keys for fallback
    private let fallbackStoreKey = "RateFallback.Store"
    private let fallbackBlockKey = "RateFallback.BlockWhenOut"

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

    // History capping
    private let maxMessagesStored = 1000 // keep history manageable

    init() {
        client = OpenAIClient(apiKeyProvider: {
            return KeychainHelper.load(key: ChatViewModel.apiKeyKeychainKey)
        })
        self.apiKeyPresent = KeychainHelper.load(key: Self.apiKeyKeychainKey) != nil

        // Load history
        loadHistory()

        // Load fallback counters and block flag
        loadFallbackCounters()
        blockWhenOutOfCalls = UserDefaults.standard.object(forKey: fallbackBlockKey) as? Bool ?? true

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
        do {
            let data = try Data(contentsOf: historyURL)
            let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
            if !decoded.isEmpty {
                messages = decoded
            }
        } catch {
            // If corrupted, ignore and keep default system message
            print("Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
        // Trim before save
        trimHistoryIfNeeded()
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    private func trimHistoryIfNeeded() {
        guard messages.count > maxMessagesStored else { return }
        // Keep the first system message if present, and the last N-1 messages
        if let first = messages.first, first.role == "system" {
            let tail = messages.suffix(maxMessagesStored - 1)
            messages = [first] + tail
        } else {
            messages = Array(messages.suffix(maxMessagesStored))
        }
    }

    // MARK: - Fallback counters

    private struct FallbackStore: Codable {
        var used: Int
        var limit: Int
        var windowEndsAt: Date
        var windowSeconds: Int
    }

    private func loadFallbackCounters() {
        if let data = UserDefaults.standard.data(forKey: fallbackStoreKey),
           let store = try? JSONDecoder().decode(FallbackStore.self, from: data) {
            fallbackUsedInWindow = store.used
            fallbackLimitInWindow = store.limit
            fallbackWindowEndsAt = store.windowEndsAt
            fallbackWindowSeconds = max(1, store.windowSeconds)
        } else {
            fallbackLimitInWindow = 60
            fallbackUsedInWindow = 0
            fallbackWindowSeconds = 60
            fallbackWindowEndsAt = Date().addingTimeInterval(TimeInterval(fallbackWindowSeconds))
            persistFallbackCounters()
        }
        rollFallbackWindowIfNeeded()
    }

    private func persistFallbackCounters() {
        let store = FallbackStore(
            used: fallbackUsedInWindow,
            limit: fallbackLimitInWindow,
            windowEndsAt: fallbackWindowEndsAt,
            windowSeconds: fallbackWindowSeconds
        )
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: fallbackStoreKey)
        }
    }

    private func rollFallbackWindowIfNeeded() {
        let now = Date()
        if now >= fallbackWindowEndsAt {
            fallbackUsedInWindow = 0
            fallbackWindowEndsAt = now.addingTimeInterval(TimeInterval(fallbackWindowSeconds))
            persistFallbackCounters()
        }
    }

    private func noteApiCallForFallback() {
        rollFallbackWindowIfNeeded()
        fallbackUsedInWindow += 1
        persistFallbackCounters()
    }

    // Public API to configure fallback in Settings
    func updateFallbackWindow(seconds: Int) {
        let clamped = max(1, min(86_400, seconds))
        fallbackWindowSeconds = clamped
        fallbackUsedInWindow = 0
        fallbackWindowEndsAt = Date().addingTimeInterval(TimeInterval(fallbackWindowSeconds))
        persistFallbackCounters()
    }

    func updateFallbackLimit(_ limit: Int) {
        let clamped = max(1, min(1_000_000, limit))
        fallbackLimitInWindow = clamped
        persistFallbackCounters()
    }

    func setBlockWhenOutOfCalls(_ enabled: Bool) {
        blockWhenOutOfCalls = enabled
        UserDefaults.standard.set(enabled, forKey: fallbackBlockKey)
    }

    // MARK: - Normal chat

    func sendCurrentInput() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard canSend else {
            lastErrorMessage = "You’ve reached the API call limit for this window. Please wait until it resets."
            return
        }

        // Intercept "Bash:" requests here and reroute
        if text.lowercased().hasPrefix("bash:") {
            inputText = ""
            await handleBashRequest(String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

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
                if Task.isCancelled { return }
                let outboundMessages = await MainActor.run { self.messages }
                await MainActor.run { self.noteApiCallForFallback() }

                let response = try await self.client.streamChat(model: self.selectedModel, messages: outboundMessages, temperature: 0.2)

                // Apply server rate info if present; else clear to avoid stale display
                await MainActor.run {
                    self.rateLimitLimit = response.rateLimit.limit
                    self.rateLimitRemaining = response.rateLimit.remaining
                    self.rateLimitReset = response.rateLimit.reset
                }

                var buffer = ""
                var lastFlushTime = Date()

                @MainActor
                func flushBufferOnMain() {
                    guard !buffer.isEmpty else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        var current = self.messages[idx]
                        current.content += buffer
                        self.messages[idx] = current
                    }
                    buffer = ""
                    lastFlushTime = Date()
                }

                for try await token in response.stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        buffer.append(token)
                        let bySize = buffer.count >= self.chunkFlushSize
                        let endsWithPunct = buffer.last.map { String($0).rangeOfCharacter(from: self.punctuationSet) != nil } ?? false
                        let byTime = Date().timeIntervalSince(lastFlushTime) >= self.chunkFlushInterval
                        if bySize || endsWithPunct || token.hasSuffix("\n") || byTime {
                            flushBufferOnMain()
                        }
                    }
                }

                await MainActor.run {
                    if !buffer.isEmpty {
                        flushBufferOnMain()
                    }
                    // If no headers present (nil), clear server-truth to avoid stale display
                    if self.rateLimitLimit == nil && self.rateLimitRemaining == nil && self.rateLimitReset == nil {
                        self.rateLimitLimit = nil
                        self.rateLimitRemaining = nil
                        self.rateLimitReset = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = error.localizedDescription
                    self.applyRateLimitIfPresent(from: error)
                }
            }

            await MainActor.run {
                self.isSending = false
                self.streamingTask = nil
                self.saveHistory()
            }
        }
    }

    // New: Append a user message and send without using inputText
    func appendAndSendUserMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        guard canSend else {
            lastErrorMessage = "You’ve reached the API call limit for this window. Please wait until it resets."
            return
        }

        lastErrorMessage = nil
        isSending = true

        let userMsg = ChatMessage(role: "user", content: trimmed)
        messages.append(userMsg)

        let assistantMsg = ChatMessage(role: "assistant", content: "")
        messages.append(assistantMsg)
        let assistantMsgId = assistantMsg.id

        streamingTask?.cancel()
        streamingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                try await self.client.preflightCheck()
                if Task.isCancelled { return }
                let outboundMessages = await MainActor.run { self.messages }
                await MainActor.run { self.noteApiCallForFallback() }

                let response = try await self.client.streamChat(model: self.selectedModel, messages: outboundMessages, temperature: 0.2)

                await MainActor.run {
                    self.rateLimitLimit = response.rateLimit.limit
                    self.rateLimitRemaining = response.rateLimit.remaining
                    self.rateLimitReset = response.rateLimit.reset
                }

                var buffer = ""
                var lastFlushTime = Date()

                @MainActor
                func flushBufferOnMain() {
                    guard !buffer.isEmpty else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        var current = self.messages[idx]
                        current.content += buffer
                        self.messages[idx] = current
                    }
                    buffer = ""
                    lastFlushTime = Date()
                }

                for try await token in response.stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        buffer.append(token)
                        let bySize = buffer.count >= self.chunkFlushSize
                        let endsWithPunct = buffer.last.map { String($0).rangeOfCharacter(from: self.punctuationSet) != nil } ?? false
                        let byTime = Date().timeIntervalSince(lastFlushTime) >= self.chunkFlushInterval
                        if bySize || endsWithPunct || token.hasSuffix("\n") || byTime {
                            flushBufferOnMain()
                        }
                    }
                }

                await MainActor.run {
                    if !buffer.isEmpty {
                        flushBufferOnMain()
                    }
                    if self.rateLimitLimit == nil && self.rateLimitRemaining == nil && self.rateLimitReset == nil {
                        self.rateLimitLimit = nil
                        self.rateLimitRemaining = nil
                        self.rateLimitReset = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = error.localizedDescription
                    self.applyRateLimitIfPresent(from: error)
                }
            }

            await MainActor.run {
                self.isSending = false
                self.streamingTask = nil
                self.saveHistory()
            }
        }
    }

    // MARK: - Composer consent bridges (to be implemented by the View)

    // View sets these closures to present alerts and call the completion with the user’s choice.
    var requestComposerSendCommandConsent: ((String, @escaping (Bool) -> Void) -> Void)?
    var requestComposerSendOutputConsent: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private func promptComposerConsentToSendCommand(command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            requestComposerSendCommandConsent?(command) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func promptComposerConsentToSendOutput(command: String, output: String) async -> Bool {
        await withCheckedContinuation { continuation in
            requestComposerSendOutputConsent?(command, output) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    // MARK: - Bash request orchestration

    func handleBashRequest(_ natural: String) async {
        let request = natural.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        // 1) Ask model to synthesize a single command (plain text, no backticks)
        var resolvedCommand: String
        do {
            resolvedCommand = try await synthesizeBashCommand(from: request)
        } catch {
            messages.append(ChatMessage(role: "assistant", content: "I couldn’t derive a command from your request: \(error.localizedDescription)"))
            return
        }

        // 2) Ask consent to send the derived command to ChatGPT for analysis
        let allowSendCommand = await promptComposerConsentToSendCommand(command: resolvedCommand)
        if allowSendCommand {
            messages.append(ChatMessage(role: "user", content: "bash$ \(resolvedCommand)"))
        }

        // 3) If command contains sudo, automatically provide password from cache or prompt once
        let needsSudo = resolvedCommand.contains("sudo ")
        var stdinData: Data? = nil

        if needsSudo {
            if let cached = sudoPasswordCache {
                stdinData = (cached + "\n").data(using: .utf8)
            } else {
                let pwd = await promptForSudoPassword(description: "Command requires administrator privileges.")
                guard let pwd, !pwd.isEmpty else {
                    messages.append(ChatMessage(role: "assistant", content: "Canceled running sudo command."))
                    return
                }
                sudoPasswordCache = pwd
                stdinData = (pwd + "\n").data(using: .utf8)
            }
        }

        // 4) Run the command via BashRunner with 120s timeout, collect output
        let result = await runCommandCollectOutput(command: resolvedCommand, timeout: 120, stdinData: stdinData)

        if needsSudo && sudoAuthLikelyFailed(in: result.output) {
            sudoPasswordCache = nil
        }

        // 5) Ask consent to send the raw output to ChatGPT for analysis
        let allowSendOutput = await promptComposerConsentToSendOutput(command: resolvedCommand, output: result.output)
        if allowSendOutput {
            messages.append(ChatMessage(role: "user", content: result.output.isEmpty ? "(no output)" : result.output))

            let contextualized = """
            I ran the following shell command:

            bash$ \(resolvedCommand)

            Here is the full output:

            \(result.output.isEmpty ? "(no output)" : result.output)

            Please analyze the output. If there are errors, explain the likely cause and suggest fixes. If it succeeded, summarize what happened and any next steps I might take.
            """
            await appendAndSendUserMessage(contextualized)
        } else {
            messages.append(ChatMessage(role: "assistant", content: "Output was not sent for analysis as requested."))
        }
    }

    private func runCommandCollectOutput(command: String, timeout: TimeInterval, stdinData: Data?) async -> (exitCode: Int32, output: String) {
        let handle = BashRunner.run(command: command, timeout: timeout, stdinData: stdinData)
        var collected = ""
        for await chunk in handle.stream {
            collected += chunk.text
        }
        let code = await handle.exitCodeTask.value
        return (code, collected)
    }

    private func synthesizeBashCommand(from natural: String) async throws -> String {
        // Placeholder: pass through if it looks like a command; otherwise echo it.
        let trimmed = natural.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "echo 'No command provided'"
        } else {
            if trimmed.contains(" ") || trimmed.contains("/") {
                return trimmed
            } else {
                return "echo \(trimmed)"
            }
        }
    }

    private func sudoAuthLikelyFailed(in text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("sorry, try again") ||
               lowered.contains("sudo: 3 incorrect password attempts") ||
               lowered.contains("authentication failure")
    }

    private func promptForSudoPassword(description: String) async -> String? {
        await withCheckedContinuation { continuation in
            self.pendingSudoRequestDescription = description
            self.needsSudoPasswordPrompt = true
            self.onSudoPasswordProvided = { pwd in
                self.needsSudoPasswordPrompt = false
                self.pendingSudoRequestDescription = ""
                self.onSudoPasswordProvided = nil
                continuation.resume(returning: pwd)
            }
        }
    }

    func provideSudoPassword(_ password: String?) {
        onSudoPasswordProvided?(password)
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        saveHistory()
    }

    // Convenience computed properties for UI

    private var hasAnyServerRateInfo: Bool {
        return rateLimitLimit != nil || rateLimitRemaining != nil
    }

    var displayUsed: Int? {
        if let l = rateLimitLimit, let r = rateLimitRemaining {
            return max(0, l - r)
        }
        if rateLimitLimit != nil, rateLimitRemaining == nil { return nil }
        if rateLimitRemaining != nil, rateLimitLimit == nil { return nil }
        return fallbackUsedInWindow
    }

    var displayLimit: Int? { rateLimitLimit }
    var displayRemaining: Int? { rateLimitRemaining }
    var displayReset: Date? { rateLimitReset }

    var displayLimitFallbackAware: Int {
        if let l = rateLimitLimit { return l }
        return fallbackLimitInWindow
    }

    var displayRemainingFallbackAware: Int {
        if let r = rateLimitRemaining { return r }
        if rateLimitLimit != nil { return 0 }
        return max(0, fallbackLimitInWindow - fallbackUsedInWindow)
    }

    var displayPercentUsed: Double {
        let limit = Double(displayLimitFallbackAware)
        guard limit > 0 else { return 0 }
        let used = Double(displayUsed ?? (displayLimitFallbackAware - displayRemainingFallbackAware))
        return min(1.0, max(0.0, used / limit))
    }

    var usageColorRole: UsageRole {
        let pct = displayPercentUsed
        if pct >= criticalThreshold { return .critical }
        if pct >= warnThreshold { return .warning }
        return .normal
    }

    enum UsageRole {
        case normal
        case warning
        case critical
    }

    var canSend: Bool {
        if !blockWhenOutOfCalls { return true }
        if let remaining = rateLimitRemaining, let limit = rateLimitLimit {
            return remaining > 0 && limit > 0
        }
        let remainingFallback = max(0, displayLimitFallbackAware - fallbackUsedInWindow)
        return remainingFallback > 0
    }

    var usageTooltip: String {
        var parts: [String] = []
        if hasAnyServerRateInfo {
            let limit = rateLimitLimit
            let remaining = rateLimitRemaining
            if let limit {
                parts.append("Server rate limit: \(limit) total" + (remaining != nil ? "," : ""))
            }
            if let remaining {
                parts.append("\(remaining) remaining.")
            }
            if let reset = rateLimitReset {
                parts.append("Resets at \(reset.formatted(date: .omitted, time: .standard)).")
            }
        } else {
            parts.append("Fallback window: \(fallbackWindowSeconds)s, limit \(fallbackLimitInWindow).")
            let remaining = max(0, fallbackLimitInWindow - fallbackUsedInWindow)
            parts.append("\(fallbackUsedInWindow) used, \(remaining) remaining.")
            parts.append("Window ends at \(fallbackWindowEndsAt.formatted(date: .omitted, time: .standard)).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Rate limit parsing and application

    private func parseRateLimit(from text: String) -> (limit: Int?, used: Int?, tryAgainSeconds: TimeInterval?) {
        let lower = text.lowercased()

        guard lower.contains("rate limit") || lower.contains("limit reached") || lower.contains("quota") || lower.contains("too many requests") else {
            return (nil, nil, nil)
        }

        var limit: Int?
        var used: Int?
        var requested: Int?
        var tryAgain: TimeInterval?

        if let data = text.data(using: .utf8) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any] {
                if let msg = err["message"] as? String {
                    let parsed = parseRateLimit(from: msg)
                    limit = parsed.limit ?? limit
                    used = parsed.used ?? used
                    tryAgain = parsed.tryAgainSeconds ?? tryAgain
                }
                if let retry = err["retry_after"] as? TimeInterval {
                    tryAgain = retry
                }
                if let l = err["limit"] as? Int { limit = l }
                if let u = err["used"] as? Int { used = u }
            }
        }

        func firstInt(matching pattern: String) -> Int? {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                if let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2 {
                    return Int(ns.substring(with: m.range(at: 1)))
                }
            }
            return nil
        }
        func firstDouble(matching pattern: String) -> Double? {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                if let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2 {
                    return Double(ns.substring(with: m.range(at: 1)))
                }
            }
            return nil
        }

        if limit == nil || used == nil || requested == nil {
            if let re = try? NSRegularExpression(
                pattern: #"limit\s+(\d+)\s*,\s*used\s+(\d+)\s*,\s*requested\s+(\d+)"#,
                options: [.caseInsensitive]
            ) {
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                if let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 4 {
                    if limit == nil { limit = Int(ns.substring(with: m.range(at: 1))) }
                    if used == nil { used = Int(ns.substring(with: m.range(at: 2))) }
                    if requested == nil { requested = Int(ns.substring(with: m.range(at: 3))) }
                }
            }
        }

        if limit == nil {
            limit = firstInt(matching: #"(?:(?:limit|allowed|quota)[^\d]{0,12})(\d+)"#)
        }
        if used == nil {
            used = firstInt(matching: #"(?:(?:used)[^\d]{0,12})(\d+)"#)
        }
        if requested == nil {
            requested = firstInt(matching: #"(?:(?:requested)[^\d]{0,12})(\d+)"#)
        }
        var remaining: Int?
        remaining = firstInt(matching: #"(?:(?:remaining)[^\d]{0,12})(\d+)"#)

        if tryAgain == nil {
            if let secs = firstDouble(matching: #"try again in\s+(\d+)\s*(?:s|sec|secs|seconds)?"#) {
                tryAgain = secs
            } else if let secs = firstDouble(matching: #"retry after\s+(\d+)\s*(?:s|sec|secs|seconds)?"#) {
                tryAgain = secs
            }
            if tryAgain == nil {
                if let mins = firstDouble(matching: #"try again in\s+(\d+)\s*(?:m|min|mins|minutes)\b"#) {
                    tryAgain = mins * 60.0
                } else if let mins = firstDouble(matching: #"retry after\s+(\d+)\s*(?:m|min|mins|minutes)\b"#) {
                    tryAgain = mins * 60.0
                }
            }
            if tryAgain == nil {
                if let re = try? NSRegularExpression(pattern: #"(?:(?:try again in|retry after)\s+)(\d+):(\d+(?:\.\d+)?)"#, options: [.caseInsensitive]) {
                    let ns = text as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    if let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 3 {
                        if let mm = Double(ns.substring(with: m.range(at: 1))),
                           let ss = Double(ns.substring(with: m.range(at: 2))) {
                            tryAgain = mm * 60.0 + ss
                        }
                    }
                }
            }
            if tryAgain == nil {
                if let re = try? NSRegularExpression(pattern: #"(?:(?:try again in|retry after)\s+)(\d+)\s*(?:m|min|mins|minutes)\s*(\d+(?:\.\d+)?)\s*(?:s|sec|secs|seconds)"#, options: [.caseInsensitive]) {
                    let ns = text as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    if let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 3 {
                        if let mm = Double(ns.substring(with: m.range(at: 1))),
                           let ss = Double(ns.substring(with: m.range(at: 2))) {
                            tryAgain = mm * 60.0 + ss
                        }
                    }
                }
            }
        }

        if used == nil, let l = limit, let r = remaining {
            used = max(0, l - r)
        }
        if remaining == nil, let l = limit, let u = used {
            remaining = max(0, l - u)
        }

        return (limit, used, tryAgain)
    }

    private func parseAndApplyRateLimit(fromText text: String) {
        let parsed = parseRateLimit(from: text)
        applyParsedRateLimit(limit: parsed.limit, used: parsed.used, tryAgainSeconds: parsed.tryAgainSeconds)
    }

    private func applyRateLimitIfPresent(from error: Error) {
        if case OpenAIError.httpError(_, let body) = error {
            parseAndApplyRateLimit(fromText: body)
        }
    }

    private func applyParsedRateLimit(limit: Int?, used: Int?, tryAgainSeconds: TimeInterval?) {
        var updated = false
        var switchedToServerTruth = false

        if let l = limit {
            rateLimitLimit = l
            updated = true
            switchedToServerTruth = true
        }
        if let u = used, let l = rateLimitLimit ?? limit {
            let remaining = max(0, l - u)
            rateLimitRemaining = remaining
            updated = true
            switchedToServerTruth = true
        }
        if let wait = tryAgainSeconds, wait.isFinite, wait > 0 {
            let reset = Date().addingTimeInterval(wait)
            rateLimitReset = reset
            updated = true
            switchedToServerTruth = true
        }

        if switchedToServerTruth {
            if let reset = rateLimitReset, reset > Date() {
                fallbackWindowEndsAt = reset
            }
            fallbackUsedInWindow = 0
            persistFallbackCounters()
        }

        if updated {
            objectWillChange.send()
        }
    }
}
