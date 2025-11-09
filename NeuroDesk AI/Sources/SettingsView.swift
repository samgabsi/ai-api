import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: ChatViewModel
    @Binding var selectedSkin: ChatSkin
    @Binding var showSettings: Bool

    let skins = [ChatSkin.terminalSplit, ChatSkin.nativeLight]

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

            HStack {
                Image(systemName: vm.apiKeyPresent ? "key.fill" : "key")
                    .foregroundColor(vm.apiKeyPresent ? .green : .red)
                Text(vm.apiKeyPresent ? "API key present" : "No API key")
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
    }
}
