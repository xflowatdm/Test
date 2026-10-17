import SwiftUI
import UIKit

/// Монохромная палитра: светлая и тёмная тема (значения из макета «render liquid glass»)
/// Дизайн был написан @inflexibleN1
enum Theme {
    static let bg = dynamic(UIColor(white: 0.949, alpha: 1), UIColor(white: 0, alpha: 1))
    static let surface = dynamic(UIColor(white: 1, alpha: 1), UIColor(white: 0.071, alpha: 1))
    static let surface2 = dynamic(UIColor(white: 0, alpha: 0.05), UIColor(white: 1, alpha: 0.07))
    static let line = dynamic(UIColor(white: 0, alpha: 0.08), UIColor(white: 1, alpha: 0.08))
    static let press = dynamic(UIColor(white: 0, alpha: 0.04), UIColor(white: 1, alpha: 0.05))

    static let text = dynamic(UIColor(white: 0, alpha: 1), UIColor(white: 1, alpha: 1))
    static let text2 = dynamic(UIColor(white: 0, alpha: 0.5), UIColor(white: 1, alpha: 0.5))
    static let text3 = dynamic(UIColor(white: 0, alpha: 0.28), UIColor(white: 1, alpha: 0.28))

    /// Главный цвет: чёрный в светлой теме, белый в тёмной
    static let accent = dynamic(UIColor(white: 0, alpha: 1), UIColor(white: 1, alpha: 1))
    static let onAccent = dynamic(UIColor(white: 1, alpha: 1), UIColor(white: 0, alpha: 1))
    static let ctaFill = dynamic(UIColor(white: 1, alpha: 0.18), UIColor(white: 0, alpha: 0.08))
    static let ctaChip = dynamic(UIColor(white: 1, alpha: 0.14), UIColor(white: 0, alpha: 0.07))

    /// Дорожка включённого переключателя. Ручка системного Toggle всегда белая,
    /// поэтому в тёмной теме дорожка серая, а не белая.
    static let switchOn = dynamic(UIColor(white: 0, alpha: 1), UIColor(white: 0.56, alpha: 1))

    /// Пружина с заметным перелётом (--spring)
    static let spring = Animation.spring(duration: 0.55, bounce: 0.32)
    /// Мягкая пружина почти без перелёта (--soft)
    static let soft = Animation.spring(duration: 0.65, bounce: 0.05)

    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Выбор темы

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension View {
    /// Список в стиле макета: сгруппированные карточки на фоне `bg`
    func themedList() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
    }

    /// Фон строки списка (`surface`)
    func surfaceRow() -> some View {
        listRowBackground(Theme.surface)
    }
}
