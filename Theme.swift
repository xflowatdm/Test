import SwiftUI

/// Тёмная палитра: почти чёрный фон, графитовые панели, белое выделение
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.062)
    static let panel = Color(red: 0.098, green: 0.098, blue: 0.106)
    static let card = Color(red: 0.082, green: 0.082, blue: 0.090)
    static let row = Color(red: 0.135, green: 0.135, blue: 0.147)
    static let stroke = Color.white.opacity(0.07)
    static let textSecondary = Color(white: 0.58)
    static let textTertiary = Color(white: 0.42)
}

extension View {
    /// Тёмная карточка со скруглением
    func themedCard(radius: CGFloat = 18) -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}
