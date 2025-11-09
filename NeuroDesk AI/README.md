# NeuroDesk AI (macOS) — Full Source Package

**Bundle ID:** com.gabsi.neurodeskai  
**Platform:** macOS 13+ (SwiftUI)  
**License:** MIT

## Features
- Streaming chat (chunked UI updates)
- Hybrid UI (terminal + split-brain composer)
- Skins/themes with Futuristic Glow default
- Secure API key storage in macOS Keychain
- App Sandbox with outgoing network access

## Build (Xcode 15+)
1. Open this folder in Xcode and create/select the macOS App target pointing to `Sources/`.
2. In **Signing & Capabilities**, ensure **App Sandbox → Outgoing Connections (Client)** is enabled.
3. Build & Run (⌘R). Click **Set API Key** in the app and paste your OpenAI key.
4. Start chatting — streaming will render live in the right pane.

## Assets
- `Assets.xcassets/AppIcon.appiconset` → Xcode compiles these PNGs into `.icns` automatically.
- `Assets.xcassets/NeuroDeskLogo.imageset` → Header logo (PNG) for UI.
- `Assets/Branding/neurodesk_logo_text.png` + `.svg` → Source branding files.

## Notes
- To add more skins, extend `ChatSkin` in `Skin.swift`.
- To change models, wire selection from SettingsView into ChatViewModel.
- ATS is scoped to `api.openai.com` for HTTPS calls.
