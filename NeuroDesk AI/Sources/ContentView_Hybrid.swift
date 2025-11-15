import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView_Hybrid: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var activeSkin: ChatSkin = .terminalSplit
    @State private var showSettings = false
    @State private var leftEditorText = ""
    @AppStorage("composerEnterSends") private var enterToSend: Bool = false

    // Onboarding states
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var showOnboardingOverlay: Bool = false

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

    // Image attachments for Bash tool
    @State private var pendingUploads: [PendingUpload] = []
    @State private var showImageImporter: Bool = false

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

    // Composer consent gating state
    @State private var composerPendingCommand: String = ""
    @State private var composerShowSendCommandConsent = false
    @State private var composerCommandConsentCompletion: ((Bool) -> Void)?
    @State private var composerPendingOutputCommand: String = ""
    @State private var composerPendingOutput: String = ""
    @State private var composerShowSendOutputConsent = false
    @State private var composerOutputConsentCompletion: ((Bool) -> Void)?

    // Composer-specific image attachments
    @State private var composerPendingUploads: [PendingUpload] = []
    @State private var composerShowImageImporter: Bool = false

    // Preview state for composer images
    @State private var composerPreviewImage: NSImage? = nil
    @State private var composerPreviewTitle: String = ""
    @State private var showComposerPreview: Bool = false

    // Composer Vision Warning and error dismissal
    @State private var showComposerVisionWarning: Bool = false
    @State private var composerErrorDismissed: Bool = false

    // Added states for expanded message and line limit
    @State private var expandedMessageIDs: Set<UUID> = []
    private let resultsCollapsedLineLimit: Int = 12

    // Simple model for an image attachment pending upload
    private struct PendingUpload: Identifiable {
        let id = UUID()
        let filename: String
        let data: Data
        let mimeType: String?
        let bytes: Int
    }

    // Convert pending uploads into BashImageUpload payloads
    private func makeBashUploads() -> [BashImageUpload] {
        pendingUploads.map { BashImageUpload(filename: $0.filename, data: $0.data, mimeType: $0.mimeType) }
    }

    // Infer MIME type from URL using UTType if available
    private func mimeType(for url: URL) -> String? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.preferredMIMEType
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }

    private func isImageMime(_ mime: String?) -> Bool {
        guard let m = mime?.lowercased() else { return false }
        return m.hasPrefix("image/")
    }

    private func isLikelyImage(ext: String) -> Bool {
        let e = ext.lowercased()
        return ["png","jpg","jpeg","gif","webp","bmp","tif","tiff","heic","heif","svg"].contains(e)
    }

    private func formatBytes(_ n: Int) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(n))
    }

    private func saveFile(from url: URL, suggestedName: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? url.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    // If file exists, try replacing
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
            }
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Vision capable models (local copy of list)
    private var visionCapableModels: Set<String> { [
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-preview",
        "gpt-4o", "gpt-4o-mini"
    ] }
    
    // Added helper to format timestamps
    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    var body: some View {
        _ = Group {
            if showOnboardingOverlay {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("Welcome to NeuroDesk AI").font(.title3).bold()
                    Text("Quick start guide").font(.subheadline).foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "1.circle")
                            Text("Set your OpenAI API key in the header. This enables ChatGPT responses.")
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "2.circle")
                            Text("Compose a prompt in the Composer or run a shell command in Quick Command.")
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "3.circle")
                            Text("Attach files or images in the Composer and send for analysis.")
                        }
                    }
                    .frame(maxWidth: 420)
                    HStack(spacing: 12) {
                        Button("Set API Key") {
                            showOnboardingOverlay = false
                            showAPIKeyEntry()
                        }
                        Button("Got it") {
                            hasSeenOnboarding = true
                            showOnboardingOverlay = false
                        }
                    }
                }
                .padding()
                .background(activeSkin.leftPaneBackground)
                .cornerRadius(12)
                .shadow(radius: 20)
            }
        }

        return ZStack {
            activeSkin.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider()
                mainSplit
                Divider()
                bottomConsole
                if !pendingUploads.isEmpty {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(pendingUploads) { up in
                                HStack(spacing: 6) {
                                    Image(systemName: isImageMime(up.mimeType) ? "photo" : "doc")
                                    Text("\(up.filename) · \(formatBytes(up.bytes))")
                                        .lineLimit(1)
                                    Button(role: .destructive) {
                                        pendingUploads.removeAll { $0.id == up.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(activeSkin.leftPaneBackground.opacity(0.12))
                                .cornerRadius(6)
                            }
                            Button("Clear Attachments") { pendingUploads.removeAll() }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal)
                    }
                }
                terminalSection
            }
            .foregroundColor(activeSkin.userTextColor)
            .font(activeSkin.font)
            .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        guard let data = try? Data(contentsOf: url) else { continue }
                        let name = url.lastPathComponent
                        let mime = mimeType(for: url)
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? data.count
                        let up = PendingUpload(filename: name, data: data, mimeType: mime, bytes: bytes)
                        pendingUploads.append(up)
                    }
                case .failure:
                    break
                }
            }
            .fileImporter(isPresented: $composerShowImageImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        guard let data = try? Data(contentsOf: url) else { continue }
                        let name = url.lastPathComponent
                        let mime = mimeType(for: url)
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? data.count
                        let up = PendingUpload(filename: name, data: data, mimeType: mime, bytes: bytes)
                        composerPendingUploads.append(up)
                    }
                case .failure:
                    break
                }
            }

            if showSettings {
                Color.black.opacity(0.35).ignoresSafeArea()
                SettingsView(selectedSkin: $activeSkin, showSettings: $showSettings)
                    .environmentObject(vm)
                    .frame(width: 480, height: 520)
                    .background(activeSkin.leftPaneBackground)
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .applyExporting(document: $exportDocument,
                        isExporting: $isExporting,
                        pendingClearAfterExport: $pendingClearAfterExport,
                        onExported: { success in
                            if success, pendingClearAfterExport {
                                vm.clearHistory()
                            }
                            pendingClearAfterExport = false
                        },
                        defaultFilename: defaultTranscriptFilename(),
                        transcriptBuilder: { makeTranscriptText(from: vm.messages) })
        .applyExportAlerts(showExportChoiceAlert: $showExportChoiceAlert,
                           showFinalClearConfirm: $showFinalClearConfirm,
                           beginExport: {
                               exportDocument = TranscriptDocument(text: makeTranscriptText(from: vm.messages))
                               pendingClearAfterExport = true
                               isExporting = true
                           },
                           clearNow: { vm.clearHistory() },
                           hasAnyNonSystemContent: hasAnyNonSystemContent())
        .applyCommandConsentAlerts(showSendCommandConsent: $showSendCommandConsent,
                                   pendingCommand: $pendingCommand,
                                   sendCommandToChat: { cmd in
                                       Task { await vm.appendAndSendUserMessage("bash$ \(cmd)") }
                                   },
                                   showSendOutputConsent: $showSendOutputConsent,
                                   lastRanCommand: $lastRanCommand,
                                   lastCommandOutputToSend: $lastCommandOutputToSend,
                                   sendOutputToChat: { cmd, output in
                                       let contextualized = """
                                       I ran the following shell command:

                                       bash$ \(cmd)

                                       Here is the full output:

                                       \(output)

                                       Please analyze the output. If there are errors, explain the likely cause and suggest fixes. If it succeeded, summarize what happened and any next steps I might take.
                                       """
                                       Task { await vm.appendAndSendUserMessage(contextualized) }
                                   })
        .applyAPIKeyAlert(showAPIKeyPrompt: $showAPIKeyPrompt,
                          pendingAPIKey: $pendingAPIKey,
                          onSave: { key in vm.saveAPIKey(key) })
        .applySudoAlert(vm: vm,
                        sudoPassword: $sudoPassword)
        .applyComposerConsentAlerts(
            vm: vm,
            composerPendingCommand: $composerPendingCommand,
            composerShowSendCommandConsent: $composerShowSendCommandConsent,
            composerCommandConsentCompletion: $composerCommandConsentCompletion,
            composerPendingOutputCommand: $composerPendingOutputCommand,
            composerPendingOutput: $composerPendingOutput,
            composerShowSendOutputConsent: $composerShowSendOutputConsent,
            composerOutputConsentCompletion: $composerOutputConsentCompletion
        )
        .onChange(of: vm.messages.count) { _, _ in
            // Keep AI pane scrolled if needed (optional)
        }
        .onChange(of: vm.lastErrorMessage) { _, _ in
            composerErrorDismissed = false
        }
        .sheet(isPresented: $showComposerPreview) {
            VStack(spacing: 12) {
                Text(composerPreviewTitle).font(.headline)
                if let img = composerPreviewImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(minWidth: 300, minHeight: 200)
                } else {
                    Text("No Preview Available").foregroundColor(.secondary)
                }
                HStack { Button("Close") { showComposerPreview = false } }
            }
            .padding()
            .frame(minWidth: 480, minHeight: 360)
        }
        .onAppear {
            if !hasSeenOnboarding { showOnboardingOverlay = true }
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
            Button { withAnimation { showSettings = true } } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .help("Open Settings. Theme is available inside Settings.")
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
                Text("Composer").font(.headline).foregroundColor(activeSkin.aiTextColor)
                Button {
                    showOnboardingOverlay = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .help("Open quick start guide")
                Spacer()
                Toggle("Press Enter to send", isOn: $enterToSend)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .help("When on: Enter sends, Shift+Enter inserts a newline.\nWhen off: Enter inserts newline, ⌘↩ sends.")
                    .frame(maxWidth: 220)
                Button {
                    composerShowImageImporter = true
                } label: {
                    Label("Attach…", systemImage: "paperclip")
                }
                .disabled(vm.isSending)
                .help("Attach files or images to include with your prompt.")
                Button("Send →") {
                    let text = leftEditorText
                    Task {
                        // Intercept Bash: requests with NL→Bash flow
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bash:") {
                            let natural = String(text.dropFirst(5))
                            let uploads = composerPendingUploads.map { BashImageUpload(filename: $0.filename, data: $0.data, mimeType: $0.mimeType) }
                            await vm.composeAndRunBash(natural: natural, uploads: uploads)
                            await MainActor.run { composerPendingUploads.removeAll() }
                        } else {
                            await MainActor.run { composerErrorDismissed = false }
                            await MainActor.run { vm.inputText = text }
                            let uploads = composerPendingUploads.map { BashImageUpload(filename: $0.filename, data: $0.data, mimeType: $0.mimeType) }
                            if uploads.isEmpty {
                                await vm.sendCurrentInput()
                            } else {
                                await vm.sendCurrentInput(images: uploads)
                                await MainActor.run {
                                    let atts: [ChatImageAttachment] = uploads.enumerated().map { (idx, up) in
                                        let b64 = up.data.base64EncodedString()
                                        let bytes = up.data.count
                                        let mt = up.mimeType ?? "application/octet-stream"
                                        return ChatImageAttachment(filename: up.filename, bytes: bytes, mimeType: mt, dataBase64: b64)
                                    }
                                    vm.messages.append(ChatMessage(role: "user", content: text, attachments: atts))
                                    composerPendingUploads.removeAll()
                                }
                            }
                        }
                        await MainActor.run { leftEditorText = "" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isSending || leftEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !vm.canSend)
                .help("Send the current prompt. Shift+Enter inserts a newline when Enter-to-send is on.")
            }
            .padding([.top, .horizontal])

            if !composerPendingUploads.isEmpty && !visionCapableModels.contains(vm.selectedModel) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("The selected model may not accept images. Switch to a vision model?")
                        .font(.caption)
                    Spacer()
                    Button("Switch to gpt-4o-mini") { vm.selectedModel = "gpt-4o-mini" }
                    Button("Send anyway") { /* proceed without changing model */ }
                }
                .padding(8)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            if let err = vm.lastErrorMessage, !composerErrorDismissed {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundColor(.red)
                    Text(err).font(.caption)
                    Spacer()
                    Button("Dismiss") { composerErrorDismissed = true }
                }
                .padding(8)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            InterceptingTextEditor(
                text: $leftEditorText,
                isDisabled: vm.isSending || !vm.canSend,
                enterSends: enterToSend,
                onSend: {
                    let text = leftEditorText
                    Task {
                        // Intercept Bash: requests with NL→Bash flow
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bash:") {
                            let natural = String(text.dropFirst(5))
                            let uploads = composerPendingUploads.map { BashImageUpload(filename: $0.filename, data: $0.data, mimeType: $0.mimeType) }
                            await vm.composeAndRunBash(natural: natural, uploads: uploads)
                            await MainActor.run { composerPendingUploads.removeAll() }
                        } else {
                            await MainActor.run { composerErrorDismissed = false }
                            await MainActor.run { vm.inputText = text }
                            let uploads = composerPendingUploads.map { BashImageUpload(filename: $0.filename, data: $0.data, mimeType: $0.mimeType) }
                            if uploads.isEmpty {
                                await vm.sendCurrentInput()
                            } else {
                                await vm.sendCurrentInput(images: uploads)
                                await MainActor.run {
                                    let atts: [ChatImageAttachment] = uploads.enumerated().map { (idx, up) in
                                        let b64 = up.data.base64EncodedString()
                                        let bytes = up.data.count
                                        let mt = up.mimeType ?? "application/octet-stream"
                                        return ChatImageAttachment(filename: up.filename, bytes: bytes, mimeType: mt, dataBase64: b64)
                                    }
                                    vm.messages.append(ChatMessage(role: "user", content: text, attachments: atts))
                                    composerPendingUploads.removeAll()
                                }
                            }
                        }
                        await MainActor.run { leftEditorText = "" }
                    }
                }
            )
            .frame(minHeight: 140)
            .padding(8)
            .background(Color.clear)
            .foregroundColor(activeSkin.aiTextColor)

            if !composerPendingUploads.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        ForEach(composerPendingUploads) { up in
                            HStack(spacing: 6) {
                                Image(systemName: isImageMime(up.mimeType) ? "photo" : "doc")
                                Button(action: {
                                    if let nsimg = NSImage(data: up.data) {
                                        composerPreviewImage = nsimg
                                        composerPreviewTitle = up.filename
                                        showComposerPreview = true
                                    }
                                }) {
                                    Text("\(up.filename) · \(formatBytes(up.bytes))")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) {
                                    composerPendingUploads.removeAll { $0.id == up.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(activeSkin.leftPaneBackground.opacity(0.12))
                            .cornerRadius(6)
                        }
                        Button("Clear Attachments") { composerPendingUploads.removeAll() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal)
                }
            }

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
                Text("Results").font(.headline).foregroundColor(activeSkin.aiTextColor)
                Spacer()
                Toggle(isOn: $pinnedToBottom) {
                    Image(systemName: pinnedToBottom ? "pin.fill" : "pin")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .help(pinnedToBottom ? "Auto-scroll pinned to bottom" : "Auto-scroll paused")
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
                .help("Save the conversation and clear the Results.")
            }
            .padding([.horizontal, .top])

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.messages) { msg in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(msg.role.capitalized).font(.caption).foregroundColor(.secondary)
                                    Group {
                                        if expandedMessageIDs.contains(msg.id) {
                                            Text(msg.content)
                                                .font(.system(.body, design: .monospaced))
                                                .foregroundColor(msg.role == "assistant" ? activeSkin.aiTextColor : activeSkin.userTextColor)
                                                .textSelection(.enabled)
                                                .padding(8)
                                            Button("Show less") { expandedMessageIDs.remove(msg.id) }
                                                .font(.caption)
                                        } else {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(msg.content)
                                                    .font(.system(.body, design: .monospaced))
                                                    .foregroundColor(msg.role == "assistant" ? activeSkin.aiTextColor : activeSkin.userTextColor)
                                                    .textSelection(.enabled)
                                                    .lineLimit(resultsCollapsedLineLimit)
                                                    .padding(8)
                                                if msg.content.split(separator: "\n").count > resultsCollapsedLineLimit || msg.content.count > 1500 {
                                                    Button("Show more") { expandedMessageIDs.insert(msg.id) }
                                                        .font(.caption)
                                                }
                                            }
                                        }
                                    }
                                    if let atts = msg.attachments, !atts.isEmpty {
                                        if msg.role == "user" {
                                            Text("Attachments (sent by you)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        ScrollView(.horizontal, showsIndicators: true) {
                                            HStack(spacing: 12) {
                                                ForEach(atts) { att in
                                                    VStack(spacing: 6) {
                                                        if let data = Data(base64Encoded: att.dataBase64), let nsImage = NSImage(data: data) {
                                                            Image(nsImage: nsImage)
                                                                .resizable()
                                                                .interpolation(.high)
                                                                .antialiased(true)
                                                                .aspectRatio(contentMode: .fit)
                                                                .frame(width: 180, height: 120)
                                                                .background(Color.black.opacity(0.05))
                                                                .cornerRadius(8)
                                                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                                                        } else {
                                                            ZStack {
                                                                Rectangle().fill(Color.gray.opacity(0.15))
                                                                VStack(spacing: 6) {
                                                                    Image(systemName: "photo")
                                                                    Text(att.filename).font(.caption2).lineLimit(2)
                                                                }.foregroundColor(.secondary)
                                                            }
                                                            .frame(width: 180, height: 120)
                                                            .cornerRadius(8)
                                                        }
                                                        Text(att.filename)
                                                            .font(.caption2)
                                                            .lineLimit(1)
                                                        Text("\(att.mimeType) • \(formatBytes(att.bytes))")
                                                            .font(.caption2)
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                            }
                                        }
                                    }
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
            Text("Quick Command")
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
            .help(vm.canSend ? "Execute the shell command locally." : "Blocked to prevent exceeding rate limit.")
        }
        .padding()
        .background(activeSkin.leftPaneBackground.opacity(0.06))
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Terminal Output").font(.headline).foregroundColor(activeSkin.aiTextColor)
                Spacer()
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(terminalEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("bash$ \(entry.command)")
                                    .font(.system(.body, design: .monospaced)).bold()
                                Text("• \(timeString(entry.startedAt))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let code = entry.exitCode {
                                    Image(systemName: code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundColor(code == 0 ? .green : .orange)
                                    Text("exit \(code)")
                                        .font(.caption)
                                        .foregroundColor(code == 0 ? .green : .orange)
                                    Button("Summarize") {
                                        let output = entry.chunks.map { $0.text }.joined(separator: "")
                                        let contextualized = """
                                        I ran the following shell command:

                                        bash$ \(entry.command)

                                        Here is the full output:

                                        \(output)

                                        Please summarize the results. If there are errors, identify likely causes and actionable fixes. If it succeeded, explain what happened and suggest next steps.
                                        """
                                        Task { await vm.appendAndSendUserMessage(contextualized) }
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Send this output to ChatGPT for a summary.")
                                } else {
                                    ProgressView().controlSize(.small)
                                    Text("running…")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            ForEach(entry.chunks.indices, id: \.self) { idx in
                                let c = entry.chunks[idx]
                                Text(c.text)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(c.stream == .stderr ? .red : activeSkin.aiTextColor)
                            }
                            if !entry.outputImages.isEmpty {
                                Divider().padding(.vertical, 4)
                                Text("Generated Images (\(entry.outputImages.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ScrollView(.horizontal, showsIndicators: true) {
                                    HStack(spacing: 12) {
                                        ForEach(entry.outputImages) { img in
                                            VStack(spacing: 6) {
                                                GeneratedImageView(url: img.url)
                                                    .frame(width: 180, height: 120)
                                                    .background(Color.black.opacity(0.05))
                                                    .cornerRadius(8)
                                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                                                Text(img.filename)
                                                    .font(.caption2)
                                                    .lineLimit(1)
                                                    .frame(maxWidth: 180)
                                                Text("\(img.mimeType) • \(formatBytes(img.bytes))")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                HStack(spacing: 8) {
                                                    Button("Open") { NSWorkspace.shared.open(img.url) }
                                                    Button("Reveal") { revealInFinder(img.url) }
                                                    Button("Save As…") { saveFile(from: img.url, suggestedName: img.filename) }
                                                }
                                                .buttonStyle(.borderless)
                                            }
                                        }
                                    }
                                }
                            }
                            if !entry.outputFiles.isEmpty {
                                Divider().padding(.vertical, 4)
                                Text("Generated Files (\(entry.outputFiles.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ScrollView(.horizontal, showsIndicators: true) {
                                    HStack(spacing: 12) {
                                        ForEach(entry.outputFiles) { f in
                                            VStack(spacing: 6) {
                                                HStack(spacing: 8) {
                                                    Image(systemName: isLikelyImage(ext: f.url.pathExtension) ? "photo" : "doc")
                                                    Text(f.filename).font(.caption2).lineLimit(2)
                                                }
                                                Text("\(f.mimeType) • \(formatBytes(f.bytes))")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                HStack(spacing: 8) {
                                                    Button("Open") { NSWorkspace.shared.open(f.url) }
                                                    Button("Reveal") { revealInFinder(f.url) }
                                                    Button("Save As…") { saveFile(from: f.url, suggestedName: f.filename) }
                                                }
                                                .buttonStyle(.borderless)
                                            }
                                            .frame(width: 200)
                                            .padding(8)
                                            .background(activeSkin.leftPaneBackground.opacity(0.08))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
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

    // MARK: - Quick Prompt Command Flow (using BashQueryExecutor with image IO)

    private func runCommandFlow(_ command: String, uploads: [PendingUpload]? = nil) {
        guard vm.canSend else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Ask consent to send the command to ChatGPT
        pendingCommand = trimmed
        showSendCommandConsent = true

        // Create a terminal entry placeholder
        let entry = TerminalEntry(command: trimmed)
        terminalEntries.append(entry)
        let index = terminalEntries.count - 1

        lastRanCommand = trimmed

        Task(priority: .userInitiated) {
            let source = uploads ?? pendingUploads
            let bashUploads = source.map { BashImageUpload(filename: $0.filename, data: $0.data, mimeType: $0.mimeType) }

            let result = await BashQueryExecutor.execute("bash: \(trimmed)", timeout: 120, inputImages: bashUploads)

            await MainActor.run {
                // Map stdout/stderr (non-streaming)
                if !result.stdout.isEmpty {
                    terminalEntries[index].chunks.append(.init(stream: .stdout, text: result.stdout))
                }
                if !result.stderr.isEmpty {
                    terminalEntries[index].chunks.append(.init(stream: .stderr, text: result.stderr))
                }
                terminalEntries[index].exitCode = result.exitCode
                terminalEntries[index].endedAt = Date()

                // Attach generated images for preview/download
                terminalEntries[index].outputImages = result.outputImages.map { gi in
                    TerminalEntry.GeneratedImage(url: gi.fileURL, filename: gi.filename, mimeType: gi.mimeType, bytes: gi.bytes)
                }
                terminalEntries[index].outputFiles = result.outputFiles.map { gf in
                    TerminalEntry.GeneratedFile(url: gf.fileURL, filename: gf.filename, mimeType: gf.mimeType, bytes: gf.bytes)
                }

                // Prompt to send output content to chat analysis
                lastCommandOutputToSend = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
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

// MARK: - View Modifiers to split heavy .alert and exporter chains

private extension View {
    func applyExporting(document: Binding<TranscriptDocument>,
                        isExporting: Binding<Bool>,
                        pendingClearAfterExport: Binding<Bool>,
                        onExported: @escaping (Bool) -> Void,
                        defaultFilename: String,
                        transcriptBuilder: @escaping () -> String) -> some View {
        self.fileExporter(
            isPresented: isExporting,
            document: document.wrappedValue,
            contentType: .plainText,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success:
                onExported(true)
            case .failure:
                onExported(false)
            }
        }
    }

    func applyExportAlerts(showExportChoiceAlert: Binding<Bool>,
                           showFinalClearConfirm: Binding<Bool>,
                           beginExport: @escaping () -> Void,
                           clearNow: @escaping () -> Void,
                           hasAnyNonSystemContent: Bool) -> some View {
        self
            .alert("Export before clearing?", isPresented: showExportChoiceAlert) {
                Button("Export…") { beginExport() }
                Button("Clear without Export") { showFinalClearConfirm.wrappedValue = true }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You can save the current AI conversation as a .txt file before clearing.")
            }
            .alert("Clear AI Response?", isPresented: showFinalClearConfirm) {
                Button("Clear", role: .destructive) { clearNow() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to clear the AI response section? This action cannot be undone and the data isn't presently backed up anywhere.")
            }
    }

    func applyCommandConsentAlerts(showSendCommandConsent: Binding<Bool>,
                                   pendingCommand: Binding<String>,
                                   sendCommandToChat: @escaping (String) -> Void,
                                   showSendOutputConsent: Binding<Bool>,
                                   lastRanCommand: Binding<String>,
                                   lastCommandOutputToSend: Binding<String>,
                                   sendOutputToChat: @escaping (String, String) -> Void) -> some View {
        self
            .alert("Send command to ChatGPT?", isPresented: showSendCommandConsent) {
                Button("Send to ChatGPT") { sendCommandToChat(pendingCommand.wrappedValue) }
                Button("Don’t Send", role: .cancel) { }
            } message: {
                Text("Allow sending this command for analysis?\n\n\(pendingCommand.wrappedValue)")
            }
            .alert("Send output to ChatGPT?", isPresented: showSendOutputConsent) {
                Button("Send Output") {
                    sendOutputToChat(lastRanCommand.wrappedValue, lastCommandOutputToSend.wrappedValue)
                }
                Button("Don’t Send", role: .cancel) { }
            } message: {
                Text("Allow sending the command output for analysis?")
            }
    }

    func applyAPIKeyAlert(showAPIKeyPrompt: Binding<Bool>,
                          pendingAPIKey: Binding<String>,
                          onSave: @escaping (String) -> Void) -> some View {
        self.alert("Enter OpenAI API Key", isPresented: showAPIKeyPrompt) {
            TextField("sk-...", text: pendingAPIKey)
            Button("Save") {
                let key = pendingAPIKey.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    onSave(key)
                }
                pendingAPIKey.wrappedValue = ""
            }
            Button("Cancel", role: .cancel) {
                pendingAPIKey.wrappedValue = ""
            }
        } message: {
            Text("Your key will be stored securely in the Keychain.")
        }
    }

    func applySudoAlert(vm: ChatViewModel,
                        sudoPassword: Binding<String>) -> some View {
        self.alert("Administrator Password Required", isPresented: Binding(
            get: { vm.needsSudoPasswordPrompt },
            set: { vm.needsSudoPasswordPrompt = $0 }
        )) {
            SecureField("Password", text: sudoPassword)
            Button("Run") {
                let pwd = sudoPassword.wrappedValue
                sudoPassword.wrappedValue = ""
                vm.provideSudoPassword(pwd)
            }
            Button("Cancel", role: .cancel) {
                sudoPassword.wrappedValue = ""
                vm.provideSudoPassword(nil)
            }
        } message: {
            Text(vm.pendingSudoRequestDescription.isEmpty ? "Enter your password to run this command with sudo." : vm.pendingSudoRequestDescription)
        }
    }

    func applyComposerConsentAlerts(
        vm: ChatViewModel,
        composerPendingCommand: Binding<String>,
        composerShowSendCommandConsent: Binding<Bool>,
        composerCommandConsentCompletion: Binding<((Bool) -> Void)?>,
        composerPendingOutputCommand: Binding<String>,
        composerPendingOutput: Binding<String>,
        composerShowSendOutputConsent: Binding<Bool>,
        composerOutputConsentCompletion: Binding<((Bool) -> Void)?>
    ) -> some View {
        self
            .onAppear {
                vm.requestComposerSendCommandConsent = { command, completion in
                    if let old = composerCommandConsentCompletion.wrappedValue {
                        old(false)
                    }
                    composerPendingCommand.wrappedValue = command
                    composerCommandConsentCompletion.wrappedValue = completion
                    composerShowSendCommandConsent.wrappedValue = true
                }
                vm.requestComposerSendOutputConsent = { command, output, completion in
                    if let old = composerOutputConsentCompletion.wrappedValue {
                        old(false)
                    }
                    composerPendingOutputCommand.wrappedValue = command
                    composerPendingOutput.wrappedValue = output
                    composerOutputConsentCompletion.wrappedValue = completion
                    composerShowSendOutputConsent.wrappedValue = true
                }
            }
            .onDisappear {
                if let pending = composerCommandConsentCompletion.wrappedValue {
                    pending(false)
                    composerCommandConsentCompletion.wrappedValue = nil
                }
                if let pending = composerOutputConsentCompletion.wrappedValue {
                    pending(false)
                    composerOutputConsentCompletion.wrappedValue = nil
                }
                vm.requestComposerSendCommandConsent = nil
                vm.requestComposerSendOutputConsent = nil
            }
            .alert("Send command to ChatGPT?", isPresented: composerShowSendCommandConsent) {
                Button("Send to ChatGPT") {
                    composerCommandConsentCompletion.wrappedValue?(true)
                    composerCommandConsentCompletion.wrappedValue = nil
                    composerPendingCommand.wrappedValue = ""
                }
                Button("Don’t Send", role: .cancel) {
                    composerCommandConsentCompletion.wrappedValue?(false)
                    composerCommandConsentCompletion.wrappedValue = nil
                    composerPendingCommand.wrappedValue = ""
                }
            } message: {
                Text("Allow sending this command for analysis?\n\n\(composerPendingCommand.wrappedValue)")
            }
            .alert("Send output to ChatGPT?", isPresented: composerShowSendOutputConsent) {
                Button("Send Output") {
                    composerOutputConsentCompletion.wrappedValue?(true)
                    composerOutputConsentCompletion.wrappedValue = nil
                    composerPendingOutput.wrappedValue = ""
                    composerPendingOutputCommand.wrappedValue = ""
                }
                Button("Don’t Send", role: .cancel) {
                    composerOutputConsentCompletion.wrappedValue?(false)
                    composerOutputConsentCompletion.wrappedValue = nil
                    composerPendingOutput.wrappedValue = ""
                    composerPendingOutputCommand.wrappedValue = ""
                }
            } message: {
                Text("Allow sending the command output for analysis?\n\nbash$ \(composerPendingOutputCommand.wrappedValue)\n\n(Output truncated in UI display if very long.)")
            }
    }
}

// Terminal models in-view for simplicity
private struct TerminalEntry: Identifiable {
    struct Chunk {
        enum Stream { case stdout, stderr }
        let stream: Stream
        let text: String
    }

    struct GeneratedImage: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        let mimeType: String
        let bytes: Int
    }
    
    struct GeneratedFile: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        let mimeType: String
        let bytes: Int
    }

    let id = UUID()
    let command: String
    var chunks: [Chunk] = []
    var exitCode: Int32? = nil
    var startedAt: Date = Date()
    var endedAt: Date? = nil
    var outputImages: [GeneratedImage] = []
    var outputFiles: [GeneratedFile] = []

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

private struct GeneratedImageView: View {
    let url: URL
    var body: some View {
        if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.15))
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text(url.lastPathComponent).font(.caption2).lineLimit(2)
                }.foregroundColor(.secondary)
            }
        }
    }
}

