import SwiftUI

/// Тёмно-синяя палитра с зелёным акцентом
enum Theme {
    static let background = Color(red: 0.035, green: 0.051, blue: 0.067)
    static let panel = Color(red: 0.055, green: 0.078, blue: 0.098)
    static let card = Color(red: 0.063, green: 0.090, blue: 0.110)
    static let row = Color(red: 0.086, green: 0.118, blue: 0.141)
    static let selected = Color(red: 0.110, green: 0.149, blue: 0.180)
    static let stroke = Color.white.opacity(0.075)

    /// Запасной цвет для мелких значков. Основной цвет интерфейса — градиент ниже.
    static let accent = Color.white

    /// Основной цвет: градиент от чёрного к белому слева направо
    static let gradient = LinearGradient(
        colors: [Color(white: 0.04), Color(white: 1.0)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let textPrimary = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let textSecondary = Color(red: 0.53, green: 0.58, blue: 0.64)
    static let textTertiary = Color(red: 0.38, green: 0.43, blue: 0.48)

    static let trackOff = Color(red: 0.145, green: 0.180, blue: 0.212)
    static let knobOff = Color(red: 0.90, green: 0.92, blue: 0.94)
    static let gradientEdge = Color.white.opacity(0.22)

    /// Фон экрана: почти чёрный сверху, к низу чуть светлее
    static var backdrop: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.035, green: 0.051, blue: 0.067), location: 0.0),
                .init(color: Color(red: 0.050, green: 0.071, blue: 0.090), location: 0.55),
                .init(color: Color(red: 0.140, green: 0.165, blue: 0.195), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// Тёмная карточка с тонкой рамкой
    func themedCard(radius: CGFloat = 16) -> some View {
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
