//
//  Haptics.swift
//  Make-a-Million
//
//  Tiny wrapper over UIFeedbackGenerator so call sites stay one-liners and the
//  UIKit import is contained here. All entry points are main-actor and a no-op
//  on platforms without UIKit. The OS still honours the device's System Haptics
//  setting, so this never overrides a user who has turned haptics off.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum Haptics {

    /// A light tap played when it becomes the local player's turn to act. Kept
    /// gentle on purpose — it's a "you're up" nudge, not an alert.
    static func yourTurn() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred(intensity: 0.7)
        #endif
    }
}
