import AVFoundation

/// The sound dictation starts with: two soft rising notes, synthesised
/// here so it's Lowtide's own and nothing like macOS's "not allowed"
/// tones. Made once, kept ready so it plays the instant you press.
enum Chime {
    private static let player: AVAudioPlayer? = {
        let player = try? AVAudioPlayer(data: wav())
        player?.volume = 0.6
        player?.prepareToPlay()
        return player
    }()

    /// Builds the sound ahead of the first dictation.
    static func prepare() {
        _ = player
    }

    /// Its audible part, plus the speaker-to-microphone delay: what's cut
    /// from the take so the model never hears it.
    static let audible = 0.3

    /// Plays it; returns when it started (`Clock` time), nil if it couldn't.
    @discardableResult
    static func play() -> UInt64? {
        guard let player else { return nil }
        player.currentTime = 0
        return player.play() ? Clock.now() : nil
    }

    /// E5 then B5, a fifth apart, each a quick pluck with a little warmth
    /// from its octave; the second overlaps the first.
    private static func wav() -> Data {
        let rate = 44_100.0
        let length = Int(rate * 0.32)
        var samples = [Float](repeating: 0, count: length)
        for (frequency, start) in [(659.25, 0.0), (987.77, 0.075)] {
            let first = Int(start * rate)
            for index in first..<length {
                let t = Double(index - first) / rate
                let attack = min(1, t / 0.006)
                let decay = exp(-t / 0.07)
                let tone = sin(2 * .pi * frequency * t) + 0.18 * sin(4 * .pi * frequency * t)
                samples[index] += Float(tone * attack * decay * 0.22)
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(length * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
