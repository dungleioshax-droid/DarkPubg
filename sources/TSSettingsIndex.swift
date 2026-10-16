//
//  TSSettingsIndex.swift
//  DarkSpeed
//
//  Kernrw48: app chỉ còn ESP — gỡ toàn bộ setting của HUD speed/FPS
//  (Display Mode, Incoming Only, Appearance, Landscape, Size, Prefixes,
//  Unit, Base Game). Giữ 3 setting cấu trúc của cửa sổ HUD (Pass-through,
//  Keep In-place, Hide @snapshot) + toggle ESP Box.
//

import Foundation

enum TSSettingsIndex: Int, CaseIterable {
    case passthroughMode = 0
    case keepInPlace
    case hideAtSnapshot
    case showESPBox

    var key: String {
        switch self {
        case .passthroughMode:
            return HUDUserDefaultsKeyPassthroughMode
        case .keepInPlace:
            return HUDUserDefaultsKeyKeepInPlace
        case .hideAtSnapshot:
            return HUDUserDefaultsKeyHideAtSnapshot
        case .showESPBox:
            return HUDUserDefaultsKeyShowESPBox
        }
    }

    var title: String {
        switch self {
        case .passthroughMode:
            return NSLocalizedString("Pass-through", comment: "TSSettingsIndex")
        case .keepInPlace:
            return NSLocalizedString("Keep In-place", comment: "TSSettingsIndex")
        case .hideAtSnapshot:
            return NSLocalizedString("Hide @snapshot", comment: "TSSettingsIndex")
        case .showESPBox:
            return NSLocalizedString("ESP Box", comment: "TSSettingsIndex")
        }
    }

    func subtitle(highlighted: Bool, restartRequired: Bool) -> String {
        switch self {
        case .passthroughMode:
            if restartRequired {
                return NSLocalizedString("Re-open to apply", comment: "TSSettingsIndex")
            } else {
                return highlighted ? NSLocalizedString("ON", comment: "TSSettingsIndex") : NSLocalizedString("OFF", comment: "TSSettingsIndex")
            }
        case .keepInPlace: fallthrough
        case .hideAtSnapshot: fallthrough
        case .showESPBox:
            return highlighted ? NSLocalizedString("ON", comment: "TSSettingsIndex") : NSLocalizedString("OFF", comment: "TSSettingsIndex")
        }
    }
}
