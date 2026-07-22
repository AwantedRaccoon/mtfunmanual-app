import Observation
import SwiftUI

enum AppColorTokens {
    static let rice: UInt = 0xEFE6D4
    static let paper: UInt = 0xF7F0E3
    static let indigo: UInt = 0x172F4A
    static let indigoDeep: UInt = 0x0F2135
    static let vermilion: UInt = 0xB94D42
    static let rose: UInt = 0xDCA59B
    static let mustard: UInt = 0xC5A441
    static let blue: UInt = 0x477594
    static let moss: UInt = 0x78815B

    // Small and secondary copy must remain AA-readable on the paper surface.
    static let secondaryText = indigoDeep
    // Accessible text companion for vermilion emphasis on rice and paper.
    static let vermilionText: UInt = 0xA33E35
    // Accessible text companions preserve category meaning on rice and paper.
    static let blueText: UInt = 0x315E7A
    static let mossText: UInt = 0x4E5935
    static let mustardText: UInt = 0x6B5812
}

@MainActor
@Observable
final class AppTheme {
    let rice = Color(hex: AppColorTokens.rice)
    let paper = Color(hex: AppColorTokens.paper)
    let indigo = Color(hex: AppColorTokens.indigo)
    let indigoDeep = Color(hex: AppColorTokens.indigoDeep)
    let vermilion = Color(hex: AppColorTokens.vermilion)
    let rose = Color(hex: AppColorTokens.rose)
    let mustard = Color(hex: AppColorTokens.mustard)
    let blue = Color(hex: AppColorTokens.blue)
    let moss = Color(hex: AppColorTokens.moss)
    let secondaryText = Color(hex: AppColorTokens.secondaryText)
    let vermilionText = Color(hex: AppColorTokens.vermilionText)
    let blueText = Color(hex: AppColorTokens.blueText)
    let mossText = Color(hex: AppColorTokens.mossText)
    let mustardText = Color(hex: AppColorTokens.mustardText)

    func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Songti SC", size: size, relativeTo: style).weight(.bold)
    }

    func utility(_ size: CGFloat = 11, relativeTo style: Font.TextStyle = .caption) -> Font {
        .custom("Arial Narrow", size: size, relativeTo: style).weight(.bold)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
