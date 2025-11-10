import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: ChatViewModel
    @Binding var selectedSkin: ChatSkin
    @Binding var showSettings: Bool

    let skins = [ChatSkin.terminalSplit, ChatSkin.nativeLight]

    // Local editing state for fallback config
    @State private var fallbackWindowSecondsText: String = ""
    @State private var fallbackLimitText: String = ""
    @State private var blockWhenOut: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Close") { showSettings = false }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Theme").font(.subheadline).foregroundColor(.secondary)
                ForEach(skins) { skin in
                    Button(action: { selectedSkin = skin }) {
                        HStack {
                            Text(skin.displayName)
                            Spacer()
                            if skin.id == selectedSkin.id {
                                Image(systemName: "checkmark").foregroundColor(selectedSkin.accentColor)
                            }
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model").font(.subheadline).foregroundColor(.secondary)
                Picker("Model", selection: Binding(get: { "gpt-4o-mini" }, set: { _ in })) {
                    Text("gpt-4o-mini").tag("gpt-4o-mini")
                    Text("gpt-4o").tag("gpt-4o")
                    Text("gpt-3.5-turbo").tag("gpt-3.5-turbo")
                }.pickerStyle(.menu)
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
                    vm.setBlockWhenOutOfCalls(newValue)
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

