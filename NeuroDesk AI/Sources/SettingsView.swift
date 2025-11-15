import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: ChatViewModel
    @Binding var selectedSkin: ChatSkin
    @Binding var showSettings: Bool

    let skins = [
        ChatSkin.terminalSplit,
        ChatSkin.nativeLight,
        ChatSkin.solarizedDark,
        ChatSkin.solarizedLight,
        ChatSkin.highContrast,
        ChatSkin.midnightBlue,
        ChatSkin.softGray
    ]

    // Local editing state for fallback config
    @State private var fallbackWindowSecondsText: String = ""
    @State private var fallbackLimitText: String = ""
    @State private var blockWhenOut: Bool = true

    // Mainstream OpenAI chat models (update as needed)
    private let availableModels: [String] = [
        // 4.1 family (vision-capable)
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-preview",
        // 4o family (vision-capable)
        "gpt-4o",
        "gpt-4o-mini",
        // Legacy/popular (non-vision)
        "gpt-3.5-turbo"
    ]

    private let visionCapableModels: Set<String> = [
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-preview",
        "gpt-4o", "gpt-4o-mini"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Sticky header
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Close") { showSettings = false }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut("w", modifiers: [.command])
            }
            .padding([.horizontal, .top])

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme").font(.subheadline).foregroundColor(.secondary)
                        ForEach(skins) { skin in
                            Button(action: { selectedSkin = skin }) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(skin.background)
                                            .frame(width: 36, height: 24)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(skin.accentColor.opacity(0.6), lineWidth: 1)
                                            )
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(skin.leftPaneBackground)
                                            .frame(width: 14, height: 10)
                                            .offset(x: -7)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(skin.rightPaneBackground)
                                            .frame(width: 14, height: 10)
                                            .offset(x: 7)
                                    }
                                    Text(skin.displayName)
                                    Spacer()
                                    if skin.id == selectedSkin.id {
                                        Image(systemName: "checkmark").foregroundColor(selectedSkin.accentColor)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model").font(.subheadline).foregroundColor(.secondary)

                        Picker("OpenAI Model", selection: $vm.selectedModel) {
                            ForEach(availableModels, id: \.self) { model in
                                HStack {
                                    Text(model)
                                    if visionCapableModels.contains(model) {
                                        Image(systemName: "eye")
                                            .foregroundColor(.blue)
                                            .help("Supports image input")
                                    }
                                }
                                .tag(model)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack {
                            Text("Current:")
                            Text(vm.selectedModel)
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Save") {
                                // Selection persists automatically via ChatViewModel.didSet; close the sheet.
                                showSettings = false
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Usage (Fallback) — used when server rate headers are unavailable")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Toggle(isOn: $blockWhenOut) {
                            Text("Block sends when out of calls")
                        }
                        .onChange(of: blockWhenOut) { _, newValue in
                            vm.blockWhenOutOfCalls = newValue
                        }

                        HStack {
                            Text("Window Length (seconds)")
                            Spacer()
                            TextField("", text: $fallbackWindowSecondsText)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .onSubmit(applyFallbackWindowSeconds)
                        }
                        HStack {
                            Text("Limit per Window")
                            Spacer()
                            TextField("", text: $fallbackLimitText)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .onSubmit(applyFallbackLimit)
                        }
                        HStack {
                            Text("Current Window Ends")
                            Spacer()
                            Text(vm.fallbackWindowEndsAt.formatted(date: .omitted, time: .standard))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Used / Limit")
                            Spacer()
                            Text("\(vm.fallbackUsedInWindow) / \(vm.fallbackLimitInWindow)")
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Warning thresholds")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("• Warning at 75% used")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Critical at 90% used")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)

                        HStack {
                            Button("Apply") {
                                applyFallbackWindowSeconds()
                                applyFallbackLimit()
                            }
                            Button("Reset Window") {
                                vm.updateFallbackWindow(seconds: vm.fallbackWindowSeconds)
                            }
                        }
                        .padding(.top, 4)
                    }

                    Divider()

                    HStack {
                        Image(systemName: vm.apiKeyPresent ? "key.fill" : "key")
                            .foregroundColor(vm.apiKeyPresent ? .green : .red)
                        Text(vm.apiKeyPresent ? "API key present" : "No API key")
                    }

                    Spacer()
                }
                .padding()
            }
        }
        .onAppear {
            fallbackWindowSecondsText = String(vm.fallbackWindowSeconds)
            fallbackLimitText = String(vm.fallbackLimitInWindow)
            blockWhenOut = vm.blockWhenOutOfCalls
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
    }

    private func applyFallbackWindowSeconds() {
        if let seconds = Int(fallbackWindowSecondsText) {
            vm.updateFallbackWindow(seconds: seconds)
            // refresh display text to clamped value
            fallbackWindowSecondsText = String(vm.fallbackWindowSeconds)
        }
    }

    private func applyFallbackLimit() {
        if let limit = Int(fallbackLimitText) {
            vm.updateFallbackLimit(limit)
            fallbackLimitText = String(vm.fallbackLimitInWindow)
        }
    }
}
