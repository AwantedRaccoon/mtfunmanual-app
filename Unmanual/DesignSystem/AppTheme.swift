import Observation
import SwiftUI

@MainActor
@Observable
final class AppTheme {
    let rice = Color(hex: 0xEFE6D4)
    let paper = Color(hex: 0xF7F0E3)
    let indigo = Color(hex: 0x172F4A)
    let indigoDeep = Color(hex: 0x0F2135)
    let vermilion = Color(hex: 0xB94D42)
    let rose = Color(hex: 0xDCA59B)
    let mustard = Color(hex: 0xC5A441)
    let blue = Color(hex: 0x477594)
    let moss = Color(hex: 0x78815B)

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
