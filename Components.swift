import SwiftUI

// MARK: - Нажатие с пружиной

/// Кнопка слегка уменьшается при нажатии и возвращается с пружиной
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.15) : Theme.spring, value: configuration.isPressed)
    }
}

// MARK: - Появление при открытии

/// Элемент выплывает снизу из размытия; `index` задаёт очередь
struct Rise: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .scaleEffect(shown ? 1 : 0.985)
            .blur(radius: shown ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Theme.soft.speed(0.72).delay(Double(index) * 0.07 + 0.08)) { shown = true }
                }
            }
    }
}

extension View {
    func rise(_ index: Int) -> some View {
        modifier(Rise(index: index))
    }
}

// MARK: - Тряска

/// Короткая тряска по горизонтали: увеличьте `progress` на 1, чтобы встряхнуть
struct ShakeEffect: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = progress - progress.rounded(.down)
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0.2, -8), (0.4, 7), (0.6, -5), (0.8, 3), (1, 0)]
        var x: CGFloat = 0
        for i in 1..<points.count where t <= points[i].0 {
            let a = points[i - 1]
            let b = points[i]
            x = a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
            break
        }
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

extension View {
    func shake(_ trigger: Int) -> some View {
        modifier(ShakeEffect(progress: CGFloat(trigger)))
            .animation(.timingCurve(0.36, 0.07, 0.19, 0.97, duration: 0.5), value: trigger)
    }
}

// MARK: - Галочка, которая прорисовывается

struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 5 * s, y: 12.5 * s))
        p.addLine(to: CGPoint(x: 9.5 * s, y: 17 * s))
        p.addLine(to: CGPoint(x: 19 * s, y: 7.5 * s))
        return p
    }
}

struct TickMark: View {
    var drawn: Bool
    var size: CGFloat = 18

    var body: some View {
        TickShape()
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: 2.4 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .animation(.timingCurve(0.6, 0, 0.2, 1, duration: 0.35).delay(drawn ? 0.05 : 0), value: drawn)
    }
}

/// Галочка, которая прорисовывается сразу после появления
struct AppearingTick: View {
    var size: CGFloat = 18
    @State private var drawn = false

    var body: some View {
        TickMark(drawn: drawn, size: size)
            .onAppear { drawn = true }
    }
}

// MARK: - Кольцо прогресса

struct ProgressRing: View {
    let value: Double
    var lineWidth: CGFloat = 2.4
    var track: Color = Theme.line
    var tint: Color = Theme.text

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Прокручивающийся текст

/// Старое значение уходит вверх и размывается, новое въезжает снизу с пружиной
struct RollTransition: Transition {
    var up = true

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(y: offset(for: phase))
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 4)
    }

    private func offset(for phase: TransitionPhase) -> CGFloat {
        let direction: CGFloat = up ? 1 : -1
        switch phase {
        case .willAppear: return 10 * direction
        case .didDisappear: return -10 * direction
        default: return 0
        }
    }
}

struct RollText: View {
    let text: String
    var up = true

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(text)
                .lineLimit(1)
                .id(text)
                .transition(RollTransition(up: up))
        }
        .animation(Theme.spring, value: text)
    }
}

// MARK: - Строки списка

/// Подпись секции (`.label` в макете)
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text2)
            .textCase(nil)
    }
}

/// Пояснение под секцией (`.note` в макете)
struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text2)
            .lineSpacing(2)
    }
}

/// Маленькая метка в рамке рядом с заголовком строки
struct TagLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.text3, lineWidth: 0.5)
            )
    }
}

/// Заголовок строки с необязательной подписью и меткой
struct ItemLabel: View {
    let title: String
    var sub: String? = nil
    var tag: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                if let tag { TagLabel(text: tag) }
            }
            if let sub {
                Text(sub)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Строка со значением и стрелками ↕: открывает выбор в шите
struct ValueRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ItemLabel(title: title)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    RollText(text: value)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.text2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Строка со сводкой и шевроном: переключает вкладку
struct ChevronRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ItemLabel(title: title)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    RollText(text: value)
                        .foregroundStyle(Theme.text2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .font(.system(size: 16))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Строка выбора с галочкой справа
struct TickRow: View {
    let title: String
    var sub: String? = nil
    let selected: Bool
    var indent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ItemLabel(title: title, sub: sub)
                Spacer(minLength: 8)
                TickMark(drawn: selected)
                    .foregroundStyle(Theme.text)
            }
            .padding(.leading, indent ? 16 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Строка-действие: текст по всей ширине
struct ActionRow: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22)
                }
                Text(title).font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Системный переключатель в монохроме
struct SwitchRow: View {
    let title: String
    var sub: String? = nil
    var tag: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            ItemLabel(title: title, sub: sub, tag: tag)
        }
        .tint(Theme.switchOn)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
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
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    value = neutral
                } label: {
                    Text(String(format: format, value))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isNeutral ? Theme.text2 : Theme.text)
                        .underline(!isNeutral)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderless)
            }
            if let step {
                Slider(value: $value, in: range, step: step).tint(Theme.accent)
            } else {
                Slider(value: $value, in: range).tint(Theme.accent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Значок загрузки (стрелка вверх над чертой)

struct UploadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 12 * s, y: 16 * s))
        p.addLine(to: CGPoint(x: 12 * s, y: 5 * s))
        p.move(to: CGPoint(x: 7 * s, y: 10 * s))
        p.addLine(to: CGPoint(x: 12 * s, y: 5 * s))
        p.addLine(to: CGPoint(x: 17 * s, y: 10 * s))
        p.move(to: CGPoint(x: 5 * s, y: 19 * s))
        p.addLine(to: CGPoint(x: 19 * s, y: 19 * s))
        return p
    }
}

/// Круг со стрелкой: расходящиеся кольца, покачивание, а при загрузке — кольцо прогресса
struct UploadOrb: View {
    let loading: Bool
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: loading || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if !loading && !reduceMotion {
                    pulse(t)
                    pulse(t + 1.3)
                }
                Circle().fill(Theme.accent)
                UploadGlyph()
                    .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 30, height: 30)
                    .offset(y: reduceMotion ? 0 : bob(t))
                    .opacity(loading ? 0 : 1)
                    .scaleEffect(loading ? 0.5 : 1)
                ProgressRing(value: progress, lineWidth: 3, track: Color.gray.opacity(0.35), tint: Theme.onAccent)
                    .frame(width: 44, height: 44)
                    .opacity(loading ? 1 : 0)
                    .scaleEffect(loading ? 1 : 0.6)
            }
        }
        .frame(width: 76, height: 76)
        .animation(Theme.spring, value: loading)
    }

    private func pulse(_ t: Double) -> some View {
        let p = (t / 2.6).truncatingRemainder(dividingBy: 1)
        let e = 1 - pow(1 - p, 2.2)
        return Circle()
            .stroke(Theme.text3, lineWidth: 1)
            .scaleEffect(1 + 1.3 * e)
            .opacity(1 - e)
    }

    private func bob(_ t: Double) -> CGFloat {
        CGFloat(-4 * (0.5 - 0.5 * cos(2 * .pi * t / 2.6)))
    }
}
