import SwiftUI

// MARK: - Текст поверх градиента «чёрный → белый»

/// Слева, где фон тёмный, содержимое белое, справа, где фон светлый, чёрное.
/// Так текст и значки читаются на любом конце градиента.
struct SplitTone<Content: View>: View {
    let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .foregroundStyle(Color.white)
                .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
            content
                .foregroundStyle(Color.black)
                .mask(HStack(spacing: 0) { Color.clear; Rectangle() })
        }
    }
}

// MARK: - Заголовок раздела

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 20, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Вкладки-«пилюли» (активная — с градиентом)

struct PillTabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { i in
                    let selected = selection == i
                    Button {
                        selection = i
                    } label: {
                        Group {
                            if selected {
                                SplitTone {
                                    Text(titles[i]).font(.system(size: 15, weight: .semibold))
                                }
                            } else {
                                Text(titles[i])
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(
                            selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.row),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selected ? Theme.gradientEdge : Theme.stroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Строка выбора (выбранная — с градиентной рамкой и галочкой)

struct SelectRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.selected : Theme.row,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.stroke),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Карточка с переключателем (иконка, заголовок, подпись)

struct ToggleRow: View {
    let title: String
    var caption: String? = nil
    var icon: String? = nil
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1.5))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.trackOff))
                    Circle()
                        .fill(isOn ? Color.black : Theme.knobOff)
                        .padding(3)
                }
                .frame(width: 50, height: 30)
                .overlay(
                    Capsule().stroke(isOn ? Theme.gradientEdge : Color.clear, lineWidth: 1)
                )
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - Ползунок (значение справа, нажатие сбрасывает)

struct GradeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    var format: String = "%.2f"
    var step: Double? = nil

    var body: some View {
        let isNeutral = abs(value - neutral) < 0.0001
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    value = neutral
                } label: {
                    Text(String(format: format, value))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isNeutral ? Theme.textSecondary : Color.white)
                        .underline(!isNeutral)
                }
                .buttonStyle(.plain)
            }
            if let step {
                Slider(value: $value, in: range, step: step).tint(Color(white: 0.78))
            } else {
                Slider(value: $value, in: range).tint(Color(white: 0.78))
            }
        }
    }
}

// MARK: - Быстрый выбор значений

struct ChipRow: View {
    let values: [Double]
    let current: Double
    let label: (Double) -> String
    let action: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(values, id: \.self) { v in
                let selected = current == v
                Button {
                    action(v)
                } label: {
                    Group {
                        if selected {
                            SplitTone {
                                Text(label(v)).font(.system(size: 14, weight: .semibold))
                            }
                        } else {
                            Text(label(v))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(
                        selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.row),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? Theme.gradientEdge : Theme.stroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Кнопки

struct PrimaryLabel: View {
    let title: String
    var icon: String? = nil
    var dark: Bool = false

    private var label: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(size: 16, weight: .bold))
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        Group {
            if dark {
                label.foregroundStyle(Color.white)
            } else {
                SplitTone { label }
            }
        }
        .frame(height: 52)
        .background(
            dark ? AnyShapeStyle(Theme.row) : AnyShapeStyle(Theme.gradient),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(dark ? Theme.stroke : Theme.gradientEdge, lineWidth: 1)
        )
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var dark: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PrimaryLabel(title: title, icon: icon, dark: dark)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Полоса прогресса с градиентом

struct GradientProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.trackOff)
                Capsule()
                    .fill(Theme.gradient)
                    .frame(width: max(8, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }
}

// MARK: - Строка «название — значение»

struct InfoRow: View {
    let label: String
    let value: String
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(Theme.textPrimary)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 15))
            .padding(.vertical, 11)
            if divider {
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
        }
    }
}

struct SmallCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 4)
    }
}
