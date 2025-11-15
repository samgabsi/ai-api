import SwiftUI
import AppKit

public struct ChatSkin: Identifiable {
    public let id: String
    public let displayName: String
    public let background: Color
    public let leftPaneBackground: Color
    public let rightPaneBackground: Color
    public let userTextColor: Color
    public let aiTextColor: Color
    public let accentColor: Color
    public let font: Font

    public init(id: String, displayName: String,
                background: Color, leftPaneBackground: Color, rightPaneBackground: Color,
                userTextColor: Color, aiTextColor: Color, accentColor: Color,
                font: Font = .system(.body, design: .monospaced)) {
        self.id = id
        self.displayName = displayName
        self.background = background
        self.leftPaneBackground = leftPaneBackground
        self.rightPaneBackground = rightPaneBackground
        self.userTextColor = userTextColor
        self.aiTextColor = aiTextColor
        self.accentColor = accentColor
        self.font = font
    }

    public static let terminalSplit: ChatSkin = ChatSkin(
        id: "terminalSplit",
        displayName: "Terminal Split",
        background: Color(.sRGB, red: 0.03, green: 0.03, blue: 0.04, opacity: 1.0),
        leftPaneBackground: Color(.sRGB, red: 0.06, green: 0.06, blue: 0.07, opacity: 1.0),
        rightPaneBackground: Color(.sRGB, red: 0.02, green: 0.02, blue: 0.03, opacity: 1.0),
        userTextColor: .white,
        aiTextColor: Color.cyan,
        // Matches AccentColor asset and appAccent tint.
        accentColor: Color(hue: 0.72, saturation: 0.6, brightness: 1.0),
        font: .system(.body, design: .monospaced)
    )

    public static let nativeLight: ChatSkin = ChatSkin(
        id: "nativeLight",
        displayName: "Native Light",
        background: Color(nsColor: .windowBackgroundColor),
        leftPaneBackground: Color.white,
        rightPaneBackground: Color.white,
        userTextColor: .primary,
        aiTextColor: .blue,
        // Uses system blue; you can switch to .appAccent if you want uniform branding.
        accentColor: .blue,
        font: .system(.body, design: .default)
    )

    public static let solarizedDark: ChatSkin = ChatSkin(
        id: "solarizedDark",
        displayName: "Solarized Dark",
        background: Color(red: 0.0, green: 0.169, blue: 0.212),
        leftPaneBackground: Color(red: 0.027, green: 0.212, blue: 0.259),
        rightPaneBackground: Color(red: 0.0, green: 0.169, blue: 0.212),
        userTextColor: Color(red: 0.514, green: 0.580, blue: 0.588), // base0
        aiTextColor: Color(red: 0.149, green: 0.545, blue: 0.824),   // blue
        accentColor: Color(red: 0.149, green: 0.545, blue: 0.824),
        font: .system(.body, design: .monospaced)
    )

    public static let solarizedLight: ChatSkin = ChatSkin(
        id: "solarizedLight",
        displayName: "Solarized Light",
        background: Color(red: 0.992, green: 0.965, blue: 0.890),
        leftPaneBackground: Color.white,
        rightPaneBackground: Color.white,
        userTextColor: Color(red: 0.345, green: 0.431, blue: 0.459), // base00
        aiTextColor: Color(red: 0.027, green: 0.212, blue: 0.259),   // base02
        accentColor: Color(red: 0.149, green: 0.545, blue: 0.824),
        font: .system(.body, design: .default)
    )

    public static let highContrast: ChatSkin = ChatSkin(
        id: "highContrast",
        displayName: "High Contrast",
        background: Color.black,
        leftPaneBackground: Color(red: 0.05, green: 0.05, blue: 0.05),
        rightPaneBackground: Color(red: 0.02, green: 0.02, blue: 0.02),
        userTextColor: Color.white,
        aiTextColor: Color.cyan,
        accentColor: .yellow,
        font: .system(.body, design: .monospaced)
    )

    public static let midnightBlue: ChatSkin = ChatSkin(
        id: "midnightBlue",
        displayName: "Midnight Blue",
        background: Color(hue: 0.62, saturation: 0.35, brightness: 0.10),
        leftPaneBackground: Color(hue: 0.62, saturation: 0.28, brightness: 0.14),
        rightPaneBackground: Color(hue: 0.62, saturation: 0.40, brightness: 0.08),
        userTextColor: Color.white,
        aiTextColor: Color(hue: 0.55, saturation: 0.60, brightness: 1.0),
        accentColor: Color(hue: 0.62, saturation: 0.6, brightness: 0.9),
        font: .system(.body, design: .monospaced)
    )

    public static let softGray: ChatSkin = ChatSkin(
        id: "softGray",
        displayName: "Soft Gray",
        background: Color(red: 0.95, green: 0.95, blue: 0.96),
        leftPaneBackground: Color(red: 0.98, green: 0.98, blue: 0.99),
        rightPaneBackground: Color.white,
        userTextColor: Color(red: 0.20, green: 0.22, blue: 0.26),
        aiTextColor: Color.blue,
        accentColor: Color(hue: 0.62, saturation: 0.35, brightness: 0.9),
        font: .system(.body, design: .default)
    )
}
