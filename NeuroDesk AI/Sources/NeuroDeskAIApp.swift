/// NeuroDeskAIApp.swift
/// Root application entry and primary UI composition.
/// This file wires together:
/// - Chat UI (messages + composer)
/// - Bash shell helper panel
/// - Attachments (images/audio/video) including webcam capture
/// - Vision-capable send path (routes attachments to model)
/// Legacy kept where it adds functionality; redundant legacy removed.

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation
import CoreMedia

/// App entry point. Provides the shared ChatViewModel as an environment object.
@main
struct NeuroDeskAIApp: App {
    @StateObject private var chat = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(chat)
        }
    }
}

/// RootView composes the split UI and orchestrates state for settings, skin, attachments, and capture.
struct RootView: View {
    @EnvironmentObject var chat: ChatViewModel
    @State private var showSettings: Bool = false
    @State private var selectedSkin: ChatSkin = .terminalSplit
    @State private var enterSends: Bool = true
    @State private var showBashShell: Bool = true  // Toggles the auxiliary Bash shell composer panel
    @State private var uploads: [BashImageUpload] = []  // Pending attachments to include in next send / bash run
    @State private var showCaptureSheet: Bool = false  // Presents webcam capture sheet (photo/video)
    @State private var showPostCaptureAction: Bool = false
    @State private var lastCapturedUploads: [BashImageUpload] = []
    @State private var alertMessage: String? = nil

