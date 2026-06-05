//
//  OrientationLock.swift
//  Make-a-Million
//
//  Runtime orientation control. Most screens are phone-first portrait; the
//  tabletop board is intentionally landscape.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
final class OrientationLock {
    static let shared = OrientationLock()

    private(set) var mask: UIInterfaceOrientationMask = .portrait

    func lock(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            refreshSupportedOrientations()
            return
        }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        refreshSupportedOrientations(in: scene)
    }

    private func refreshSupportedOrientations(in scene: UIWindowScene? = nil) {
        let scenes = scene.map { [$0] } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
#endif
