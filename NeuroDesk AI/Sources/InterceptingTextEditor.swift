import SwiftUI
import AppKit

struct InterceptingTextEditor: View {
    @Binding var text: String
    var isDisabled: Bool
    var enterSends: Bool
    var onSend: () -> Void

    @Environment(\.font) private var envFont

    var body: some View {
        // TextEditor automatically uses the environment font; fall back to monospaced body.
        TextEditor(text: $text)
            .font(envFont ?? .system(.body, design: .monospaced))
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1.0)
            .background(Color.clear)
            // Use SwiftUI's native key press handling targeting Return specifically.
            .onKeyPress(.return) {
                // Inspect current modifier keys (best-effort on macOS)
                let modifiers = CurrentModifiers.current
                let shift = modifiers.contains(.shift)
                let command = modifiers.contains(.command)

                if enterSends {
                    // Enter sends; Shift+Enter inserts newline
                    if shift {
                        return .ignored
                    } else {
                        onSend()
                        return .handled
                    }
                } else {
                    // Enter inserts newline; Command+Enter sends
                    if command {
                        onSend()
                        return .handled
                    } else {
                        return .ignored
                    }
                }
            }
    }
}

// A lightweight wrapper to represent current modifier keys in a SwiftUI-friendly way.
private struct CurrentModifiers: OptionSet {
    let rawValue: Int

    static let shift   = CurrentModifiers(rawValue: 1 << 0)
    static let command = CurrentModifiers(rawValue: 1 << 1)
    static let option  = CurrentModifiers(rawValue: 1 << 2)
    static let control = CurrentModifiers(rawValue: 1 << 3)

    static var current: CurrentModifiers {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var mods: CurrentModifiers = []
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return mods
        #else
        return []
        #endif
    }
}
