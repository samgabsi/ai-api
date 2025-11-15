import Foundation
import Combine
import AppKit

@MainActor
final class ChatViewModel: ObservableObject {
    static let apiKeyKeychainKey = "OpenAI.ApiKey"
    private static let selectedModelDefaultsKey = "OpenAI.SelectedModel"

    @Published var messages: [ChatMessage] = [ChatMessage(role: "system", content: "You are a helpful assistant.")]
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var lastErrorMessage: String?
    @Published var apiKeyPresent: Bool = false

    @Published var selectedModel: String = "gpt-4o-mini" {
        didSet { persistSelectedModel() }
    }

    @Published var rateLimitLimit: Int?
    @Published var rateLimitRemaining: Int?
    @Published var rateLimitReset: Date?

    @Published var fallbackUsedInWindow: Int = 0
    @Published var fallbackLimitInWindow: Int = 60
    @Published var fallbackWindowEndsAt: Date = Date()
    @Published var fallbackWindowSeconds: Int = 60
    @Published var blockWhenOutOfCalls: Bool = true

    let warnThreshold: Double = 0.75
    let criticalThreshold: Double = 0.90

    // Sudo prompt bridge
    @Published var needsSudoPasswordPrompt: Bool = false
    @Published var pendingSudoRequestDescription: String = ""
    var onSudoPasswordProvided: ((String?) -> Void)?
    private var sudoPasswordCache: String?

    var pendingSudoPasswordPrompt: Bool {
        get { needsSudoPasswordPrompt }
        set { needsSudoPasswordPrompt = newValue }
    }

    private let client: OpenAIClient
    private var streamingTask: Task<Void, Never>?

    private let fallbackStoreKey = "RateFallback.Store"
    private let fallbackBlockKey = "RateFallback.BlockWhenOut"

    private let historyURL: URL = {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base?.appendingPathComponent("NeuroDesk AI", isDirectory: true)
        if let dir, !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (dir ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("chat.json")
    }()

    private let maxMessagesStored = 1000
    private var cancellables: Set<AnyCancellable> = []

    // Consent bridges for composer alerts (wired by ContentView_Hybrid)
    var requestComposerSendCommandConsent: ((String, @escaping (Bool) -> Void) -> Void)?
    var requestComposerSendOutputConsent: ((String, String, @escaping (Bool) -> Void) -> Void)?

    init() {
        client = OpenAIClient(apiKeyProvider: {
            return KeychainHelper.load(key: ChatViewModel.apiKeyKeychainKey)
        })
        self.apiKeyPresent = KeychainHelper.load(key: Self.apiKeyKeychainKey) != nil

        if let persisted = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey),
           !persisted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.selectedModel = persisted
        }

        loadHistory()
        loadFallbackCounters()
        blockWhenOutOfCalls = UserDefaults.standard.object(forKey: fallbackBlockKey) as? Bool ?? true

