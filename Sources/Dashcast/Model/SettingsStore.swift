import CoreGraphics
import DashcastContracts
import Foundation

/// Persists `ServiceSettings` field-by-field in UserDefaults (readable with `defaults read online.davidlam.dashcast`).
enum SettingsStore {
    private enum Key {
        static let displayMode = "settings.displayMode"
        static let mirrorDisplayID = "settings.mirrorDisplayID"
        static let latencyMode = "settings.latencyMode"
        static let tierOverrideID = "settings.tierOverrideID"
        static let audioEnabled = "settings.audioEnabled"
        static let inputEnabled = "settings.inputEnabled"
        static let hiDPI = "settings.hiDPI"
    }

    static func load(from defaults: UserDefaults = .standard) -> ServiceSettings {
        var settings = ServiceSettings()
        if let raw = defaults.string(forKey: Key.displayMode), let mode = DisplayMode(rawValue: raw) {
            settings.displayMode = mode
        }
        if let id = defaults.object(forKey: Key.mirrorDisplayID) as? NSNumber {
            settings.mirrorDisplayID = CGDirectDisplayID(id.uint32Value)
        }
        if let raw = defaults.string(forKey: Key.latencyMode), let mode = LatencyMode(rawValue: raw) {
            settings.latencyMode = mode
        }
        if let id = defaults.string(forKey: Key.tierOverrideID), Tier.all.contains(where: { $0.id == id }) {
            settings.tierOverrideID = id
        }
        if defaults.object(forKey: Key.audioEnabled) != nil { settings.audioEnabled = defaults.bool(forKey: Key.audioEnabled) }
        if defaults.object(forKey: Key.inputEnabled) != nil { settings.inputEnabled = defaults.bool(forKey: Key.inputEnabled) }
        if defaults.object(forKey: Key.hiDPI) != nil { settings.hiDPI = defaults.bool(forKey: Key.hiDPI) }
        return settings
    }

    static func save(_ settings: ServiceSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.displayMode.rawValue, forKey: Key.displayMode)
        if let id = settings.mirrorDisplayID {
            defaults.set(NSNumber(value: id), forKey: Key.mirrorDisplayID)
        } else {
            defaults.removeObject(forKey: Key.mirrorDisplayID)
        }
        defaults.set(settings.latencyMode.rawValue, forKey: Key.latencyMode)
        if let id = settings.tierOverrideID {
            defaults.set(id, forKey: Key.tierOverrideID)
        } else {
            defaults.removeObject(forKey: Key.tierOverrideID)
        }
        defaults.set(settings.audioEnabled, forKey: Key.audioEnabled)
        defaults.set(settings.inputEnabled, forKey: Key.inputEnabled)
        defaults.set(settings.hiDPI, forKey: Key.hiDPI)
    }
}
