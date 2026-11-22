import AVFoundation
import QuartzCore
import CoreAudio
import Foundation

/// The microphone, as 16 kHz mono floats on a timeline (`Clock` time), so a
/// take can start before the press and end a little after the release.
///
/// Kept ready (the default), the stream stays open between takes and only
/// the last second is held, in memory, for the pre-roll; macOS shows its
/// orange dot the whole time. Otherwise it opens on the press and closes
/// after the take. Either way it opens off the main thread, retries, and
/// follows device changes (ideas from Hex's `audio.rs`, MIT).
final class Microphone: @unchecked Sendable {
    static let rate = 16_000.0
    /// Audio kept from before the press: the first syllable often comes
    /// with it.
    static let preRoll = 0.45
    /// After the release: the end of the last word. Grows while speech
    /// carries on, up to `maxTail`.
    static let tail = 0.2
    static let maxTail = 0.6
    /// Held while idle, for the pre-roll.
    private static let ring = 1.0

    /// Loudness, 0…1, for the overlay: at most 30 times a second, from the
    /// audio thread, during a take only.
    var onLevel: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "voice.mic", qos: .userInitiated)
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Microphone.rate, channels: 1, interleaved: false)!

    // The queue's own.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var device: String?
    private var avoidBluetooth = true
    private var keepOpen = false
    /// The default input or the device list changed during a take.
    private var stale = false
    private var openedAt: UInt64 = 0

    // Under `lock`: the audio thread writes, everyone reads.
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Absolute index of `samples[0]`.
    private var base: Int64 = 0
    /// When one absolute index was heard.
    private var anchor: (index: Int64, at: UInt64)?
    /// Where the take in progress starts; nil between takes.
    private var keepFrom: Int64?
    /// Where the last take ended: the next one's pre-roll stops there, or
    /// its first words would be the end of the last take again.
    private var lastEnd: Int64 = 0
    /// Stretches cut from the take (the start chime).
    private var excluded: [(UInt64, UInt64)] = []
    private var lastBufferAt: UInt64 = 0
    private var levelAt = 0.0

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            address.mSelector = selector
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) {
                [weak self] _, _ in self?.devicesChanged()
            }
        }
        // A stream that delivers nothing (a device gone to sleep, a Bluetooth
        // profile switch) is reopened.
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in self?.checkStream() }
        watchdog.resume()
        self.watchdog = watchdog
    }

    private var watchdog: DispatchSourceTimer?

    // MARK: Settings

    /// `keepOpen` is "keep the microphone ready" and dictation on.
    func configure(device: String?, avoidBluetooth: Bool, keepOpen: Bool) {
        queue.async { [self] in
            let changed = device != self.device || avoidBluetooth != self.avoidBluetooth
            self.device = device
            self.avoidBluetooth = avoidBluetooth
            self.keepOpen = keepOpen
            if !keepOpen, !inTake { close("idle") }
            if changed, engine != nil, !inTake { close("device changed") }
            if keepOpen, engine == nil { try? open() }
        }
    }

    private var inTake: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keepFrom != nil
    }

    // MARK: Takes

    /// Starts a take at `press`, with the pre-roll when the stream was
    /// already open. `ready` runs on the main thread, with an error message
    /// when no microphone would open.
    func begin(at press: UInt64, ready: @escaping (String?) -> Void) {
        queue.async { [self] in
            var failure: String?
            if engine == nil {
                do { try open() } catch { failure = error.localizedDescription }
            }
            if failure == nil {
                lock.lock()
                let end = base + Int64(samples.count)
                let from = anchor.map { index(at: press &- UInt64(Microphone.preRoll * 1e9), $0) } ?? end
                keepFrom = min(end, max(base, from, lastEnd))
                excluded = []
                lock.unlock()
            }
            DispatchQueue.main.async { ready(failure) }
        }
    }

    /// Leaves `from…to` out of the take (what the microphone heard of the chime).
    func exclude(from: UInt64, to: UInt64) {
        lock.lock()
        excluded.append((from, to))
        lock.unlock()
    }

    /// Seconds in the take so far.
    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let keepFrom else { return 0 }
        return Double(base + Int64(samples.count) - keepFrom) / Microphone.rate
    }

    /// The take so far, or its last `seconds`.
    func snapshot(last seconds: Double? = nil) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var take = slice(to: base + Int64(samples.count))
        if let seconds, take.count > Int(seconds * Microphone.rate) {
            take = Array(take.suffix(Int(seconds * Microphone.rate)))
        }
        return take
    }

    /// Ends the take. With `release`, waits for the audio through the tail
    /// (longer while speech runs into it, bounded if the stream stalls);
    /// without, ends at once. `done` runs on the main thread with the take,
    /// which is all that's kept of it.
    func end(at release: UInt64?, done: @escaping ([Float]) -> Void) {
        guard let release else {
            finishTake(through: nil, done: done)
            return
        }
        let started = Clock.now()
        var tail = Microphone.tail
        let floor = noiseFloor()
        func check() {
            lock.lock()
            let written = base + Int64(samples.count)
            let goal = anchor.map { index(at: release + UInt64(tail * 1e9), $0) } ?? written
            let arrived = written >= goal
            let speaking = arrived && level(endingAt: goal) > floor + 12
            lock.unlock()
            let waited = Clock.seconds(started, Clock.now())
            if arrived, speaking, tail < Microphone.maxTail {
                tail = min(Microphone.maxTail, tail + 0.1)
            } else if arrived || waited > tail + 0.1 {
                Log.event("tail", ["ms": Int(tail * 1000), "waitedMs": Int(waited * 1000), "complete": arrived])
                finishTake(through: goal, done: done)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
        }
        check()
    }

    private func finishTake(through goal: Int64?, done: @escaping ([Float]) -> Void) {
        lock.lock()
        let through = goal ?? base + Int64(samples.count)
        let take = slice(to: through)
        lastEnd = max(lastEnd, through)
        keepFrom = nil
        excluded = []
        lock.unlock()
        queue.async { [self] in
            if !keepOpen {
                close("take ended")
            } else if stale {
                close("device changed")
                try? open()
            }
            stale = false
        }
        done(take)
    }

    // MARK: Buffer (under `lock`)

    private func index(at time: UInt64, _ anchor: (index: Int64, at: UInt64)) -> Int64 {
        anchor.index + Int64((Double(Int64(bitPattern: time &- anchor.at))) / 1e9 * Microphone.rate)
    }

    private func slice(to end: Int64) -> [Float] {
        guard let keepFrom else { return [] }
        let start = Int(max(0, keepFrom - base))
        let stop = Int(min(Int64(samples.count), max(keepFrom, end) - base))
        guard start < stop else { return [] }
        guard let anchor, !excluded.isEmpty else { return Array(samples[start..<stop]) }
        var keep = [Float]()
        keep.reserveCapacity(stop - start)
        var cursor = start
        for (from, to) in excluded.sorted(by: { $0.0 < $1.0 }) {
            let cutFrom = Int(min(Int64(stop), max(Int64(cursor), index(at: from, anchor) - base)))
            let cutTo = Int(min(Int64(stop), max(Int64(cutFrom), index(at: to, anchor) - base)))
            keep.append(contentsOf: samples[cursor..<cutFrom])
            cursor = cutTo
        }
        keep.append(contentsOf: samples[cursor..<stop])
        return keep
    }

    /// dBFS of the 100 ms ending at `end`.
    private func level(endingAt end: Int64) -> Float {
        let stop = Int(min(Int64(samples.count), end - base))
        let start = max(0, stop - Int(Microphone.rate * 0.1))
        guard start < stop else { return -100 }
        return Audio.decibels(samples[start..<stop])
    }

    /// The quieter end of the take's 20 ms frames, to tell speech from room.
    private func noiseFloor() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard let keepFrom else { return -100 }
        let frame = Int(Microphone.rate * 0.02)
        var levels = [Float]()
        var start = Int(max(0, keepFrom - base))
        while start + frame <= samples.count {
            levels.append(Audio.decibels(samples[start..<start + frame]))
            start += frame
        }
        guard !levels.isEmpty else { return -100 }
        return levels.sorted()[levels.count / 5]
    }

    private func take(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, converter: AVAudioConverter, ratio: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        let now = Clock.now()
        let heard = when.isHostTimeValid ? Clock.nanos(ticks: when.hostTime) ?? now : now
        lock.lock()
        anchor = (base + Int64(samples.count), heard)
        samples.append(contentsOf: chunk)
        lastBufferAt = now
        let taking = keepFrom != nil
        if !taking, samples.count > Int(Microphone.rate * Microphone.ring * 1.5) {
            let drop = samples.count - Int(Microphone.rate * Microphone.ring)
            samples.removeFirst(drop)
            base += Int64(drop)
        }
        lock.unlock()
        let media = CACurrentMediaTime()
        if taking, media - levelAt > 1.0 / 30 {
            levelAt = media
            onLevel?(Audio.level(chunk))
        }
    }

    // MARK: Engine (on `queue`)

    /// The chosen microphone, two more tries 100 ms apart, then the
    /// system's default.
    private func open() throws {
        let wanted = chosen()
        var failure: Error = VoiceError("No microphone is available.")
        for attempt in 0..<3 {
            do {
                try start(wanted)
                return
            } catch {
                failure = error
                Log.event("mic", ["action": "open-failed", "attempt": attempt, "error": error.localizedDescription])
                usleep(100_000)
            }
        }
        if wanted != nil {
            do {
                try start(nil)
                Log.event("mic", ["action": "fallback-default"])
                return
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// A picked microphone, else the built-in one standing in for a
    /// Bluetooth default (headset mics are narrowband and slow to wake), else
    /// nil for the default.
    private func chosen() -> AudioDeviceID? {
        if let device, let id = Devices.id(for: device) { return id }
        guard avoidBluetooth, let current = Devices.defaultID(), Devices.isBluetooth(current) else { return nil }
        return Devices.builtIn()
    }

    private func start(_ device: AudioDeviceID?) throws {
        let began = Clock.now()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw VoiceError("The microphone couldn't be selected.") }
        }
        // A format read mid-change makes `installTap` raise an Objective-C
        // exception, which Swift can't catch: check it first.
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              format.sampleRate > 0, format.channelCount > 0
        else { throw VoiceError("No microphone is available.") }
        guard format.sampleRate == hardware.sampleRate else {
            throw VoiceError("The microphone was changing; try again.")
        }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw VoiceError("The microphone's format isn't supported.")
        }
        let ratio = Microphone.rate / format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            self?.take(buffer, when: when, converter: converter, ratio: ratio)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceError("The microphone couldn't start: \(error.localizedDescription)")
        }
        // The engine stops itself when its device's format changes. Opening a
        // picked microphone while the output is Bluetooth posts a change
        // right after every start; restarting on each one looped forever
        // (close, open, change, close…). Only a stopped engine is reopened,
        // and not sooner than a second after the last open.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.configurationChanged(engine) }
        }
        self.engine = engine
        openedAt = Clock.now()
        lock.lock()
        lastBufferAt = openedAt
        lock.unlock()
        Log.event("mic", [
            "action": "open", "device": device.flatMap(Devices.name) ?? "default",
            "rate": format.sampleRate, "channels": Int(format.channelCount),
            "ms": Int(Clock.seconds(began, openedAt) * 1000),
        ])
    }

    private func close(_ reason: String) {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        self.engine = nil
        lock.lock()
        anchor = nil
        if keepFrom == nil {
            samples = []
            base = 0
            lastEnd = 0
        }
        lock.unlock()
        Log.event("mic", ["action": "close", "reason": reason])
    }

    private func restart(_ reason: String) {
        guard engine != nil else { return }
        close(reason)
        if keepOpen || inTake {
            do { try open() } catch {
                Log.event("mic", ["action": "reopen-failed", "error": error.localizedDescription])
            }
        }
    }

    private func configurationChanged(_ changed: AVAudioEngine) {
        guard changed === engine, !changed.isRunning else { return }
        let wait = 1 - Clock.seconds(openedAt, Clock.now())
        guard wait <= 0 else {
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.configurationChanged(changed) }
            return
        }
        restart("configuration changed")
    }

    /// Plugged in, unplugged, a new default: picked up now when idle, after
    /// the take otherwise.
    private func devicesChanged() {
        guard engine != nil else { return }
        if inTake {
            stale = true
        } else {
            restart("devices changed")
        }
    }

    /// Reopens a stream that delivers only zeros.
    func reopen() {
        queue.async { [self] in
            guard !inTake else { return }
            restart("digital silence")
        }
    }

    private func checkStream() {
        guard engine != nil else { return }
        lock.lock()
        let quiet = Clock.seconds(lastBufferAt, Clock.now())
        lock.unlock()
        if quiet > 4 { restart("no audio for 4 s") }
    }
}

