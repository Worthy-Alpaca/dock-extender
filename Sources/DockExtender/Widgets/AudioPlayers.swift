import AppKit

/// What a player says it is playing.
struct AudioTrack: Sendable, Equatable {
    var title: String
    var artist = ""
    var album = ""
}

/// A player that is open, with what it last said about itself.
struct RemotePlayer: Sendable {
    var bundleID: String
    var pid: pid_t
    var name: String
    /// The track it last named, whether it is playing it or has it paused.
    var track: AudioTrack?
}

/// Follows the players that announce their tracks and take commands.
///
/// Music and Spotify post a system-wide notification whenever playback
/// starts, pauses or moves on, with the track's details attached. Listening
/// for those takes no permission and no polling. Every other app keeps its
/// titles to itself: macOS's own "Now Playing" information, which would cover
/// them all, is reserved for Apple's apps.
///
/// A notification only comes when something changes, so a track that was
/// already playing when this app started is unknown until then. To cover the
/// common case, a restart of this app, each playing track is kept on disk
/// until it must have ended.
///
/// Created, and notified, on the main thread; read from the sampling queue.
final class PlayerWatcher: NSObject, @unchecked Sendable {
    /// Notification name -> bundle ID of the player that posts it.
    private static let notifications = [
        "com.apple.Music.playerInfo": "com.apple.Music",
        "com.spotify.client.PlaybackStateChanged": "com.spotify.client",
    ]
    private static let storageKey = "audioTracks"
    /// How long a stored track is trusted when the player did not say how
    /// long the track is.
    private static let fallbackLifetime: TimeInterval = 60

    private let lock = NSLock()
    /// Bundle ID -> the track last named. Guarded by `lock`.
    private var tracks: [String: AudioTrack] = [:]
    /// Bundle ID -> the running player. Guarded by `lock`.
    private var running: [String: (pid: pid_t, name: String)] = [:]
    /// Bundle ID -> when the track it is playing is over at the latest.
    /// Main thread only.
    private var ends: [String: Date] = [:]

    override init() {
        super.init()
        restore()
        for name in Self.notifications.keys {
            // Deliver immediately: by default these are held back until the
            // app is frontmost, which this app never is.
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(playerChanged(_:)),
                name: Notification.Name(name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }

        // Which of the players are open, kept current without polling.
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications {
            note(app, isRunning: true)
        }
        workspace.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        workspace.notificationCenter.addObserver(
            self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
    }

    /// The players that are open right now.
    func players() -> [RemotePlayer] {
        lock.lock()
        defer { lock.unlock() }
        return running
            .map { RemotePlayer(bundleID: $0.key, pid: $0.value.pid, name: $0.value.name, track: tracks[$0.key]) }
            .sorted { $0.bundleID < $1.bundleID }
    }

    // MARK: Running players

    @objc private func appLaunched(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            note(app, isRunning: true)
        }
    }

    @objc private func appQuit(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            note(app, isRunning: false)
        }
    }

    private func note(_ app: NSRunningApplication, isRunning: Bool) {
        guard let player = app.bundleIdentifier, Self.notifications.values.contains(player) else { return }
        lock.lock()
        if isRunning {
            running[player] = (app.processIdentifier, app.localizedName ?? player)
        } else {
            running[player] = nil
            tracks[player] = nil
        }
        lock.unlock()
    }

    // MARK: Tracks

    @objc private func playerChanged(_ notification: Notification) {
        guard let player = Self.notifications[notification.name.rawValue] else { return }
        let info = notification.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""

        // A paused player still names its track; a stopped one has none.
        var track: AudioTrack?
        if state == "Playing" || state == "Paused", let title = info["Name"] as? String, !title.isEmpty {
            track = AudioTrack(
                title: title,
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? ""
            )
        }
        Log.debug("\(player) is \(state.lowercased())\(track.map { ": \"\($0.title)\" by \($0.artist)" } ?? "")")

