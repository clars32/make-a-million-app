//
//  ContentView.swift
//  Make-a-Million
//
//  Template root. It does nothing but host GameView so the app entry point
//  (Make_A_MillionApp) stays untouched. All real UI lives in Views/GameView.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        GameView()
    }
}

#Preview {
    ContentView()
}
