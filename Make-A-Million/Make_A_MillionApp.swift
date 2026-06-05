//
//  Make_A_MillionApp.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/18/26.
//

import SwiftUI

@main
struct Make_A_MillionApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var orientationDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