        $messages
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveHistory()
            }
            .store(in: &cancellables)
    }

    private func persistSelectedModel() {
        UserDefaults.standard.set(selectedModel, forKey: Self.selectedModelDefaultsKey)
    }

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
            print("Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
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
        if let first = messages.first, first.role == "system" {
            let tail = messages.suffix(maxMessagesStored - 1)
            messages = [first] + tail
        } else {
            messages = Array(messages.suffix(maxMessagesStored))
        }
    }

    private struct FallbackStore: Codable {
        var used: Int
        var limit: Int
        var windowEndsAt: Date
        var windowSeconds: Int
    }

    private func saveFallbackCounters() {
        let store = FallbackStore(
            used: fallbackUsedInWindow,
            limit: fallbackLimitInWindow,
            windowEndsAt: fallbackWindowEndsAt,
            windowSeconds: fallbackWindowSeconds
        )
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: fallbackStoreKey)
        }
        UserDefaults.standard.set(blockWhenOutOfCalls, forKey: fallbackBlockKey)
    }

    func loadFallbackCounters() {
        if let data = UserDefaults.standard.data(forKey: fallbackStoreKey),
           let store = try? JSONDecoder().decode(FallbackStore.self, from: data) {
            fallbackUsedInWindow = store.used
            fallbackLimitInWindow = store.limit
            fallbackWindowEndsAt = store.windowEndsAt
            fallbackWindowSeconds = max(1, store.windowSeconds)
        } else {
            fallbackUsedInWindow = 0
            fallbackLimitInWindow = 60
            fallbackWindowSeconds = 60
            fallbackWindowEndsAt = Date().addingTimeInterval(TimeInterval(fallbackWindowSeconds))
        }
    }

    func updateFallbackWindow(seconds: Int) {
        let clamped = max(1, min(seconds, 24 * 3600))
        fallbackWindowSeconds = clamped
        fallbackUsedInWindow = 0
        fallbackWindowEndsAt = Date().addingTimeInterval(TimeInterval(clamped))
        saveFallbackCounters()
    }

    func updateFallbackLimit(_ limit: Int) {
        let clamped = max(1, min(limit, 10_000))
        fallbackLimitInWindow = clamped
        fallbackUsedInWindow = min(fallbackUsedInWindow, clamped)
        saveFallbackCounters()
    }

    func tickFallbackUsage() {
        let now = Date()
        if now >= fallbackWindowEndsAt {
            fallbackUsedInWindow = 0
            fallbackWindowEndsAt = now.addingTimeInterval(TimeInterval(fallbackWindowSeconds))
        }
        fallbackUsedInWindow = min(fallbackUsedInWindow + 1, fallbackLimitInWindow)
        saveFallbackCounters()
    }

    var canSend: Bool {
        if let remaining = rateLimitRemaining, let reset = rateLimitReset {
            if remaining > 0 { return true }
            if Date() >= reset { return true }
            return !blockWhenOutOfCalls
        }
        let now = Date()
        let remainingFallback: Int
        if now >= fallbackWindowEndsAt {
            remainingFallback = fallbackLimitInWindow
        } else {
            remainingFallback = max(0, fallbackLimitInWindow - fallbackUsedInWindow)
        }
        if remainingFallback > 0 { return true }
        return !blockWhenOutOfCalls
    }

    func appendAndSendUserMessage(_ text: String) async {
        await MainActor.run { inputText = text }
        await sendCurrentInput()
    }

    func sendCurrentInput() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard canSend else {
            await MainActor.run { lastErrorMessage = "Send blocked by rate limit." }
            return
        }

        if rateLimitRemaining == nil {
            tickFallbackUsage()
        }

        isSending = true
        lastErrorMessage = nil
        messages.append(ChatMessage(role: "user", content: text))
        inputText = ""

        do {
            let response = try await client.streamChat(model: selectedModel, messages: messages)
            rateLimitLimit = response.rateLimit.limit
            rateLimitRemaining = response.rateLimit.remaining
            rateLimitReset = response.rateLimit.reset

            let assistant = ChatMessage(role: "assistant", content: "")
            messages.append(assistant)
            var buffer = ""

            for try await token in response.stream {
                buffer.append(token)
                if let lastIndex = messages.indices.last {
                    messages[lastIndex].content = buffer
                }
            }
        } catch {
            lastErrorMessage = (error as? OpenAIError)?.localizedDescription ?? error.localizedDescription
        }

        isSending = false
    }
    
    func sendCurrentInput(images: [BashImageUpload]) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard canSend else {
            await MainActor.run { lastErrorMessage = "Send blocked by rate limit." }
            return
        }

        if rateLimitRemaining == nil { tickFallbackUsage() }

        isSending = true
        lastErrorMessage = nil
        messages.append(ChatMessage(role: "user", content: text))
        inputText = ""

        do {
            let response = try await client.streamChat(model: selectedModel, messages: messages, images: images)
            rateLimitLimit = response.rateLimit.limit
            rateLimitRemaining = response.rateLimit.remaining
            rateLimitReset = response.rateLimit.reset

            let assistant = ChatMessage(role: "assistant", content: "")
            messages.append(assistant)
            var buffer = ""

            for try await token in response.stream {
                buffer.append(token)
                if let lastIndex = messages.indices.last {
                    messages[lastIndex].content = buffer
                }
            }
        } catch {
            lastErrorMessage = (error as? OpenAIError)?.localizedDescription ?? error.localizedDescription
        }

        isSending = false
    }

    func handleBashRequest(_ natural: String) async {
        let trimmed = natural.trimmingCharacters(in: .whitespacesAndNewlines)

        // Known deterministic intents
        if matchesTimeIntent(trimmed) {
            await runTimeIntent()
            return
        }
        if matchesCreateTreeIntent(trimmed) {
            await runCreateTreeDatabase(from: parseRequestedRoot(from: trimmed) ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                        depth: parseRequestedDepth(from: trimmed) ?? 3)
            return
        }
        if matchesRootTreeIntent(trimmed) {
            await runRootTreeIntent(root: parseRequestedRoot(from: trimmed) ?? "/", depth: parseRequestedDepth(from: trimmed) ?? 3)
            return
        }

        // Expanded Install intents (rule-based)
        if let plan = buildInstallPlan(from: trimmed) {
            await executePlanWithConsent(plan)
            return
        }

        // Fallback to normal chat behavior
        await appendAndSendUserMessage("bash: \(natural)")
    }

    // MARK: - Composer NL→Bash flow
    /// Translate natural language into a concrete bash command using the chat model,
    /// gate the run with user consent, execute with BashQueryExecutor, and post output
    /// into the AI Response section.
    func composeAndRunBash(natural: String, uploads: [BashImageUpload], timeout: TimeInterval = 300) async {
        let trimmed = natural.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Build the prompt for command synthesis
        let system = ChatMessage(role: "system", content: "You are a bash assistant. Convert natural language tasks into a single safe bash command line that runs non-interactively on macOS. Return ONLY the command, no markdown, no commentary. Prefer standard tools. Assume a clean non-login bash with no aliases. If the task is ambiguous, choose a reasonable default.")
        let user = ChatMessage(role: "user", content: """
        Task:
        \(trimmed)

        Available environment variables you may reference:
        - IMAGE_DIR, IMAGE_COUNT, IMAGE_1..N
        - FILE_DIR, FILE_COUNT, FILE_1..N
        - BASH_WORK_DIR
        Return only the final command line.
        """)

        var synthesized = ""
        do {
            let response = try await client.streamChat(model: selectedModel, messages: [system, user])
            // Update window counters if server doesn't provide rate headers
            rateLimitLimit = response.rateLimit.limit
            rateLimitRemaining = response.rateLimit.remaining
            rateLimitReset = response.rateLimit.reset
            if rateLimitRemaining == nil { tickFallbackUsage() }

            for try await token in response.stream { synthesized.append(token) }
        } catch {
            await MainActor.run { self.lastErrorMessage = (error as? OpenAIError)?.localizedDescription ?? error.localizedDescription }
            return
        }

        let command = Self.extractCommand(from: synthesized)
        guard !command.isEmpty else {
            await MainActor.run {
                self.messages.append(ChatMessage(role: "assistant", content: "I couldn't derive a runnable command from your request."))
                self.saveHistory()
            }
            return
        }

        // Ask for consent to run the command (gated)
        let approved: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.requestComposerSendCommandConsent?(command) { ok in cont.resume(returning: ok) } ?? { cont.resume(returning: false) }()
        }
        guard approved else {
            await MainActor.run {
                self.messages.append(ChatMessage(role: "assistant", content: "Cancelled. I did not run:\n\nbash$ \(command)"))
                self.saveHistory()
            }
            return
        }

        // Execute via BashQueryExecutor with provided uploads
        let wrapped = envPathPrefixExport() + command
        let result = await BashQueryExecutor.execute("bash: \(wrapped)", timeout: timeout, inputImages: uploads)

        // Format output for AI Response section
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String] = []
        body.append("I generated and ran the following command (with your approval):\n\nbash$ \(command)")
        body.append("Exit code: \(result.exitCode)")
        if !stdout.isEmpty { body.append("stdout:\n\(stdout.prefix(8000))") }
        if !stderr.isEmpty { body.append("stderr:\n\(stderr.prefix(8000))") }
        if !result.outputFiles.isEmpty {
            let list = result.outputFiles.map { f in
                let sizeFmt = ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file)
                return "• \(f.filename) — \(sizeFmt) — \(f.mimeType)"
            }.joined(separator: "\n")
            body.append("Generated files (saved under \(result.workingDirectory.path)):\n\(list)")
        }

        await MainActor.run {
            self.messages.append(ChatMessage(role: "assistant", content: body.joined(separator: "\n\n")))
            self.saveHistory()
        }
    }

    /// Extract the first plausible command from model output.
    private static func extractCommand(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Try to peel code fence
            if let range = s.range(of: "```", options: [], range: s.index(after: s.startIndex)..<s.endIndex) {
                s = String(s[s.index(after: s.startIndex)..<range.lowerBound])
            }
        }
        // Take the first non-empty line
        if let line = s.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return line
        }
        return s
    }

    // MARK: - Expanded Rule Set for Install/Setup

    private struct Target {
        enum Kind { case formula, cask, masID, gitURL }
        let kind: Kind
        let value: String
        let verify: Bool
    }

    private func buildInstallPlan(from text: String) -> ChatPlan? {
        let l = text.lowercased()

        // Recognize intent verbs
        let installish = l.contains("install") || l.contains("set up") || l.contains("setup") || l.contains("add") || l.contains("get")
        guard installish || detectSystemWideRequest(l) else { return nil }

        // PATH/system-wide only requests
        if detectSystemWideRequest(l) && (l.contains("brew") || l.contains("homebrew") || l.contains("/opt/homebrew") || l.contains("/usr/local")) && !l.contains("install ") {
            return planEnsureBrewSystemPathOnly()
        }

        // MAS by ID
        if let id = firstMatch(regex: #"(?:mas\s+id|app\s*store\s*id)[:\s]+(\d+)"#, in: text) ?? ((l.contains("app store") || l.contains("mas")) ? firstMatch(regex: #"\b(\d{6,})\b"#, in: text) : nil) {
            return planMasInstall(id: id)
        }

        // Git URL
        if let url = firstMatch(regex: #"(https?://[A-Za-z0-9\.\-_/]+\.git)\b"#, in: text) {
            let dest = firstMatch(regex: #"dest(?:ination)?[:\s]+([^\s]+)"#, in: text)
            let installCmd = firstMatch(regex: #"install(?:\s+cmd|ation\s+cmd|:)[:\s]+(.+)$"#, in: text) ?? defaultInstallCommandForGit(url: url)
            return planGitInstall(url: url, dest: dest, installCmd: installCmd)
        }

        // Multi-target parsing (comma/and delimited)
        let wantsVerify = detectVerifyRequest(l)
        let systemWide = detectSystemWideRequest(l)
        let rawTargets = parseMultiTargets(from: text)
        if rawTargets.isEmpty { return nil }

        // Classify targets: formula vs cask (with aliases), plus explicit tokens like "cask iterm2"
        var targets: [Target] = []
        for raw in rawTargets {
            if raw.lowercased().hasPrefix("cask ") {
                let token = raw.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    targets.append(Target(kind: .cask, value: token, verify: false))
                }
                continue
            }
            if let masID = raw.range(of: #"^\d{6,}$"#, options: .regularExpression) != nil ? raw : nil {
                targets.append(Target(kind: .masID, value: masID, verify: false))
                continue
            }
            let normalized = normalizeAppNameWithAliases(raw)
            if isLikelyCask(normalized) {
                targets.append(Target(kind: .cask, value: normalized, verify: false))
            } else {
                targets.append(Target(kind: .formula, value: normalized, verify: wantsVerify))
            }
        }

        // Build a composite plan: ensure Homebrew (and PATH if system-wide), then install each target
        var steps: [ChatPlanStep] = []
        steps += ensureHomebrewSteps()
        if systemWide {
            steps += ensureBrewPathOnlySteps()
        }

        // Group by kind for efficiency
        let formulas = targets.filter { $0.kind == .formula }.map { $0.value }
        let casks = targets.filter { $0.kind == .cask }.map { $0.value }
        let masIDs = targets.filter { $0.kind == .masID }.map { $0.value }

        if !formulas.isEmpty {
            steps += planMultiBrewFormulaSteps(names: formulas, verify: wantsVerify)
        }
        if !casks.isEmpty {
            steps += planMultiBrewCaskSteps(names: casks)
        }
        if !masIDs.isEmpty {
            steps += ensureMasSteps()
            for id in masIDs {
                steps.append(ChatPlanStep(title: "mas install/upgrade \(id)",
                                  command: """
                                  if mas list | awk '{print $1}' | grep -qx "\(id)"; then
                                    mas upgrade "\(id)" || true
                                  else
                                    mas install "\(id)"
                                  fi
                                  """,
                                  timeout: 1800,
                                  safety: .needsConsent))
            }
        }

        let desc: String = {
            var parts: [String] = []
            if !formulas.isEmpty { parts.append("formulae: \(formulas.joined(separator: ", "))") }
            if !casks.isEmpty { parts.append("casks: \(casks.joined(separator: ", "))") }
            if !masIDs.isEmpty { parts.append("MAS: \(masIDs.joined(separator: ", "))") }
            if parts.isEmpty { return "Install requested items" }
            return "Install " + parts.joined(separator: " • ")
        }()

        return ChatPlan(description: desc, steps: steps)
    }

    // MARK: - Parsing helpers and heuristics

    private func parseMultiTargets(from text: String) -> [String] {
        // Extract likely target tokens after verbs: install|setup|set up|add|get
        // Split on commas and " and "
        let lower = text.lowercased()
        let verbs = ["install", "setup", "set up", "add", "get"]
        guard let range = verbs.compactMap({ lower.range(of: $0) }).first else {
            return []
        }
        let tail = text[range.upperBound...]
        _ = CharacterSet(charactersIn: ",")
        var parts = tail
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Clean common suffixes like "then verify", "and check version"
        parts = parts.map { s in
            var t = s
            t = t.replacingOccurrences(of: #"then\s+verify.*$"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"and\s+check\s+version.*$"#, with: "", options: .regularExpression)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return t
        }

        // Remove empty entries and leading verbs if repeated
        parts = parts.compactMap { p in
            var t = p
            for v in verbs {
                if t.lowercased().hasPrefix(v + " ") {
                    t = String(t.dropFirst(v.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return t.isEmpty ? nil : t
        }

        return parts
    }

    private func detectVerifyRequest(_ l: String) -> Bool {
        l.contains("then verify") || l.contains("and verify") || l.contains("check version") || l.contains("verify version")
    }

    private func detectSystemWideRequest(_ l: String) -> Bool {
        l.contains("system-wide") || l.contains("system wide") ||
        l.contains("all users") || l.contains("for everyone") ||
        l.contains("everyone's path") || l.contains("in path for everyone") ||
        l.contains("available to all users") || l.contains("usable by all users") ||
        l.contains("add to path") || l.contains("/etc/paths.d")
    }

    // Map common GUI names to cask tokens
    private func normalizeAppNameWithAliases(_ s: String) -> String {
        let map: [String: String] = [
            "iterm2": "iterm2",
            "iterm": "iterm2",
            "visual studio code": "visual-studio-code",
            "vscode": "visual-studio-code",
            "google chrome": "google-chrome",
            "chrome": "google-chrome",
            "slack": "slack",
            "docker": "docker",
            "docker desktop": "docker",
            "rectangle": "rectangle",
            "postman": "postman"
        ]
        let key = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = map[key] { return mapped }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyCask(_ token: String) -> Bool {
        let lower = token.lowercased()
        // Heuristics: contains spaces (GUI app names), known cask aliases above, or typical GUI words
        if lower.contains(" ") { return true }
        let guiHints = ["visual-studio-code", "iterm2", "google-chrome", "slack", "docker", "postman", "rectangle"]
        if guiHints.contains(lower) { return true }
        return false
    }

    private func defaultInstallCommandForGit(url: String) -> String? {
        if url.lowercased().contains("junegunn/fzf") {
            return "./install --all"
        }
        return nil
    }

    // MARK: - Plan builders (expanded)

    private func planEnsureBrewSystemPathOnly() -> ChatPlan {
        ChatPlan(description: "Ensure Homebrew is on system-wide PATH", steps: ensureHomebrewSteps() + ensureBrewPathOnlySteps())
    }

    private func planMultiBrewFormulaSteps(names: [String], verify: Bool) -> [ChatPlanStep] {
        let prefix = brewPrefixGuess()
        let brew = FileManager.default.fileExists(atPath: "\(prefix)/bin/brew") ? "\(prefix)/bin/brew" : "brew"
        var steps: [ChatPlanStep] = []
        steps.append(ChatPlanStep(title: "brew update",
                          command: "\"\(brew)\" update",
                          timeout: 1200,
                          safety: .safe))
        for n in names {
            steps.append(ChatPlanStep(title: "brew install/upgrade \(n)",
                              command: """
                              if "\(brew)" list --versions "\(n)" >/dev/null 2>&1; then
                                "\(brew)" upgrade "\(n)" || true
                              else
                                "\(brew)" install "\(n)"
                              fi
                              """,
                              timeout: 1800,
                              safety: .safe))
            if verify {
                steps.append(ChatPlanStep(title: "verify \(n)",
                                  command: """
                                  command -v "\(n)" >/dev/null 2>&1 || exit 1
                                  "\(n)" --version >/dev/null 2>&1 || true
                                  """,
                                  timeout: 30,
                                  safety: .safe))
            }
        }
        return steps
    }

    private func planMultiBrewCaskSteps(names: [String]) -> [ChatPlanStep] {
        let prefix = brewPrefixGuess()
        let brew = FileManager.default.fileExists(atPath: "\(prefix)/bin/brew") ? "\(prefix)/bin/brew" : "brew"
        var steps: [ChatPlanStep] = []
        steps.append(ChatPlanStep(title: "brew update",
                          command: "\"\(brew)\" update",
                          timeout: 1200,
                          safety: .safe))
        for n in names {
            steps.append(ChatPlanStep(title: "brew install/upgrade --cask \(n)",
                              command: """
                              if "\(brew)" list --cask --versions "\(n)" >/dev/null 2>&1; then
                                "\(brew)" upgrade --cask "\(n)" || true
                              else
                                "\(brew)" install --cask "\(n)"
                              fi
                              """,
                              timeout: 1800,
                              safety: .needsConsent))
        }
        return steps
    }

    private func planMasInstall(id: String) -> ChatPlan {
        var steps: [ChatPlanStep] = []
        steps += ensureHomebrewSteps() // to install mas via brew if needed
        steps += ensureMasSteps()
        steps.append(ChatPlanStep(title: "mas install/upgrade \(id)",
                          command: """
                          if mas list | awk '{print $1}' | grep -qx "\(id)"; then
                            mas upgrade "\(id)" || true
                          else
                            mas install "\(id)"
                          fi
                          """,
                          timeout: 1800,
                          safety: .needsConsent))
        return ChatPlan(description: "Install Mac App Store app \(id)", steps: steps)
    }

    private func planGitInstall(url: String, dest: String?, installCmd: String?) -> ChatPlan {
        let destination = dest ?? "/usr/local/src"
        let name = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "repo"
        var steps: [ChatPlanStep] = []
        steps += ensureGitSteps()
        steps.append(ChatPlanStep(title: "clone/update \(name)",
                          command: """
                          set -e
                          mkdir -p "\(destination)"
                          if [ -d "\(destination)/\(name)/.git" ]; then
                            git -C "\(destination)/\(name)" fetch --all --prune
                            git -C "\(destination)/\(name)" reset --hard origin/HEAD || true
                          else
                            git clone --depth=1 "\(url)" "\(destination)/\(name)"
                          fi
                          """,
                          timeout: 1200,
                          safety: .needsConsent))
        if let installCmd, !installCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(ChatPlanStep(title: "run install command",
                              command: "cd \"\(destination)/\(name)\" && bash -lc \(escapeShellArg(installCmd))",
                              timeout: 1800,
                              safety: .needsConsent))
        }
        return ChatPlan(description: "Install from Git: \(url)", steps: steps)
    }

    // Shared step builders

    private func ensureHomebrewSteps() -> [ChatPlanStep] {
        let prefix = brewPrefixGuess()
        let brewExists = FileManager.default.fileExists(atPath: "\(prefix)/bin/brew") ||
                         FileManager.default.fileExists(atPath: "/usr/local/bin/brew") ||
                         FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
        var steps: [ChatPlanStep] = []
        if !brewExists {
            steps.append(ChatPlanStep(title: "Install Homebrew",
                              command: #"NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                              timeout: 1800,
                              safety: .privileged,
                              requiresSudo: true,
                              stdin: { [weak self] in (self?.sudoPasswordCache ?? "") == "" ? nil : (self!.sudoPasswordCache! + "\n").data(using: .utf8) }))
        }
        return steps
    }

    private func ensureBrewPathOnlySteps() -> [ChatPlanStep] {
        let prefix = brewPrefixGuess()
        let binDir = "\(prefix)/bin"
        let sbinDir = "\(prefix)/sbin"
        return [
            ChatPlanStep(title: "Add Homebrew to system PATH",
                 command: """
                 set -e
                 tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
                 touch "$tmp"
                 if [ -d "\(binDir)" ]; then echo "\(binDir)" >> "$tmp"; fi
                 if [ -d "\(sbinDir)" ]; then echo "\(sbinDir)" >> "$tmp"; fi
                 install -m 0644 "$tmp" "/etc/paths.d/homebrew"
                 """,
                 timeout: 30,
                 safety: .privileged,
                 requiresSudo: true,
                 stdin: { [weak self] in (self?.sudoPasswordCache ?? "") == "" ? nil : (self!.sudoPasswordCache! + "\n").data(using: .utf8) })
        ]
    }

    private func ensureGitSteps() -> [ChatPlanStep] {
        var steps: [ChatPlanStep] = []
        // If git is not present, attempt Xcode CLT then brew git
        steps.append(ChatPlanStep(title: "Ensure git (Command Line Tools)",
                          command: """
                          if command -v git >/dev/null 2>&1; then exit 0; fi
                          if /usr/bin/xcode-select -p >/dev/null 2>&1; then exit 0; fi
                          touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
                          softwareupdate -l >/dev/null 2>&1 || true
                          PKG="$(softwareupdate -l 2>/dev/null | awk -F'*' '/Command Line Tools/ {print $2}' | sed -e 's/^ *//' | tail -n1)"
                          if [ -n "$PKG" ]; then softwareupdate -i "$PKG" -a || true; fi
                          rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress || true
                          """,
                          timeout: 1200,
                          safety: .needsConsent,
                          requiresSudo: true,
                          stdin: { [weak self] in (self?.sudoPasswordCache ?? "") == "" ? nil : (self!.sudoPasswordCache! + "\n").data(using: .utf8) }))
        let prefix = brewPrefixGuess()
        let brew = FileManager.default.fileExists(atPath: "\(prefix)/bin/brew") ? "\(prefix)/bin/brew" : "brew"
        steps += ensureHomebrewSteps()
        steps.append(ChatPlanStep(title: "Install git via Homebrew (if still missing)",
                          command: """
                          if command -v git >/dev/null 2>&1; then exit 0; fi
                          "\(brew)" install git
                          """,
                          timeout: 1200,
                          safety: .safe))
        return steps
    }

    private func ensureMasSteps() -> [ChatPlanStep] {
        let prefix = brewPrefixGuess()
        let brew = FileManager.default.fileExists(atPath: "\(prefix)/bin/brew") ? "\(prefix)/bin/brew" : "brew"
        var steps: [ChatPlanStep] = []
        steps.append(ChatPlanStep(title: "Install mas via Homebrew (if missing)",
                          command: """
                          if command -v mas >/dev/null 2>&1; then exit 0; fi
                          "\(brew)" install mas
                          """,
                          timeout: 600,
                          safety: .safe))
        return steps
    }

    // MARK: - Plan execution with consolidated consent

    private func executePlanWithConsent(_ plan: ChatPlan) async {
        // Summarize steps and safety levels
        let summary = planSummary(plan)
        let requiresConsent = plan.steps.contains { $0.safety != .safe }
        var approved = true

        if requiresConsent {
            approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                requestComposerSendCommandConsent?(summary) { ok in cont.resume(returning: ok) } ?? {
                    cont.resume(returning: false)
                }()
            }
        }

        if !approved {
            messages.append(ChatMessage(role: "assistant", content: "Cancelled. No changes were made."))
            saveHistory()
            return
        }

        // Execute steps
        for step in plan.steps {
            let ok = await runStep(step)
            if !ok {
                messages.append(ChatMessage(role: "assistant", content: "Step failed: \(step.title). Aborting plan."))
                saveHistory()
                return
            }
        }

        messages.append(ChatMessage(role: "assistant", content: "Completed: \(plan.description)"))
        saveHistory()
    }

    private func planSummary(_ plan: ChatPlan) -> String {
        var lines: [String] = []
        lines.append("I will perform the following steps:")
        for (i, s) in plan.steps.enumerated() {
            let badge: String = {
                switch s.safety {
                case .safe: return "safe"
                case .needsConsent: return "consent"
                case .privileged: return "privileged"
                }
            }()
            lines.append("\(i+1). [\(badge)] \(s.title)")
        }
        lines.append("")
        lines.append("Proceed?")
        return lines.joined(separator: "\n")
    }

    private func runStep(_ step: ChatPlanStep) async -> Bool {
        messages.append(ChatMessage(role: "assistant", content: "Running: \(step.title)"))
        saveHistory()

        let stdinData: Data?

        let rawCommand: String
        if step.requiresSudo {
            // Ensure we have a password
            if (sudoPasswordCache == nil || sudoPasswordCache?.isEmpty == true) {
                let pwd = await obtainSudoPassword(description: "Administrator privileges are required to run: \(step.title)")
                guard let pwd, !pwd.isEmpty else { return false }
                sudoPasswordCache = pwd
            }
            // Wrap command with sudo -S
            rawCommand = "sudo -S /bin/bash -lc \(escapeShellArg(step.command))"
            stdinData = (sudoPasswordCache! + "\n").data(using: .utf8)
        } else {
            rawCommand = step.command
            stdinData = step.stdin?()
        }
        let finalCommand = envPathPrefixExport() + rawCommand

        let handle = BashRunner.run(command: finalCommand, timeout: step.timeout, stdinData: stdinData)
        var collected = ""
        for await chunk in handle.stream { collected += chunk.text }
        let code = await handle.exitCodeTask.value

        if code == 0 {
            let out = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: "Output:\n\(out.prefix(4000))"))
                saveHistory()
            }
            return true
        } else {
            // On sudo failure, clear cache to force re-prompt next time
            if step.requiresSudo { sudoPasswordCache = nil }
            let out = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: "assistant", content: "Command failed (exit \(code)) for step '\(step.title)'. Output:\n\(out.isEmpty ? "(no output)" : out.prefix(4000))"))
            saveHistory()
            return false
        }
    }

    // MARK: - Utilities

    private func envPathPrefixExport() -> String {
        // Build a PATH that includes common Homebrew locations ahead of the current PATH
        // We avoid relying on shell init files since we run non-login, non-interactive shells
        let prefix = brewPrefixGuess()
        let brewBin = "\(prefix)/bin"
        let brewSbin = "\(prefix)/sbin"
        // Also include legacy/intel locations just in case
        let fallbackBin = "/usr/local/bin"
        let fallbackSbin = "/usr/local/sbin"
        return "export PATH=\"\(brewBin):\(brewSbin):\(fallbackBin):\(fallbackSbin):$PATH\"; "
    }

    private func brewPrefixGuess() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") { return "/opt/homebrew" }
        if FileManager.default.fileExists(atPath: "/usr/local/bin/brew") { return "/usr/local" }
        // Fallback by arch
        return (unameMachine() == "arm64") ? "/opt/homebrew" : "/usr/local"
    }

    private func unameMachine() -> String {
        var uts = utsname()
        uname(&uts)
        let m = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { ptr in
                return String(cString: ptr)
            }
        }
        return m
    }

    private func firstMatch(regex: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: s.utf16.count)
        if let m = re.firstMatch(in: s, options: [], range: range),
           m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: s) {
            let raw = String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private func escapeShellArg(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func obtainSudoPassword(description: String) async -> String? {
        if let cached = sudoPasswordCache, !cached.isEmpty {
            return cached
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            pendingSudoRequestDescription = description
            onSudoPasswordProvided = { [weak self] pwd in
                if let pwd, !pwd.isEmpty {
                    self?.sudoPasswordCache = pwd
                    cont.resume(returning: pwd)
                } else {
                    cont.resume(returning: nil)
                }
            }
            needsSudoPasswordPrompt = true
        }
    }

    // MARK: - Existing intents (time/tree)

    private func matchesTimeIntent(_ text: String) -> Bool {
        let l = text.lowercased()
        return l == "what time is it?" || l == "what time is it" || l == "time"
    }

    private func matchesCreateTreeIntent(_ text: String) -> Bool {
        let l = text.lowercased()
        let create = l.contains("create") || l.contains("make") || l.contains("build") || l.contains("generate") || l.contains("map")
        let treeish = l.contains("tree") || l.contains("hierarchy") || l.contains("hierarchical") || l.contains("structure")
        let desktop = l.contains("desktop") || l.contains("to desktop") || l.contains("on desktop") || l.contains("save to desktop") || l.contains("write to desktop") || l.contains("put on desktop")
        return create && treeish && desktop
    }

    private func matchesRootTreeIntent(_ text: String) -> Bool {
        let l = text.lowercased()
        let treeish = l.contains("tree") || l.contains("hierarchy") || l.contains("hierarchical") || l.contains("structure")
        let rootish =
            l.contains("root of the hard drive") ||
            l.contains("root of the drive") ||
            l.contains("root of disk") ||
            l.contains("root of the disk") ||
            l.contains("root directory") ||
            l.contains("from the root") ||
            l.contains("from root") ||
            l.contains("entire disk") ||
            l.contains("entire drive") ||
            l.contains("all of /") ||
            l == "tree /" ||
            l.contains("tree /")
        return treeish && rootish
    }

    private func parseRequestedDepth(from text: String) -> Int? {
        let l = text.lowercased()
        let patterns = [
            #"depth\s+(\d+)"#,
            #"to\s+depth\s+(\d+)"#,
            #"limit\s+(\d+)\s+level"#,
            #"-l\s+(\d+)"#,
            #"-L\s+(\d+)"#
        ]
        for p in patterns {
            if let d = firstInt(matching: p, in: l) {
                return clampDepth(d)
            }
        }
        return nil
    }

    private func clampDepth(_ d: Int) -> Int {
        max(1, min(d, 8))
    }

    private func firstInt(matching regex: String, in s: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: regex, options: []) else { return nil }
        let range = NSRange(location: 0, length: s.utf16.count)
        if let m = re.firstMatch(in: s, options: [], range: range),
           m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: s) {
            return Int(s[r])
        }
        return nil
    }

    private func parseRequestedRoot(from text: String) -> String? {
        let l = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = extractPath(after: "from", in: l) ?? extractPath(after: "root", in: l)
        if let path = candidates {
            return resolveTilde(in: path)
        }
        return nil
    }

    private func extractPath(after keyword: String, in s: String) -> String? {
        let components = s.components(separatedBy: .whitespacesAndNewlines)
        guard let idx = components.firstIndex(where: { $0.lowercased() == keyword }) else { return nil }
        let nextIndex = components.index(after: idx)
        guard nextIndex < components.count else { return nil }
        var tail = components[nextIndex...].joined(separator: " ")
        if let stopRange = tail.range(of: #"(?=\s(to|on|at|with|depth)\b)"#, options: .regularExpression) {
            tail = String(tail[..<stopRange.lowerBound])
        }
        return tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
    }

    private func resolveTilde(in path: String) -> String {
        if path.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if path == "~" { return home }
            let suffix = String(path.dropFirst())
            return home + suffix
        }
        return path
    }

    private func preferredTreeCommand() -> String? {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tree") { return "/opt/homebrew/bin/tree" }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tree") { return "/usr/local/bin/tree" }
        return nil
    }

    private func escapePath(_ path: String) -> String {
        var s = path.replacingOccurrences(of: "\"", with: "\\\"")
        s = s.replacingOccurrences(of: "`", with: "\\`")
        return "\"\(s)\""
    }

    private func makeFindTreeCommand(root: String, depth: Int) -> String {
        return """
        root=\(escapePath(root)); \
        find "$root" -print | awk -v r="$root" -v max=\(depth) ' \
        BEGIN { n=split(r, a, "/"); } \
        { \
          if (index($0, r) != 1) next; \
          m=split($0, b, "/"); \
          d=m-n; if (d<0) d=0; if (d>max) next; \
          indent=""; for(i=0;i<d;i++) indent=indent "  "; \
          name=$0; sub(r"/?", "", name); if (name=="") name=substr($0, length($0)); \
          if (name=="") name=r; \
          printf("%%s%%s\\n", indent, name); \
        }'
        """
    }

    // MARK: - Time/Tree runners

    private func runTimeIntent() async {
        let cmd = "date +\"%H:%M:%S %Z\""
        let handle = BashRunner.run(command: cmd, timeout: 10)
        var collected = ""
        for await chunk in handle.stream { collected += chunk.text }
        let code = await handle.exitCodeTask.value
        let output = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = (code == 0) ? "The current time is: \(output)" : "Command failed (exit \(code)). Output:\n\(output)"
        messages.append(ChatMessage(role: "user", content: "bash$ \(cmd)"))
        messages.append(ChatMessage(role: "assistant", content: answer))
        saveHistory()
    }

    private func userDesktopURL() -> URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private func runCreateTreeDatabase(from root: String, depth: Int) async {
        let maxDepth = clampDepth(depth)
        let resolvedRoot = root

        let genCmd: String
        if let tree = preferredTreeCommand() {
            genCmd = "\(tree) -L \(maxDepth) -a -n \(escapePath(resolvedRoot)) 2>/dev/null"
        } else {
            genCmd = makeFindTreeCommand(root: resolvedRoot, depth: maxDepth) + " 2>/dev/null"
        }

        let consentText = """
        I will generate a tree listing of \(resolvedRoot) (depth \(maxDepth)) by running:

        \(genCmd)

        Then I will ask you where to save the file (defaulting to your Desktop).
        """
        let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            requestComposerSendCommandConsent?(consentText) { ok in cont.resume(returning: ok) } ?? {
                cont.resume(returning: false)
            }()
        }
        if !approved {
            messages.append(ChatMessage(role: "assistant", content: "Cancelled. No files were created."))
            return
        }

        let handle = BashRunner.run(command: genCmd, timeout: 180)
        var output = ""
        for await chunk in handle.stream { output += chunk.text }
        let code = await handle.exitCodeTask.value

        guard code == 0 else {
            let stderrOut = output.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: "user", content: "bash$ \(genCmd)"))
            messages.append(ChatMessage(role: "assistant", content: """
            Failed to generate the tree listing (exit \(code)).

            stderr/stdout:
            \(stderrOut.isEmpty ? "(no output)" : stderrOut)
            """))
            saveHistory()
            return
        }

        let saveURL = await presentSavePanel(suggestedFileName: "filesystem_tree.txt", defaultDirectory: userDesktopURL())
        guard let destination = saveURL else {
            messages.append(ChatMessage(role: "assistant", content: "Save cancelled. The generated listing was not written to disk."))
            return
        }

        do {
            try (output.data(using: .utf8) ?? Data()).write(to: destination, options: .atomic)
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let sizeText: String = {
                if let size = attrs?[.size] as? NSNumber {
                    let fmt = ByteCountFormatter()
                    fmt.allowedUnits = [.useKB, .useMB]
                    fmt.countStyle = .file
                    return " (\(fmt.string(fromByteCount: size.int64Value)))"
                }
                return ""
            }()
            messages.append(ChatMessage(role: "user", content: "bash$ \(genCmd)"))
            messages.append(ChatMessage(role: "assistant", content: """
            Saved the tree listing to:
            \(destination.path)\(sizeText)
            """))
            saveHistory()
        } catch {
            messages.append(ChatMessage(role: "assistant", content: "Failed to save file: \(error.localizedDescription)"))
        }
    }

    private func runRootTreeIntent(root: String, depth: Int) async {
        let resolvedRoot = root
        let maxDepth = clampDepth(depth)

        let genCmd: String
        if let tree = preferredTreeCommand() {
            genCmd = "\(tree) -L \(maxDepth) -a -n \(escapePath(resolvedRoot)) 2>/dev/null"
        } else {
            genCmd = makeFindTreeCommand(root: resolvedRoot, depth: maxDepth) + " 2>/dev/null"
        }

        let consentText = """
        I will generate a tree listing of \(resolvedRoot) to depth \(maxDepth) by running:

        \(genCmd)

        Then I will ask you where to save the file (defaulting to your Desktop).
        """
        let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            requestComposerSendCommandConsent?(consentText) { ok in cont.resume(returning: ok) } ?? {
                cont.resume(returning: false)
            }()
        }
        if !approved {
            messages.append(ChatMessage(role: "assistant", content: "Cancelled. No files were created."))
            return
        }

        let handle = BashRunner.run(command: genCmd, timeout: 300)
        var output = ""
        for await chunk in handle.stream { output += chunk.text }
        let code = await handle.exitCodeTask.value

        guard code == 0 else {
            let stderrOut = output.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: "user", content: "bash$ \(genCmd)"))
            messages.append(ChatMessage(role: "assistant", content: """
            Failed to generate the tree listing (exit \(code)).

            stderr/stdout:
            \(stderrOut.isEmpty ? "(no output)" : stderrOut)
            """))
            saveHistory()
            return
        }

        let saveURL = await presentSavePanel(suggestedFileName: "root_structure.txt", defaultDirectory: userDesktopURL())
        guard let destination = saveURL else {
            messages.append(ChatMessage(role: "assistant", content: "Save cancelled. The generated listing was not written to disk."))
            return
        }

        do {
            try (output.data(using: .utf8) ?? Data()).write(to: destination, options: .atomic)
            messages.append(ChatMessage(role: "user", content: "bash$ \(genCmd)"))
            messages.append(ChatMessage(role: "assistant", content: "Saved the tree listing to:\n\(destination.path)"))
            saveHistory()
        } catch {
            messages.append(ChatMessage(role: "assistant", content: "Failed to save file: \(error.localizedDescription)"))
        }
    }

    private func presentSavePanel(suggestedFileName: String, defaultDirectory: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Tree Listing"
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        if let dir = defaultDirectory {
            panel.directoryURL = dir
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    func provideSudoPassword(_ password: String?) {
        onSudoPasswordProvided?(password)
        onSudoPasswordProvided = nil
        needsSudoPasswordPrompt = false
        sudoPasswordCache = password
    }

    // MARK: - Convenience actions

    /// Install `nmap` system-wide using the rule-based installer.
    /// This will:
    /// 1) Ensure Homebrew is installed
    /// 2) Add Homebrew to the system PATH (via /etc/paths.d) so it's available for all users
    /// 3) Install/upgrade the `nmap` formula
    /// The flow uses the consolidated consent dialog and sudo prompting already implemented.
    func installNmapSystemWide() async {
        let request = "install nmap system-wide and verify"
        if let plan = buildInstallPlan(from: request) {
            await executePlanWithConsent(plan)
        } else {
            messages.append(ChatMessage(role: "assistant", content: "Sorry, I couldn't build an install plan for nmap."))
            saveHistory()
        }
    }
}

private struct ChatPlan {
    let description: String
    let steps: [ChatPlanStep]
}

private struct ChatPlanStep {
    enum Safety { case safe, needsConsent, privileged }
    let title: String
    let command: String
    let timeout: TimeInterval
    let safety: Safety
    // Whether the step must be executed with sudo -S; if true, the runner will prompt/cache a password
    var requiresSudo: Bool = false
    // Optional stdin provider; used to feed passwords or other input when needed
    var stdin: (() -> Data?)? = nil
}

