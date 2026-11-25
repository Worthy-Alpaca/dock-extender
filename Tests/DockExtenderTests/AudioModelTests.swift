import Foundation
import Testing
@testable import DockExtender

/// The audio widget's state as the views see it. Nothing here touches a real
/// output device: the model's link to it is replaced.
@MainActor
struct AudioModelTests {
    private func reading(volume: Double?, muted: Bool = false, sources: [AudioSource] = [], at time: TimeInterval = 100) -> AudioReading {
        var state = AudioState()
        state.volume = volume
        state.isMuted = muted
        state.sources = sources
        return AudioReading(state: state, time: time)
    }

    @Test func showsWhatTheDeviceReports() {
        let model = AudioModel()
        model.update(reading(volume: 0.5, muted: true))
        #expect(model.volume == 0.5)
        #expect(model.isMuted)
        #expect(model.volumeText == "Mute")

        model.update(reading(volume: 0.25))
        #expect(model.volumeText == "25%")
    }

    @Test func anOutputWithoutVolumeControlCannotBeSet() {
        let model = AudioModel()
        var sent: [Double] = []
        model.setOutputVolume = { sent.append($0) }
        model.update(reading(volume: nil))
        model.setVolume(0.8)
        #expect(sent.isEmpty)
        #expect(model.volume == nil)
        #expect(model.volumeText == "–")
    }

    @Test func aDraggedVolumeShowsAtOnceAndIsPassedOn() {
        let model = AudioModel()
        var sent: [Double] = []
        model.setOutputVolume = { sent.append($0) }
        model.update(reading(volume: 0.5, muted: true))

        model.setVolume(0.25)
        #expect(sent == [0.25])
        #expect(model.volumeText == "25%")
        // Setting the volume takes the output off mute.
        #expect(!model.isMuted)

        model.setVolume(1.7)
        model.setVolume(-0.3)
        #expect(sent == [0.25, 1, 0])
    }

    @Test func theDeviceTakesOverAgainOnceItHasCaughtUp() {
        let model = AudioModel()
        model.update(reading(volume: 0.5))
        model.setVolume(0.9)
        let now = ProcessInfo.processInfo.systemUptime

        // Still reporting the old value a moment later: the chosen one shows.
        model.update(reading(volume: 0.5, at: now))
        #expect(model.volume == 0.9)
        // Later, whatever the device says goes.
        model.update(reading(volume: 0.88, at: now + 5))
        #expect(model.volume == 0.88)
    }

    @Test func thePlayerUpFrontIsTheOneThatNamesItsTrack() {
        let browser = AudioSource(pid: 1, name: "Browser", since: 10)
        let player = AudioSource(pid: 2, name: "Player", since: 20, track: AudioTrack(title: "A Song"), player: "com.apple.Music")
        let model = AudioModel()
        model.update(reading(volume: 0.5, sources: [browser, player]))
        #expect(model.state.main == player)
        #expect(model.remote == player)
    }

    @Test func aPausedPlayerStepsBackForAnythingPlaying() {
        let paused = AudioSource(pid: 2, name: "Player", track: AudioTrack(title: "A Song"), player: "com.apple.Music", isPaused: true)
        let browser = AudioSource(pid: 1, name: "Browser", since: 10)
        let model = AudioModel()

        model.update(reading(volume: 0.5, sources: [paused]))
        #expect(model.state.main == paused)
        #expect(model.remote == paused)
        #expect(model.state.playing.isEmpty)

        // Something else plays: it is up front, and there is nothing to send commands to.
        model.update(reading(volume: 0.5, sources: [browser, paused]))
        #expect(model.state.main == browser)
        #expect(model.remote == nil)
    }
}
