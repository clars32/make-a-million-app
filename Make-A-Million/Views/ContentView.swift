//
//  ContentView.swift
//  Make-a-Million
//
//  Thin shell that hosts AppRoot. The actual mode selection (Solo,
//  Host, Join) and lobby flow lives there; ContentView stays minimal so
//  the app entry point (Make_A_MillionApp) doesn't need to know about
//  any of it.
//

import SwiftUI

struct ContentView: View {
    @State private var showingSplash = true

    var body: some View {
        ZStack {
            AppRoot()
                .environmentObject(GameSettings.shared)
                .font(TableTypography.display(.body))

            if showingSplash {
                SplashScreen {
                    dismissSplash()
                }
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(10)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1900))
            dismissSplash()
        }
    }

    private func dismissSplash() {
        guard showingSplash else { return }
        withAnimation(.easeOut(duration: 0.45)) {
            showingSplash = false
        }
    }
}

private struct SplashScreen: View {
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        ZStack {
            TableFeltBackground()

            GeometryReader { proxy in
                let isWide = proxy.size.width > 700
                let markSize = min(proxy.size.width * (isWide ? 0.34 : 0.54), 250)

                VStack(spacing: isWide ? 26 : 22) {
                    Spacer(minLength: proxy.size.height * 0.12)

                    splashMark(size: markSize)
                        .scaleEffect(revealed || reduceMotion ? 1 : 0.88)
                        .opacity(revealed || reduceMotion ? 1 : 0)

                    VStack(spacing: 8) {
                        Text("Make-a-Million")
                            .font(TableTypography.display(isWide ? .largeTitle : .title, weight: .heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text("A TrueBlueDev production")
                            .font(TableTypography.display(.headline, weight: .bold))
                            .foregroundStyle(TableStyle.tableGold)
                            .tracking(1.6)
                    }
                    .opacity(revealed || reduceMotion ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : 12)

                    Spacer(minLength: proxy.size.height * 0.14)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Make-a-Million by TrueBlueDev")
        .onAppear {
            guard !reduceMotion else {
                revealed = true
                return
            }
            withAnimation(.spring(response: 0.72, dampingFraction: 0.78)) {
                revealed = true
            }
        }
    }

    private func splashMark(size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                CardBackFace(width: size * 0.36, height: size * 0.52)
                    .rotationEffect(.degrees(cardRotation(index)))
                    .offset(x: revealed || reduceMotion ? cardX(index, size: size) : 0,
                            y: revealed || reduceMotion ? cardY(index, size: size) : 8)
                    .opacity(revealed || reduceMotion ? 1 : 0.25)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            TableStyle.tableGold.opacity(0.34),
                            TableStyle.actionBlue.opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.64))
                .frame(width: size * 1.12, height: size * 1.12)
                .blendMode(.screen)

            Image("animal_tiger")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.58, height: size * 0.58)
                .shadow(color: .black.opacity(0.36), radius: 14, y: 8)
                .offset(y: size * 0.02)
        }
        .frame(width: size * 1.2, height: size * 0.86)
    }

    private func cardRotation(_ index: Int) -> Double {
        [-18, -8, 0, 8, 18][index]
    }

    private func cardX(_ index: Int, size: CGFloat) -> CGFloat {
        [-0.34, -0.17, 0, 0.17, 0.34][index] * size
    }

    private func cardY(_ index: Int, size: CGFloat) -> CGFloat {
        [0.07, -0.02, -0.06, -0.02, 0.07][index] * size
    }
}

#Preview {
    ContentView()
}
