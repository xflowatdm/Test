import SwiftUI

// MARK: - Заголовок раздела

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Вкладки-«пилюли» (белая — активная)

struct PillTabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { i in
                    Button {
                        selection = i
                    } label: {
                        Text(titles[i])
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selection == i ? Color.black : Theme.textSecondary)
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(
                                selection == i ? Color.white : Theme.row,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Строка выбора (белая — выбранная, с точкой справа)

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
                        .foregroundStyle(selected ? Color.black : Color.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Circle().fill(Color.black).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.white : Theme.row,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Переключатель в строке

struct ToggleRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
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
                    Capsule().fill(isOn ? Color.white : Theme.row)
                    Circle()
                        .fill(isOn ? Color.black : Color(white: 0.5))
                        .padding(3)
                }
                .frame(width: 52, height: 30)
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    value = neutral
                } label: {
                    Text(String(format: format, value))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isNeutral ? Theme.textSecondary : Color.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(isNeutral ? Theme.row : Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let step {
                Slider(value: $value, in: range, step: step).tint(Color.white)
            } else {
                Slider(value: $value, in: range).tint(Color.white)
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
                Button {
                    action(v)
                } label: {
                    Text(label(v))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(current == v ? Color.black : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            current == v ? Color.white : Theme.row,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
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

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(dark ? Color.white : Color.black)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(dark ? Theme.row : Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .foregroundStyle(.white)
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
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 4)
    }
}
