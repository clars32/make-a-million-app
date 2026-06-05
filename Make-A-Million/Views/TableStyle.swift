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