        // Music gives the length as "Total Time", Spotify as "Duration", both
        // in milliseconds. Playback may have resumed part-way, so the track
        // ends no later than a full length from now.
        if state == "Playing", track != nil {
            let length = ((info["Total Time"] ?? info["Duration"]) as? NSNumber)?.doubleValue ?? 0
            ends[player] = Date().addingTimeInterval(length > 0 ? length / 1000 : Self.fallbackLifetime)
        } else {
            ends[player] = nil
        }

        lock.lock()
        tracks[player] = track
        let all = tracks
        lock.unlock()
        store(all)
    }

    /// Keeps the tracks that are playing; a paused one is not worth
    /// remembering across a restart.
    private func store(_ tracks: [String: AudioTrack]) {
        var stored: [String: Any] = [:]
        for (player, track) in tracks {
            guard let end = ends[player] else { continue }
            stored[player] = ["title": track.title, "artist": track.artist, "album": track.album, "ends": end] as [String: Any]
        }
        UserDefaults.standard.set(stored, forKey: Self.storageKey)
    }

    private func restore() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) ?? [:]
        for player in Self.notifications.values {
            guard let fields = stored[player] as? [String: Any],
                  let title = fields["title"] as? String,
                  let end = fields["ends"] as? Date, end > Date()
            else { continue }
            tracks[player] = AudioTrack(
                title: title,
                artist: fields["artist"] as? String ?? "",
                album: fields["album"] as? String ?? ""
            )
            ends[player] = end
        }
    }
}

/// In the order the buttons are laid out.
enum PlayerCommand: Sendable, CaseIterable {
    case previous, playPause, next
}

/// Tells a player to play, pause or skip.
///
/// The command goes out as an Apple event, the same thing the AppleScript
/// `tell application "Music" to playpause` sends. macOS asks the user, the
/// first time, whether this app may control that player; the answer is kept
/// under System Settings › Privacy & Security › Automation.
///
/// (The media keys would reach any player, but an app may only press keys
/// for the user with the Accessibility permission, which opens up the whole
/// machine. This asks for one app.)
enum PlayerRemote {
    enum Outcome: Sendable {
        case sent
        /// The user has not allowed this app to control the player.
        case notAllowed
        case failed
    }

    private static let queue = DispatchQueue(label: "DockExtender.player-remote", qos: .userInitiated)
    /// "The user has declined permission", from the Apple Event Manager.
    private static let notPermitted: OSStatus = -1743

    static func canControl(_ bundleID: String) -> Bool {
        suite(of: bundleID) != nil
    }

    /// Sends `command` to the player running as `pid`. Never blocks the
    /// caller: asking for permission waits for the user's answer.
    static func send(
        _ command: PlayerCommand,
        to bundleID: String,
        pid: pid_t,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        guard let suite = suite(of: bundleID) else {
            completion(.failed)
            return
        }
        let event = code(event(for: command, player: bundleID))
        queue.async {
            // Addressed by process, so that a player which has just quit is
            // not launched again by the command.
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, suite, event, true)
            guard permission == noErr else {
                Log.debug("no permission to control \(bundleID): \(permission)")
                completion(permission == notPermitted ? .notAllowed : .failed)
                return
            }
            let message = NSAppleEventDescriptor(
                eventClass: suite,
                eventID: event,
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            do {
                _ = try message.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
                completion(.sent)
            } catch {
                Log.debug("\(bundleID) did not take the command: \(error)")
                completion((error as NSError).code == Int(notPermitted) ? .notAllowed : .failed)
            }
        }
    }

    // The codes come from the players' scripting dictionaries.

    private static func suite(of bundleID: String) -> AEEventClass? {
        switch bundleID {
        case "com.apple.Music": return code("hook")
        case "com.spotify.client": return code("spfy")
        default: return nil
        }
    }

    private static func event(for command: PlayerCommand, player: String) -> String {
        switch command {
        case .playPause: return "PlPs"
        case .next: return "Next"
        // Music's "back track" does what its own button does: to the start of
        // the track first, to the previous track from there.
        case .previous: return player == "com.apple.Music" ? "Back" : "Prev"
        }
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