    var body: some View {
        let background = selectedSkin.background
        let leftPaneBG = selectedSkin.leftPaneBackground
        let rightPaneBG = selectedSkin.rightPaneBackground
        let accent = selectedSkin.accentColor

        return VStack(spacing: 0) {
            // Header / global controls: settings, bash toggle, and attachment/capture actions
            HStack(spacing: 12) {
                HeaderView(title: "NeuroDesk AI",
                           background: background.opacity(0.6),
                           accent: accent,
                           showSettings: $showSettings,
                           onExport: { exportTranscript() },
                           onClearAll: { chat.clearHistory() })
                // Toggle Bash panel (kept for power users; legacy-friendly)
                Toggle(isOn: $showBashShell) {
                    Text("Bash shell")
                }
                .toggleStyle(.switch)
                .help("Toggle Bash composer section")
                // Pick image files from disk (UTType.image)
                Button {
                    presentAttachmentPicker()
                } label: {
                    Label("Add Attachment", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .help("Attach images for vision models or bash commands")
                // Launch webcam capture (photo/video) via AVFoundation sheet
                Button {
                    showCaptureSheet = true
                } label: {
                    Label("Capture Photo/Video", systemImage: "camera")
                }
                .buttonStyle(.bordered)
                .help("Use webcam to capture photo or video")
                // Pick audio/video files from disk (UTType.audio/movie/video)
                Button {
                    presentMediaPicker()
                } label: {
                    Label("Add Audio/Video", systemImage: "waveform")
                }
                .buttonStyle(.bordered)
                .help("Pick audio or video files from disk")

                if !uploads.isEmpty {
                    Text("\(uploads.count) attachment\(uploads.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Split panes: left = messages, right = composer (+ optional Bash panel)
            HStack(spacing: 0) {
                MessagesList(messages: chat.messages,
                             skin: selectedSkin)
                    .frame(minWidth: 360)
                    .background(leftPaneBG)

                Divider()

                // Main composer. Send button routes to vision-capable path when attachments present.
                ComposerView(inputText: $chat.inputText,
                             isSending: chat.isSending,
                             enterSends: $enterSends,
                             skin: selectedSkin,
                             onSend: {
                                 Task {
                                     // Detect vision-capable models (4o / 4.1 families). Keep string check local to avoid coupling.
                                     let model = chat.selectedModel.lowercased()
                                     // If model supports vision and we have attachments, send them; otherwise plain text.
                                     let isVision = model.contains("4o") || model.contains("4.1")
                                     if isVision && !uploads.isEmpty {
                                         // Clear uploads after successful handoff to avoid re-sending.
                                         let toSend = uploads
                                         uploads.removeAll()
                                         await chat.sendCurrentInput(images: toSend)
                                     } else {
                                         await chat.sendCurrentInput()
                                     }
                                 }
                             },
                             uploads: uploads,
                             onRemoveUploadAt: { idx in uploads.remove(at: idx) }
                             ,
                             onAddUploads: { items in uploads.append(contentsOf: items) },
                             onClearAllUploads: { uploads.removeAll() }
                )
                .padding(12)
                .background(rightPaneBG)

                // Optional Bash helper panel: composes NL→bash, executes with consent, and posts results
                if showBashShell {
                    Divider()
                    BashShellSection(skin: selectedSkin,
                                     inputText: $chat.inputText,
                                     isSending: chat.isSending,
                                     uploads: $uploads,
                                     onRun: { Task { await chat.composeAndRunBash(natural: chat.inputText, uploads: uploads) } })
                        .frame(minWidth: 300)
                        .background(rightPaneBG)
                        .padding(12)
                }
            }
            .background(background)
        }
        .tint(accent)
        // Settings sheet uses EnvironmentObject vm; no direct vm parameter to avoid double-injection.
        .sheet(isPresented: $showSettings) {
            SettingsView(selectedSkin: $selectedSkin, showSettings: $showSettings)
                .environmentObject(chat)
        }
        .sheet(isPresented: $showCaptureSheet) {
            MediaCaptureView { items in
                // items are (filename, data, mime)
                let new = items.map { BashImageUpload(filename: $0.0, data: $0.1, mimeType: $0.2) }
                uploads.append(contentsOf: new)
                lastCapturedUploads = new
                showCaptureSheet = false
                showPostCaptureAction = true
            } onCancel: {
                showCaptureSheet = false
            }
        }
        .confirmationDialog("Use captured media", isPresented: $showPostCaptureAction, titleVisibility: .visible) {
            Button("Send to Chat") {
                Task {
                    let model = chat.selectedModel.lowercased()
                    let isVision = model.contains("4o") || model.contains("4.1")
                    guard isVision else {
                        alertMessage = "The selected model isn't vision-capable. Switch to a vision model (e.g., GPT-4o / 4.1) to send images."
                        return
                    }

                    // Prepare uploads, converting any videos into a still JPEG if needed
                    let prepared = await prepareUploadsForVision(lastCapturedUploads)
                    await chat.sendCurrentInput(images: prepared)
                    lastCapturedUploads.removeAll()
                }
            }
            Button("Run in Bash") {
                Task {
                    let toUse = lastCapturedUploads
                    await chat.composeAndRunBash(natural: chat.inputText, uploads: toUse)
                    lastCapturedUploads.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {
                lastCapturedUploads.removeAll()
            }
        }
        .alert(item: Binding(get: {
            alertMessage.map { IdentifiedAlert(message: $0) }
        }, set: { newValue in
            alertMessage = newValue?.message
        })) { identified in
            Alert(title: Text("Notice"), message: Text(identified.message), dismissButton: .default(Text("OK")))
        }
        .frame(minWidth: 900, minHeight: 520)
    }
}

private extension RootView {
    func exportTranscript() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = "transcript.txt"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let lines = chat.messages.map { m in
                let role = m.role.capitalized
                return "[\(role)] \(m.content)"
            }.joined(separator: "\n\n")
            do {
                try lines.data(using: .utf8)?.write(to: url)
            } catch {
                print("Failed to export transcript: \(error)")
            }
        }
        #endif
    }
}

private struct IdentifiedAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct HeaderView: View {
    let title: String
    let background: Color
    let accent: Color
    @Binding var showSettings: Bool
    var onExport: () -> Void
    var onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.headline)
            Spacer()
            Button { onExport() } label: {
                Image(systemName: "square.and.arrow.up").imageScale(.medium)
            }
            .help("Export transcript")

            Button(role: .destructive) { onClearAll() } label: {
                Image(systemName: "trash").imageScale(.medium)
            }
            .help("Clear all messages")

            Button { showSettings = true } label: {
                Image(systemName: "gearshape").imageScale(.medium)
            }
            .help("Settings")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(background)
    }
}

private struct MessagesList: View {
    let messages: [ChatMessage]
    let skin: ChatSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Virtualized list of chat messages; lightweight row view to keep type-checker fast.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { msg in
                        MessageRow(message: msg, skin: skin)
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let skin: ChatSkin

    var body: some View {
        // Style varies by role; colors/fonts sourced from selected skin.
        let isUser = message.role == "user"
        let bg = isUser ? skin.leftPaneBackground.opacity(0.6) : skin.rightPaneBackground.opacity(0.6)
        let stroke = skin.accentColor.opacity(0.08)
        let textColor = isUser ? skin.userTextColor : skin.aiTextColor

        return VStack(alignment: .leading, spacing: 4) {
            Text(message.role.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.content)
                .font(skin.font)
                .foregroundColor(textColor)
                .textSelection(.enabled)

            if let atts = message.attachments, !atts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(atts) { att in
                            AttachmentChip(filename: att.filename, data: Data(base64Encoded: att.dataBase64), mimeType: att.mimeType) {
                                // no-op; historical chips are read-only
                            }
                        }
                    }
                }
                .frame(height: 40)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(stroke, lineWidth: 1)
        )
    }
}

/// Main text composer; now shows pending attachments for vision-capable sends.
private struct ComposerView: View {
    @Binding var inputText: String
    let isSending: Bool
    @Binding var enterSends: Bool
    let skin: ChatSkin
    let onSend: () -> Void
    let uploads: [BashImageUpload]
    let onRemoveUploadAt: (Int) -> Void
    let onAddUploads: ([BashImageUpload]) -> Void
    let onClearAllUploads: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compose").font(.subheadline).foregroundStyle(.secondary)

            // Text editor with Return/Shift-Return handling (legacy behavior preserved).
            InterceptingTextEditor(text: $inputText, isDisabled: isSending, enterSends: enterSends) {
                onSend()
            }
            .frame(minHeight: 140)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(skin.rightPaneBackground.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(skin.accentColor.opacity(0.15), lineWidth: 1)
            )

            // Attachments strip with drag-and-drop and Clear All
            Group {
                if !uploads.isEmpty {
                    HStack(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(uploads.enumerated()), id: \.offset) { pair in
                                    let idx = pair.offset
                                    let up = pair.element
                                    AttachmentChip(filename: up.filename, data: up.data, mimeType: up.mimeType) {
                                        onRemoveUploadAt(idx)
                                    }
                                }
                            }
                        }
                        .frame(height: 40)

                        Button("Clear All") { onClearAllUploads() }
                            .buttonStyle(.bordered)
                            .help("Remove all attachments")
                    }
                }
            }
            .onDrop(of: [UTType.image, UTType.audio, UTType.movie, UTType.video], isTargeted: nil) { providers in
                var pending: [BashImageUpload] = []
                let group = DispatchGroup()

                func loadData(from provider: NSItemProvider, type: UTType, suggestedName: String?, completion: @escaping (Data?, String?) -> Void) {
                    if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                        group.enter()
                        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                            defer { group.leave() }
                            if let url = item as? URL, let data = try? Data(contentsOf: url) {
                                completion(data, type.preferredMIMEType)
                            } else if let data = item as? Data {
                                completion(data, type.preferredMIMEType)
                            } else if let pasteboard = item as? NSPasteboardWriting,
                                      let str = pasteboard.pasteboardPropertyList(forType: .fileURL) as? String,
                                      let url = URL(string: str) {
                                        if let data = try? Data(contentsOf: url) {
                                            completion(data, type.preferredMIMEType)
                                        } else {
                                            completion(nil, nil)
                                        }
                            } else {
                                completion(nil, nil)
                            }
                        }
                    } else {
                        completion(nil, nil)
                    }
                }

                for provider in providers {
                    let suggestedName = provider.suggestedName ?? "drop-\(UUID().uuidString)"
                    // Try in order: image, movie/video, audio
                    loadData(from: provider, type: .image, suggestedName: suggestedName) { data, mime in
                        if let data = data {
                            let upload = BashImageUpload(filename: suggestedName, data: data, mimeType: mime ?? "image/*")
                            pending.append(upload)
                            return
                        }
                        loadData(from: provider, type: .movie, suggestedName: suggestedName) { data, mime in
                            if let data = data {
                                let upload = BashImageUpload(filename: suggestedName, data: data, mimeType: mime ?? "video/*")
                                pending.append(upload)
                                return
                            }
                            loadData(from: provider, type: .video, suggestedName: suggestedName) { data, mime in
                                if let data = data {
                                    let upload = BashImageUpload(filename: suggestedName, data: data, mimeType: mime ?? "video/*")
                                    pending.append(upload)
                                    return
                                }
                                loadData(from: provider, type: .audio, suggestedName: suggestedName) { data, mime in
                                    if let data = data {
                                        let upload = BashImageUpload(filename: suggestedName, data: data, mimeType: mime ?? "audio/*")
                                        pending.append(upload)
                                    }
                                }
                            }
                        }
                    }
                }

                group.notify(queue: .main) {
                    if !pending.isEmpty { onAddUploads(pending) }
                }
                return true
            }

            HStack(spacing: 12) {
                Button(action: onSend) {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("Send")
                    }
                }
                .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Toggle(isOn: $enterSends) { Text("Enter sends") }
                    .toggleStyle(.switch)

                if isSending { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }
}

