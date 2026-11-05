import Foundation

/// What Mimamori tells you at launch when it couldn't read all of `state.json`.
public struct StateNotice: Equatable, Sendable {
    public static let title = "Mimamori couldn't read all of its saved state"

    public var message: String
    /// What Show in Finder selects: the copy kept aside, or the file itself when none could be kept.
    public var file: URL
}

extension LoadedState {
    /// The notice for this load, or nil when the file read in full or wasn't there yet.
    public func notice(stateFile: URL) -> StateNotice? {
        guard problem != nil || keptAside != nil || fromPrevious else { return nil }

        let opened: String
        if fromPrevious {
            opened = "It opened what it saved the time before, so your latest changes may be missing."
        } else if state.schemaVersion > PersistedState.currentSchemaVersion {
            opened = "It was saved by a newer Mimamori, so this one opened what it could."
        } else {
            opened = "It opened what it could."
        }

        guard let keptAside else {
            let kept = "It couldn't keep a copy of the file, so it won't save over it, and changes you make now won't be saved."
            return StateNotice(message: opened + " " + kept, file: stateFile)
        }
        return StateNotice(message: opened + " It kept a copy of the file as it was.", file: keptAside)
    }
}
