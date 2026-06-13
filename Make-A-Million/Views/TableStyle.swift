//
//  TableStyle.swift
//  Make-a-Million
//
//  Shared visual language for the in-game table surfaces.
//

import SwiftUI

enum TableStyle {
    static let feltTop = Color(red: 0.08, green: 0.31, blue: 0.19)
    static let feltMid = Color(red: 0.04, green: 0.23, blue: 0.14)
    static let feltBottom = Color(red: 0.02, green: 0.13, blue: 0.09)

    static let panelFill = Color.white.opacity(0.075)
    static let panelStroke = Color.white.opacity(0.16)
    static let panelStrokeActive = Color(red: 0.93, green: 0.78, blue: 0.36)

    static let teamBlue = Color(red: 0.42, green: 0.78, blue: 0.92)
    static let teamAmber = Color(red: 0.94, green: 0.63, blue: 0.30)
    static let tableGold = Color(red: 0.92, green: 0.78, blue: 0.36)
    static let actionBlue = Color(red: 0.23, green: 0.49, blue: 0.92)
    static let passGray = Color(red: 0.48, green: 0.52, blue: 0.49)

    static let cardSelected = Color(red: 0.38, green: 0.75, blue: 0.92)
    static let cardPlayable = Color(red: 0.92, green: 0.78, blue: 0.36)

    static func teamTint(_ team: Int) -> Color {
        team == 0 ? teamBlue : teamAmber
    }

    static func suitSwatch(_ color: CardColor) -> Color {
        color == .black ? .black : color.swatch
    }
}

enum TableTypography {
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func money(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        display(style, weight: weight).monospacedDigit()
    }
}

struct TableIconButtonStyle: ButtonStyle {
    var tint: Color = TableStyle.cardSelected
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TableTypography.display(.subheadline, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.10))
                    }
            }
            .overlay {
                Circle()
                    .stroke(tint.opacity(configuration.isPressed ? 0.70 : 0.34),
                            lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72),
                       value: configuration.isPressed)
            .contentShape(Circle())
    }
}

struct TablePillButtonStyle: ButtonStyle {
    enum Emphasis {
        case filled
        case tinted
        case quiet
    }

    var tint: Color = TableStyle.actionBlue
    var emphasis: Emphasis = .filled
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TableTypography.display(compact ? .subheadline : .headline,
                                          weight: .bold))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, compact ? 14 : 18)
            .frame(minHeight: compact ? 36 : 44)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor(configuration.isPressed))
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(configuration.isPressed ? 0.08 : 0.0))
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(strokeColor(configuration.isPressed), lineWidth: 1)
            }
            .shadow(color: .black.opacity(emphasis == .quiet ? 0.12 : 0.22),
                    radius: emphasis == .quiet ? 4 : 8,
                    y: emphasis == .quiet ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch emphasis {
        case .filled: return .white
        case .tinted: return .white
        case .quiet: return tint
        }
    }

    private func backgroundColor(_ pressed: Bool) -> Color {
        switch emphasis {
        case .filled:
            return tint.opacity(pressed ? 0.88 : 1.0)
        case .tinted:
            return tint.opacity(pressed ? 0.30 : 0.18)
        case .quiet:
            return Color.white.opacity(pressed ? 0.14 : 0.08)
        }
    }

    private func strokeColor(_ pressed: Bool) -> Color {
        switch emphasis {
        case .filled:
            return Color.white.opacity(pressed ? 0.34 : 0.20)
        case .tinted, .quiet:
            return tint.opacity(pressed ? 0.76 : 0.42)
        }
    }
}

enum TableMotion {
    static func screenAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    static func screenTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.985))
                .combined(with: .offset(y: 12)),
            removal: .opacity
                .combined(with: .scale(scale: 1.015))
                .combined(with: .offset(y: -8)))
    }
}

extension View {
    func tablePanel(cornerRadius: CGFloat = 16, shadowOpacity: Double = 0.28) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(TableStyle.panelFill)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(TableStyle.panelStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: 12, y: 5)
    }
}

struct TableFeltBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TableStyle.feltTop, TableStyle.feltMid, TableStyle.feltBottom],
                startPoint: .top,
                endPoint: .bottom)

            TableFeltTexture()
                .blendMode(.softLight)

            LinearGradient(
                colors: [.black.opacity(0.10), .clear, .black.opacity(0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

private struct TableFeltTexture: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 10
            for y in stride(from: CGFloat(0), through: size.height, by: step) {
                for x in stride(from: CGFloat(0), through: size.width, by: step) {
                    let seed = Int(x * 17 + y * 31) % 9
                    let length = CGFloat(seed % 4) + 1.5
                    let alpha = 0.020 + Double(seed) * 0.002
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y + CGFloat(seed % 3)))
                    path.addLine(to: CGPoint(x: x + length, y: y + CGFloat(seed % 3)))
                    context.stroke(path, with: .color(.white.opacity(alpha)), lineWidth: 0.6)
                }
            }
        }
        .ignoresSafeArea()
    }
}