private struct BashShellSection: View {
    let skin: ChatSkin
    @Binding var inputText: String
    let isSending: Bool
    @Binding var uploads: [BashImageUpload]
    let onRun: () -> Void

    @State private var bashCommand: String = ""
    @EnvironmentObject var chat: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bash Shell").font(.subheadline).foregroundStyle(.secondary)
            Text("Describe what you want to do. I will synthesize a safe command, ask for consent, run it, and post results.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Type bash command or description…", text: $bashCommand)
                .textFieldStyle(.roundedBorder)
                .disabled(isSending)

            // Run synthesized bash with current input and attachments; chips allow removing uploads.
            HStack(spacing: 8) {
                Button {
                    if !bashCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        inputText = bashCommand
                    }
                    onRun()
                } label: {
                    Label("Run Bash", systemImage: "terminal.fill")
                }
                .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Clear Output") {
                    if let lastIdx = chat.messages.lastIndex(where: { $0.role == "assistant" }) {
                        chat.messages.remove(at: lastIdx)
                    }
                }
                .buttonStyle(.bordered)
                .help("Remove the latest assistant output")

                if !uploads.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(uploads.enumerated()), id: \.offset) { pair in
                                let idx = pair.offset
                                let up = pair.element
                                AttachmentChip(filename: up.filename, data: nil, mimeType: up.mimeType) {
                                    uploads.remove(at: idx)
                                }
                            }
                        }
                    }
                    .frame(height: 28)
                }
            }
            if let lastAssistant = chat.messages.last(where: { $0.role == "assistant" }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Bash Output").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(lastAssistant.content)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 140)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(skin.rightPaneBackground.opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(skin.accentColor.opacity(0.15), lineWidth: 1))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(skin.rightPaneBackground.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(skin.accentColor.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct AttachmentChip: View {
    let filename: String
    let data: Data?
    let mimeType: String?
    let onRemove: () -> Void

    @State private var thumbnail: NSImage? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: iconName)
            }
            Text(filename)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .onAppear(perform: makeThumbnailIfNeeded)
    }

    private var iconName: String {
        if let mt = mimeType {
            if mt.hasPrefix("image/") { return "photo" }
            if mt.hasPrefix("video/") { return "video" }
            if mt.hasPrefix("audio/") { return "waveform" }
        }
        return "paperclip"
    }

    private func makeThumbnailIfNeeded() {
        guard thumbnail == nil else { return }
        guard let data = data else { return }
        if let img = NSImage(data: data) {
            // Downscale to a small thumbnail
            let size = NSSize(width: 40, height: 40)
            let thumb = NSImage(size: size)
            thumb.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: img.size), operation: .copy, fraction: 1.0)
            thumb.unlockFocus()
            thumbnail = thumb
        }
    }
}

