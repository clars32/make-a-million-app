//
//  SoloGameStore.swift
//  Make-a-Million
//
//  Persists the single resumable solo match to UserDefaults (JSON) and
//  publishes its presence so the menu can offer "Continue". There is exactly
//  one slot: starting a new match overwrites it, finishing a match clears it.
//
//  This is solo-only. The networked host/join stacks own their own state on
//  NetSession and never touch this store.
//

import Foundation
import Combine

@MainActor
final class SoloGameStore: ObservableObject {

    static let shared = SoloGameStore()

    private let key = "soloGame.saved.v1"

    /// The currently saved game, or nil when there is nothing to resume. The
    /// menu observes this directly to show / hide the Continue entry.
    @Published private(set) var saved: SavedSoloGame?

    private init() {
        saved = Self.read(key: key)
    }

    var hasResumableGame: Bool { saved != nil }

    /// Overwrite the slot with the latest snapshot. Called after every move so
    /// a resume lands on the exact card.
    func save(_ game: SavedSoloGame) {
        saved = game
        if let data = try? JSONEncoder().encode(game) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Drop the saved match — nothing left to resume (the match was decided,
    /// or a fresh game is taking the slot).
    func clear() {
        guard saved != nil || UserDefaults.standard.data(forKey: key) != nil else { return }
        saved = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func read(key: String) -> SavedSoloGame? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedSoloGame.self, from: data)
    }
}
