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
    // Track the last assistant message id to observe streaming updates
    @State private var lastMessageId: UUID?

    // MARK: - Pure SwiftUI Export & Clear state
    @State private var showExportChoiceAlert = false
    @State private var showFinalClearConfirm = false
    @State private var isExporting = false
    @State private var exportDocument = TranscriptDocument(text: "")
    @State private var pendingClearAfterExport = false

    var body: some View {
        ZStack {
            activeSkin.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider()
                mainSplit
                Divider()
                bottomConsole
            }
            .foregroundColor(activeSkin.userTextColor)
            .font(activeSkin.font)

            if showSettings {
                Color.black.opacity(0.35).ignoresSafeArea()
                SettingsView(selectedSkin: $activeSkin, showSettings: $showSettings)
                    .environmentObject(vm)
                    .frame(width: 480, height: 420)
                    .background(activeSkin.leftPaneBackground)
                    .cornerRadius(12)
                    .shadow(radius: 20)
            }
        }
        // Pure SwiftUI exporter
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
                // You can optionally show a SwiftUI alert for error; keeping silent here.
                break
            }
            pendingClearAfterExport = false
        }
        // Export choice alert
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
        // Final destructive confirmation
        .alert("Clear AI Response?", isPresented: $showFinalClearConfirm) {
            Button("Clear", role: .destructive) {
                vm.clearHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to clear the AI response section? This action cannot be undone and the data isn't presently backed up anywhere.")
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
                        // Defer publishing changes to next runloop on main actor
                        await MainActor.run {
                            vm.inputText = text
                        }
                        await vm.sendCurrentInput()
                        // Defer clearing leftEditorText to next run loop to avoid publishing during update
                        await MainActor.run {
                            leftEditorText = ""
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isSending || leftEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.top, .horizontal])

            InterceptingTextEditor(
                text: $leftEditorText,
                isDisabled: vm.isSending,
                enterSends: enterToSend,
                onSend: {
                    let text = leftEditorText
                    Task {
                        await MainActor.run {
                            vm.inputText = text
                        }
                        await vm.sendCurrentInput()
                        await MainActor.run {
                            leftEditorText = ""
                        }
                    }
                }
            )
            .frame(minHeight: 140)
            .padding(8)
            .background(Color.clear)

            HStack {
                Spacer()
                Button("Clear") {
                    // Defer to avoid publishing during update if triggered by key handling
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
                    // Show pure SwiftUI alert flow to export and/or clear
                    if hasAnyNonSystemContent() {
                        showExportChoiceAlert = true
                    } else {
                        // Nothing meaningful to export; just confirm destructive clear
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
                    // A background GeometryReader that keeps pinnedToBottom updated based on scroll position
                    GeometryReader { _ in
                        Color.clear
                            .onAppear { pinnedToBottom = true }
                    }
                    .frame(height: 0)

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

                        // Bottom sentinel
                        Color.clear
                            .frame(height: 1)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: BottomOffsetKey.self, value: geo.frame(in: .named("scroll")).minY)
                                }
                            )
                            .id("BottomSentinel")
                    }
                    .padding()
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(BottomOffsetKey.self) { bottomMinY in
                    let threshold: CGFloat = 60
                    pinnedToBottom = (bottomMinY > -threshold)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if pinnedToBottom, let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    lastMessageId = vm.messages.last?.id
                }
                .onChange(of: vm.messages.last?.content.count ?? 0) { _, _ in
                    guard pinnedToBottom, let last = vm.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = vm.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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

            TextField("Type quickly and press ⏎ to send…", text: $vm.inputText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    Task { await vm.sendCurrentInput() }
                }
                .submitLabel(.send)
                .disabled(vm.isSending)

            if vm.isSending {
                Button("Stop") { vm.cancelStreaming() }
            } else {
                Button("Send") { Task { await vm.sendCurrentInput() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(activeSkin.leftPaneBackground.opacity(0.06))
    }

    private func showAPIKeyEntry() {
        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API key"
        alert.informativeText = "Your key will be securely stored in the Keychain."
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        input.stringValue = KeychainHelper.load(key: ChatViewModel.apiKeyKeychainKey) ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let entered = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !entered.isEmpty { vm.saveAPIKey(entered) }
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
            lines.append("") // blank line between messages
        }
        return lines.joined(separator: "\n")
    }
}

// PreferenceKey to carry the bottom sentinel’s minY in the scroll coordinate space
private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - SwiftUI FileDocument for exporting plain text
struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

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