private extension UTType {
    var preferredMIMEType: String? {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .gif: return "image/gif"
        case .tiff: return "image/tiff"
        case .bmp: return "image/bmp"
        case .heic: return "image/heic"
        case .heif: return "image/heif"
        case .svg: return "image/svg+xml"
        case .movie, .video: return "video/quicktime"
        case .mpeg4Movie: return "video/mp4"
        case .audio: return "audio/*"
        default:
            if self.conforms(to: .image) { return "image/*" }
            if self.conforms(to: .video) { return "video/*" }
            if self.conforms(to: .audio) { return "audio/*" }
            return nil
        }
    }
}

// MARK: - Attachments & Media Pickers (macOS)
import AppKit
extension RootView {
    func presentAttachmentPicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Images only; saved as BashImageUpload for both vision chat and bash env exposure.
        panel.allowedContentTypes = [.image, .png, .jpeg, .gif, .tiff, .bmp, .heic, .heif, .svg]
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            var newUploads: [BashImageUpload] = []
            for url in urls {
                if let data = try? Data(contentsOf: url) {
                    let ext = url.pathExtension.lowercased()
                    let mime: String? = {
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
                    }()
                    let upload = BashImageUpload(filename: url.lastPathComponent, data: data, mimeType: mime)
                    newUploads.append(upload)
                }
            }
            if !newUploads.isEmpty {
                uploads.append(contentsOf: newUploads)
            }
        }
        #endif
    }

    func presentMediaPicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Audio/Video selection; allows attaching for vision models or bash workflows.
        panel.allowedContentTypes = [UTType.audio, UTType.movie, UTType.video, UTType.mpeg4Movie]
        panel.begin { response in
            guard response == .OK else { return }
            var newUploads: [BashImageUpload] = []
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    let mime: String? = mimeFor(url: url)
                    let upload = BashImageUpload(filename: url.lastPathComponent, data: data, mimeType: mime)
                    newUploads.append(upload)
                }
            }
            if !newUploads.isEmpty { uploads.append(contentsOf: newUploads) }
        }
        #endif
    }

    /// Best-effort MIME by file extension for audio/video; images handled in image picker.
    private func mimeFor(url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "aiff", "aif": return "audio/aiff"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        default: return nil
        }
    }

    /// Convert any video uploads into a representative still JPEG image; pass through other types unchanged.
    func prepareUploadsForVision(_ uploads: [BashImageUpload]) async -> [BashImageUpload] {
        var result: [BashImageUpload] = []
        for up in uploads {
            if let mime = up.mimeType, mime.hasPrefix("video/") {
                if let still = await extractStillJPEG(from: up) {
                    result.append(still)
                } else {
                    // If we fail to extract, just skip the video rather than sending unsupported media
                }
            } else {
                result.append(up)
            }
        }
        return result
    }

    /// Extract a single JPEG frame from a video BashImageUpload using AVAssetImageGenerator.
    private func extractStillJPEG(from upload: BashImageUpload) async -> BashImageUpload? {
        let data = upload.data
        // Write to a temporary file so AVAsset can read it
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("thumb-\(UUID().uuidString).mov")
        do {
            try data.write(to: tmpURL)
        } catch {
            return nil
        }
        let asset = AVURLAsset(url: tmpURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cgImage: CGImage
        do {
            cgImage = try await withCheckedThrowingContinuation { cont in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                    if let img = image, result == .succeeded {
                        cont.resume(returning: img)
                    } else {
                        cont.resume(throwing: error ?? NSError(domain: "thumb", code: -1))
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
        // Encode JPEG
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
        try? FileManager.default.removeItem(at: tmpURL)
        let name = (upload.filename as NSString).deletingPathExtension + "-frame.jpg"
        return BashImageUpload(filename: name, data: jpeg, mimeType: "image/jpeg")
    }
}

import AVFoundation

// MARK: - Webcam Capture (AVFoundation)
/// Minimal capture UI: preview, capture photo, record/stop video.
/// On completion, returns in-memory items mapped to BashImageUpload in RootView.
@MainActor
private struct MediaCaptureView: View {
    var onComplete: ([(String, Data, String?)]) -> Void
    var onCancel: () -> Void

    @State private var session = AVCaptureSession()
    @State private var photoOutput = AVCapturePhotoOutput()
    @State private var movieOutput = AVCaptureMovieFileOutput()
    @State private var isRecording = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Webcam Capture").font(.headline)
            CameraPreview(session: session)
                .frame(minWidth: 480, minHeight: 320)
                .background(Color.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button {
                    capturePhoto()
                } label: { Label("Capture Photo", systemImage: "camera") }

                Button {
                    toggleRecording()
                } label: { Label(isRecording ? "Stop Recording" : "Record Video", systemImage: isRecording ? "stop.circle" : "record.circle") }
                .tint(isRecording ? .red : .accentColor)

                Spacer()
                Button("Done") { onCancel() }
            }
        }
        .padding()
        .onAppear(perform: setupSession)
        .onDisappear { session.stopRunning() }
    }

    private func setupSession() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
        // Configure video input and outputs; intentionally minimal to avoid heavy legacy.
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration(); return
        }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // Add audio input if authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()
        session.startRunning()
    }

    private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: PhotoDelegate { photoData in
            if let photoData = photoData {
                DispatchQueue.main.async {
                    onComplete([("capture.jpg", photoData, "image/jpeg")])
                }
            }
        })
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
            isRecording = false
        } else {
            startRecording()
            isRecording = true
        }
    }

    private func startRecording() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempDir.appendingPathComponent("capture-\(UUID().uuidString)").appendingPathExtension("mov")
        movieOutput.startRecording(to: fileURL, recordingDelegate: MovieDelegate { url in
            DispatchQueue.main.async {
                if let data = try? Data(contentsOf: url) {
                    onComplete([(url.lastPathComponent, data, "video/quicktime")])
                }
                try? FileManager.default.removeItem(at: url)
            }
        })
    }

    private func stopRecording() {
        movieOutput.stopRecording()
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let handler: (Data?) -> Void
    init(handler: @escaping (Data?) -> Void) { self.handler = handler }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        handler(photo.fileDataRepresentation())
    }
}

private nonisolated final class MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let handler: (URL) -> Void
    init(handler: @escaping (URL) -> Void) { self.handler = handler }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        handler(outputFileURL)
    }
}

/// NSViewRepresentable wrapper for AVCaptureVideoPreviewLayer.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.wantsLayer = true
        view.layer = layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}

