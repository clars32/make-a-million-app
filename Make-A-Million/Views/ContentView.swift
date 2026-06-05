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
    var body: some View {
        AppRoot()
            .environmentObject(GameSettings.shared)
            .font(TableTypography.display(.body))
    }
}

#Preview {
    ContentView()
}
