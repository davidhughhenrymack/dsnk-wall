import Foundation
import QuartzCore

/// Shows / hides the VHS MP4 on a GIF-like schedule: independent phase & RNG, ~2× on-time.
final class VideoPresence {
    private var nextShowAt: CFTimeInterval = 0
    private var hideAt: CFTimeInterval = 0
    private var showStart: CFTimeInterval = 0
    private var active = false
    private var beatsSeen = 0
    private var prevBeatPulse: Float = 0

    /// 0…1 fade-aware opacity for the video plate.
    private(set) var opacity: Float = 0

    init() {
        // Off-phase from GIF first appearance (GIFs use ~1.5…4s).
        nextShowAt = CACurrentMediaTime() + Double.random(in: 5.0...11.0)
    }

    func update(time now: CFTimeInterval, beatPulse: Float) {
        if active {
            let thresh = Config.videoPresenceBeatThreshold
            if beatPulse > thresh && prevBeatPulse <= thresh {
                beatsSeen += 1
                if beatsSeen >= Config.videoPresenceBeatCount {
                    let fade = Double(Config.videoPresenceFade)
                    hideAt = min(hideAt, now + fade)
                }
            }
            prevBeatPulse = beatPulse

            if now >= hideAt {
                active = false
                opacity = 0
                beatsSeen = 0
                prevBeatPulse = 0
                nextShowAt = now + Double.random(
                    in: Double(Config.videoPresenceMinGap)...Double(Config.videoPresenceMaxGap)
                )
                return
            }

            let showDur = hideAt - showStart
            let local = now - showStart
            let fade = Double(Config.videoPresenceFade)
            var o = 1.0
            if local < fade { o = local / max(fade, 0.001) }
            else if local > showDur - fade { o = (hideAt - now) / max(fade, 0.001) }
            opacity = Float(max(0, min(1, o)))
            return
        }

        opacity = 0
        prevBeatPulse = beatPulse
        guard now >= nextShowAt else { return }

        active = true
        showStart = now
        hideAt = now + Double(Config.videoPresenceMaxDuration)
        beatsSeen = 0
        prevBeatPulse = beatPulse
        opacity = 0
    }
}
