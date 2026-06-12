//
//  AnimalSoundPlayer.swift
//  Make-a-Million
//

import AVFoundation

@MainActor
enum SoundCue: Hashable {
    case buttonSelect
    case cardShuffle
    case cardPlay
    case trickTaken
    case animalBear
    case animalBull
    case animalTiger
    case bullStampede

    var resourceNames: [String] {
        switch self {
        case .buttonSelect: return ["sfx_button_select"]
        case .cardShuffle: return ["sfx_shuffle"]
        case .cardPlay: return ["sfx_card_play_1", "sfx_card_play_2", "sfx_card_play_3"]
        case .trickTaken: return ["sfx_trick_taken"]
        case .animalBear: return ["animal_bear_play"]
        case .animalBull: return ["animal_bull_play"]
        case .animalTiger: return ["animal_tiger_play"]
        case .bullStampede: return ["bulls_on_parade"]
        }
    }

    var volume: Float {
        switch self {
        case .buttonSelect: return 0.28
        case .cardShuffle: return 0.34
        case .cardPlay: return 0.30
        case .trickTaken: return 0.36
        case .animalBear, .animalBull, .animalTiger: return 0.86
        case .bullStampede: return 0.92
        }
    }

    var minimumReplayInterval: TimeInterval {
        switch self {
        case .buttonSelect: return 0.08
        case .cardPlay: return 0.045
        default: return 0.0
        }
    }

    var usesAnimalSetting: Bool {
        switch self {
        case .animalBear, .animalBull, .animalTiger, .bullStampede: return true
        default: return false
        }
    }

    var randomizedRate: Float {
        switch self {
        case .cardPlay:
            return Float.random(in: 0.94...1.06)
        case .buttonSelect:
            return Float.random(in: 0.98...1.03)
        default:
            return 1.0
        }
    }
}

@MainActor
final class SoundEffectPlayer {
    static let shared = SoundEffectPlayer()

    private var players: [String: AVAudioPlayer] = [:]
    private var lastPlayedAt: [SoundCue: Date] = [:]
    private var didConfigureSession = false

    private init() {}

    func play(_ cue: SoundCue) {
        guard shouldPlay(cue) else { return }
        configureSessionIfNeeded()

        let cueName = cue.resourceNames.randomElement() ?? cue.resourceNames[0]
        let player: AVAudioPlayer
        if let cached = players[cueName] {
            player = cached
        } else {
            guard let loaded = loadPlayer(named: cueName) else { return }
            players[cueName] = loaded
            player = loaded
        }

        lastPlayedAt[cue] = Date()
        player.currentTime = 0
        player.enableRate = true
        player.rate = cue.randomizedRate
        player.volume = cue.volume * Float(GameSettings.shared.soundEffectsVolume)
        player.play()
    }

    private func shouldPlay(_ cue: SoundCue) -> Bool {
        guard GameSettings.shared.soundEffectsEnabled else { return false }
        if cue.usesAnimalSetting && !GameSettings.shared.animalSoundsEnabled { return false }

        let interval = cue.minimumReplayInterval
        guard interval > 0, let last = lastPlayedAt[cue] else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true

        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        } catch {
            // Sound effects are nice-to-have; gameplay should never depend on audio.
        }
    }

    private func loadPlayer(named cueName: String) -> AVAudioPlayer? {
        let url = resourceURL(named: cueName)
        guard let url else { return nil }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            return nil
        }
    }

    private func resourceURL(named cueName: String) -> URL? {
        for ext in ["mp3", "wav", "m4a", "aif", "aiff"] {
            if let url = Bundle.main.url(forResource: cueName, withExtension: ext, subdirectory: "Sounds") {
                return url
            }
            if let url = Bundle.main.url(forResource: cueName, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

typealias AnimalSoundPlayer = SoundEffectPlayer
