import AppKit

/// A short falling blip for new events: louder and lower for an alert than
/// a notice. Synthesised once into WAV data; no sound files shipped.
enum NetworkSound {
    private static let alert = sound(from: 1320, to: 520, level: 0.24)
    private static let notice = sound(from: 1760, to: 1320, level: 0.1)

    static func ping(alert isAlert: Bool) {
        let sound = isAlert ? alert : notice
        sound?.stop()
        sound?.play()
    }

    /// A sine sweeping from `from` Hz to `to` Hz over 0.22 s with a quick
    /// attack and a 0.55 s decay, as 16-bit mono PCM.
    private static func sound(from: Double, to: Double, level: Double) -> NSSound? {
        let rate = 44_100.0
        let duration = 0.6
        let count = Int(rate * duration)
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            let frequency = t < 0.22 ? from * pow(to / from, t / 0.22) : to
            phase += 2 * .pi * frequency / rate
            let envelope = t < 0.012 ? t / 0.012 : exp(-(t - 0.012) * 9)
            samples[i] = Int16(max(-1, min(1, sin(phase) * envelope * level)) * Double(Int16.max))
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        samples.forEach { append($0) }
        return NSSound(data: data)
    }
}
