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
}
