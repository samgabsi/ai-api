import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView_Hybrid: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var activeSkin: ChatSkin = .terminalSplit
    @State private var showSettings = false
    @State private var leftEditorText = ""
    @AppStorage("composerEnterSends") private var enterToSend: Bool = false

    // Track whether the user is currently pinned to the bottom of the scroll view
    @State private var pinnedToBottom: Bool = true

    // Terminal state
    @State private var terminalEntries: [TerminalEntry] = []
    @State private var pendingCommand: String = ""
    @State private var showSendCommandConsent = false
    @State private var lastCommandOutputToSend: String = ""
    @State private var showSendOutputConsent = false
    // Track last command for contextualized message
    @State private var lastRanCommand: String = ""
    // Defer showing the output alert if the command alert is currently visible
    @State private var pendingOutputAlert: Bool = false

    // Export state (kept from earlier)
    @State private var showExportChoiceAlert = false
    @State private var showFinalClearConfirm = false
    @State private var isExporting = false
    @State private var exportDocument = TranscriptDocument(text: "")
    @State private var pendingClearAfterExport = false

    // API Key prompt state
    @State private var showAPIKeyPrompt = false
    @State private var pendingAPIKey: String = ""

    // Sudo prompt state
    @State private var sudoPassword: String = ""

    var body: some View {
        ZStack {
            activeSkin.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider()
                mainSplit
                Divider()
                bottomConsole
                terminalSection
            }
            .foregroundColor(activeSkin.userTextColor)
            .font(activeSkin.font)

            if showSettings {
                Color.black.opacity(0.35).ignoresSafeArea()
                SettingsView(selectedSkin: $activeSkin, showSettings: $showSettings)
                    .environmentObject(vm)
                    .frame(width: 480, height: 520)
                    .background(activeSkin.leftPaneBackground)
                    .cornerRadius(12)
                    .shadow(radius: 20)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: defaultTranscriptFilename()
        ) { result in
            switch result {
            case .success:
                if pendingClearAfterExport {
                    vm.clearHistory()
                }
            case .failure:
                break
            }
            pendingClearAfterExport = false
        }
        .alert("Export before clearing?", isPresented: $showExportChoiceAlert) {
            Button("Export…") {
                exportDocument = TranscriptDocument(text: makeTranscriptText(from: vm.messages))
                pendingClearAfterExport = true
                isExporting = true
            }
            Button("Clear without Export") {
                showFinalClearConfirm = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You can save the current AI conversation as a .txt file before clearing.")
        }
        .alert("Clear AI Response?", isPresented: $showFinalClearConfirm) {
            Button("Clear", role: .destructive) {
                vm.clearHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to clear the AI response section? This action cannot be undone and the data isn't presently backed up anywhere.")
        }
        // Consent to send command to ChatGPT from Quick Prompt
        .alert("Send command to ChatGPT?", isPresented: $showSendCommandConsent) {
            Button("Send to ChatGPT") { Task { await vm.appendAndSendUserMessage("bash$ \(pendingCommand)") } }
            Button("Don’t Send", role: .cancel) { }
        } message: {
            Text("Allow sending this command for analysis?\n\n\(pendingCommand)")
        }
        // Consent to send output to ChatGPT (contextualized) from Quick Prompt
        .alert("Send output to ChatGPT?", isPresented: $showSendOutputConsent) {
            Button("Send Output") {
                let contextualized = """
                I ran the following shell command:

                bash$ \(lastRanCommand)

                Here is the full output:

                \(lastCommandOutputToSend)

                Please analyze the output. If there are errors, explain the likely cause and suggest fixes. If it succeeded, summarize what happened and any next steps I might take.
                """
                Task { await vm.appendAndSendUserMessage(contextualized) }
            }
            Button("Don’t Send", role: .cancel) { }
        } message: {
            Text("Allow sending the command output for analysis?")
        }
        // API Key prompt
        .alert("Enter OpenAI API Key", isPresented: $showAPIKeyPrompt) {
            TextField("sk-...", text: $pendingAPIKey)
            Button("Save") {
                let key = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    vm.saveAPIKey(key)
                }
                pendingAPIKey = ""
            }
            Button("Cancel", role: .cancel) {
                pendingAPIKey = ""
            }
        } message: {
            Text("Your key will be stored securely in the Keychain.")
        }
        // Sudo password prompt, driven by ViewModel
        .alert("Administrator Password Required", isPresented: $vm.needsSudoPasswordPrompt) {
            SecureField("Password", text: $sudoPassword)
            Button("Run") {
                let pwd = sudoPassword
                sudoPassword = ""
                vm.provideSudoPassword(pwd)
            }
            Button("Cancel", role: .cancel) {
                sudoPassword = ""
                vm.provideSudoPassword(nil)
            }
        } message: {
            Text(vm.pendingSudoRequestDescription.isEmpty ? "Enter your password to run this command with sudo." : vm.pendingSudoRequestDescription)
        }
        .onChange(of: vm.messages.count) { _, _ in
            // Keep AI pane scrolled if needed (optional)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image("NeuroDeskLogo")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("NeuroDesk AI")
                    .font(.title3).bold()
                    .foregroundColor(activeSkin.accentColor)
            }
            Spacer()
            // API Calls Remaining counter (commented out per request)
            // apiCounterView
            Button { showSettings = true } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            if vm.apiKeyPresent {
                Button("Clear API Key") { vm.clearAPIKey() }
            } else {
                Button("Set API Key") { showAPIKeyEntry() }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // Keeping the implementation around in case you want to re-enable it later.
    private var apiCounterView: some View {
        let used = vm.displayUsed ?? 0
        let limit = vm.displayLimitFallbackAware
        let remaining = vm.displayRemainingFallbackAware
        let percent = vm.displayPercentUsed
        let pctText = String(format: "%.0f%%", percent * 100)

        let role = vm.usageColorRole
        let color: Color = {
            switch role {
            case .normal: return .green
            case .warning: return .yellow
            case .critical: return .red
            }
        }()

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge")
                        .foregroundColor(color)
                    Text("API Calls")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    Text("\(used)/\(limit) used")
                        .font(.caption2)
                    Text("(\(pctText))")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("• \(remaining) remaining")
                        .font(.caption2)
                }
                if let reset = vm.displayReset {
                    Text("Resets: \(reset.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("Window ends: \(vm.fallbackWindowEndsAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                ProgressView(value: percent)
                    .tint(color)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            }
        }
        .padding(8)
        .background(activeSkin.leftPaneBackground.opacity(0.15))
        .cornerRadius(8)
        .help(vm.usageTooltip)
    }

    private var mainSplit: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                leftPane.frame(width: max(320, geo.size.width * 0.42))
                    .background(activeSkin.leftPaneBackground)
                Divider()
                rightPane.frame(maxWidth: .infinity)
                    .background(activeSkin.rightPaneBackground)
            }
        }
    }

    private var leftPane: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Composer").font(.headline)
                Spacer()
                Toggle("Press Enter to send", isOn: $enterToSend)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .help("When on: Enter sends, Shift+Enter inserts a newline.\nWhen off: Enter inserts newline, ⌘↩ sends.")
                    .frame(maxWidth: 220)
                Button("Send →") {
                    let text = leftEditorText
                    Task {
                        // Intercept Bash: requests
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bash:") {
                            let natural = String(text.dropFirst(5))
                            await vm.handleBashRequest(natural)
                        } else {
                            await MainActor.run { vm.inputText = text }
                            await vm.sendCurrentInput()
                        }
                        await MainActor.run { leftEditorText = "" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isSending || leftEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !vm.canSend)
                .help(vm.canSend ? "" : "Blocked to prevent exceeding rate limit.")
            }
            .padding([.top, .horizontal])

            InterceptingTextEditor(
                text: $leftEditorText,
                isDisabled: vm.isSending || !vm.canSend,
                enterSends: enterToSend,
                onSend: {
                    let text = leftEditorText
                    Task {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bash:") {
                            let natural = String(text.dropFirst(5))
                            await vm.handleBashRequest(natural)
                        } else {
                            await MainActor.run { vm.inputText = text }
                            await vm.sendCurrentInput()
                        }
                        await MainActor.run { leftEditorText = "" }
                    }
                }
            )
            .frame(minHeight: 140)
            .padding(8)
            .background(Color.clear)

            HStack {
                Spacer()
                Button("Clear") {
                    Task { await MainActor.run { leftEditorText = "" } }
                }
                .disabled(vm.isSending)
            }
            .padding()
        }
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Response").font(.headline).foregroundColor(activeSkin.aiTextColor)
                Spacer()
                Button {
                    if hasAnyNonSystemContent() {
                        showExportChoiceAlert = true
                    } else {
                        showFinalClearConfirm = true
                    }
                } label: {
                    Label("Export & Clear…", systemImage: "trash")
                }
                .disabled(!hasAnyMessageBeyondSystem)
            }
            .padding([.horizontal, .top])

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.messages) { msg in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(msg.role.capitalized).font(.caption).foregroundColor(.secondary)
                                    Text(msg.content)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(msg.role == "assistant" ? activeSkin.aiTextColor : activeSkin.userTextColor)
                                        .textSelection(.enabled)
                                        .padding(8)
                                }
                                Spacer()
                            }
                            .id(msg.id)
                        }
                        if let error = vm.lastErrorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                                .padding(.horizontal)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    if let last = vm.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if pinnedToBottom, let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: vm.messages.last?.content.count ?? 0) { _, _ in
                    guard pinnedToBottom, let last = vm.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var bottomConsole: some View {
        HStack(spacing: 8) {
            Text("Quick Prompt")
                .font(.caption2)
                .padding(6)
                .background(activeSkin.leftPaneBackground.opacity(0.6))
                .cornerRadius(6)

            TextField("Type a shell command and press ⏎…", text: $pendingCommand)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    if vm.canSend {
                        runCommandFlow(pendingCommand)
                        pendingCommand = ""
                    }
                }
                .submitLabel(.go)
                .disabled(vm.isSending || !vm.canSend)

            Button("Run") {
                runCommandFlow(pendingCommand)
                pendingCommand = ""
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pendingCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !vm.canSend)
            .help(vm.canSend ? "" : "Blocked to prevent exceeding rate limit.")
        }
        .padding()
        .background(activeSkin.leftPaneBackground.opacity(0.06))
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Terminal Output").font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(terminalEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("bash$ \(entry.command)")
                                    .font(.system(.body, design: .monospaced)).bold()
                                Spacer()
                                Text(entry.statusText)
                                    .font(.caption)
                                    .foregroundColor(entry.exitCode == 0 ? .green : .orange)
                            }
                            ForEach(entry.chunks.indices, id: \.self) { idx in
                                let c = entry.chunks[idx]
                                Text(c.text)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(c.stream == .stderr ? .red : .primary)
                            }
                        }
                        .padding(8)
                        .background(activeSkin.leftPaneBackground.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Quick Prompt Command Flow (unchanged semantics, 120s timeout)

    private func runCommandFlow(_ command: String) {
        guard vm.canSend else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Ask consent to send the command to ChatGPT
        pendingCommand = trimmed
        showSendCommandConsent = true

        // Run command and stream output to terminalEntries
        let entry = TerminalEntry(command: trimmed)
        terminalEntries.append(entry)
        let index = terminalEntries.count - 1

        let handle = BashRunner.run(command: trimmed, timeout: 120)
        lastRanCommand = trimmed

        Task(priority: .userInitiated) {
            var output = "" // Local to the child task
            for await chunk in handle.stream {
                output += chunk.text
                await MainActor.run {
                    let mapped: TerminalEntry.Chunk.Stream = (chunk.stream == .stderr) ? .stderr : .stdout
                    terminalEntries[index].chunks.append(.init(stream: mapped, text: chunk.text))
                }
            }

            let code = await handle.exitCodeTask.value

            await MainActor.run {
                terminalEntries[index].exitCode = code
                terminalEntries[index].endedAt = Date()
                lastCommandOutputToSend = output
                showSendOutputConsent = true
            }
        }
    }

    // MARK: - Helpers

    private var hasAnyMessageBeyondSystem: Bool {
        !(vm.messages.count == 1 && vm.messages.first?.role == "system")
    }

    private func hasAnyNonSystemContent() -> Bool {
        vm.messages.contains { $0.role != "system" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func defaultTranscriptFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "NeuroDesk Transcript \(formatter.string(from: Date())).txt"
    }

    private func makeTranscriptText(from messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for msg in messages {
            let header = msg.role.capitalized
            lines.append("\(header):")
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // Present API key prompt
    private func showAPIKeyEntry() {
        pendingAPIKey = ""
        showAPIKeyPrompt = true
    }
}

// Terminal models in-view for simplicity
private struct TerminalEntry: Identifiable {
    struct Chunk {
        enum Stream { case stdout, stderr }
        let stream: Stream
        let text: String
    }

    let id = UUID()
    let command: String
    var chunks: [Chunk] = []
    var exitCode: Int32? = nil
    var startedAt: Date = Date()
    var endedAt: Date? = nil

    var statusText: String {
        if let code = exitCode {
            return "exit \(code)"
        } else {
            return "running…"
        }
    }
}

// Export document for transcripts
struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            self.text = str
        } else {
            self.text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return .init(regularFileWithContents: data)
    }
}
