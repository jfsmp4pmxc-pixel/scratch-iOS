import AVFoundation
import ScratchCore

/// Phát âm thanh của project bằng AVAudioPlayer.
final class AudioPlayer: NSObject, SoundPlaying, AVAudioPlayerDelegate {
    private let project: Project
    private var active: [ObjectIdentifier: (player: AVAudioPlayer, done: () -> Void)] = [:]

    init(project: Project) {
        self.project = project
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func play(_ sound: Sound, volume: Double, completion: @escaping () -> Void) {
        guard let data = project.assets[sound.md5ext],
              let player = try? AVAudioPlayer(data: data) else {
            completion()      // định dạng không phát được: không chặn script
            return
        }
        player.delegate = self
        player.volume = Float(max(0, min(100, volume)) / 100)
        active[ObjectIdentifier(player)] = (player, completion)
        if !player.play() {
            active.removeValue(forKey: ObjectIdentifier(player))
            completion()
        }
    }

    func stopAll() {
        let pending = active
        active.removeAll()
        for (_, item) in pending {
            item.player.stop()
            item.done()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let item = active.removeValue(forKey: ObjectIdentifier(player)) { item.done() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let item = active.removeValue(forKey: ObjectIdentifier(player)) { item.done() }
    }
}