enum Audio {
    static func decibels<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return -100 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(max(power, 1e-10))
    }

    /// RMS mapped from -55…0 dBFS onto 0…1.
    static func level<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        min(1, max(0, (decibels(samples) + 55) / 55))
    }

    /// True when nothing above a whisper was recorded.
    /// No voice in the take: its loudest 30 ms (DC removed) stays under
    /// -50 dBFS. Given silence, models make words up (or read back the
    /// vocabulary), so such a take never reaches one (Hex's
    /// `is_near_silent`, MIT).
    static func silent(_ samples: [Float]) -> Bool {
        let window = 480
        var loudest: Float = 0
        var start = 0
        while start < samples.count {
            let frame = samples[start..<min(start + window, samples.count)]
            let mean = frame.reduce(0, +) / Float(frame.count)
            let power = frame.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(frame.count)
            loudest = max(loudest, power)
            start += window
        }
        return 10 * log10(max(loudest, 1e-12)) < -50
    }

    /// Every sample exactly zero: not a quiet room but a stream gone dead
    /// (a call app holding the device, a muted input).
    static func dead(_ samples: [Float]) -> Bool {
        !samples.isEmpty && samples.allSatisfy { $0 == 0 }
    }

    /// Any audio file, as 16 kHz mono floats.
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Microphone.rate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw VoiceError("Unsupported audio file.") }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * Microphone.rate / file.processingFormat.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw VoiceError("Unsupported audio file.")
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
/// The Mac's microphones.
enum Devices {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func defaultUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func id(for uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }
}

extension Devices {
    static func defaultID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0
        else { return nil }
        return id
    }

    static func name(_ id: AudioDeviceID) -> String? {
        all().first { $0.id == id }?.name
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let kind = transport(id)
        return kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own microphone, when it has one (a closed lid hides it).
    static func builtIn() -> AudioDeviceID? {
        all().first { transport($0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
    }
}
