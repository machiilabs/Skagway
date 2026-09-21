import AVFoundation
import Foundation

/// Per-play captions choice for the built-in player. Not persisted across videos.
enum CaptionSelection: Equatable {
    case off
    case sidecar
    case inBand(id: String)
}

/// One playable option from the asset’s AV **legible** media-selection group.
struct InBandCaptionOption: Identifiable {
    let id: String
    let title: String
    let option: AVMediaSelectionOption
}

/// User-visible names for in-band caption rows. Never surfaces AV’s “Media group N”.
enum CaptionMenuCopy {
    static func isGenericMediaGroupName(_ name: String) -> Bool {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^media[[:space:]]*group([[:space:]]*[0-9]+)?$"#
        return folded.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func resolvedTitle(displayName: String, languageName: String?, isSDH: Bool) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !isGenericMediaGroupName(trimmed) {
            return trimmed
        }
        if let languageName {
            let lang = languageName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lang.isEmpty {
                if isSDH, !lang.localizedCaseInsensitiveContains("SDH") {
                    return "\(lang) SDH"
                }
                return lang
            }
        }
        if isSDH { return "SDH" }
        return "Captions"
    }

    static func languageName(locale: Locale?, extendedLanguageTag: String?) -> String? {
        if let locale {
            if let code = locale.language.languageCode?.identifier,
               let name = Locale.current.localizedString(forLanguageCode: code),
               !name.isEmpty {
                return name
            }
            let identifier = locale.identifier
            if let name = Locale.current.localizedString(forIdentifier: identifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty,
               name != identifier {
                return name
            }
        }
        if let tag = extendedLanguageTag, !tag.isEmpty {
            if let name = Locale.current.localizedString(forLanguageCode: tag), !name.isEmpty {
                return name
            }
            if let name = Locale.current.localizedString(forIdentifier: tag)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty,
               name != tag {
                return name
            }
        }
        return nil
    }

    static func stableID(
        index: Int,
        displayName: String,
        languageTag: String?,
        isSDH: Bool,
        isForced: Bool
    ) -> String {
        let tag = languageTag ?? ""
        return "\(index)|\(tag)|\(displayName)|\(isSDH ? "sdh" : "")|\(isForced ? "forced" : "")"
    }

    static func title(for option: AVMediaSelectionOption) -> String {
        let localized = option.displayName(with: .current)
        let raw = option.displayName
        let display: String = {
            let loc = localized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !loc.isEmpty, !isGenericMediaGroupName(loc) { return loc }
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty, !isGenericMediaGroupName(fallback) { return fallback }
            return loc.isEmpty ? fallback : loc
        }()
        let isSDH = option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
            && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
        return resolvedTitle(
            displayName: display,
            languageName: languageName(locale: option.locale, extendedLanguageTag: option.extendedLanguageTag),
            isSDH: isSDH
        )
    }

    static func id(for option: AVMediaSelectionOption, index: Int) -> String {
        let isSDH = option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
            && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
        let isForced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
        return stableID(
            index: index,
            displayName: option.displayName,
            languageTag: option.extendedLanguageTag,
            isSDH: isSDH,
            isForced: isForced
        )
    }
}
