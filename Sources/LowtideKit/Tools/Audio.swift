import CoreAudio
import os
import Foundation

/// Sound outputs, the output volume, and the microphone, through CoreAudio.
public enum Sound {
    /// One sound output device.
    public struct Output: Sendable, Identifiable, Equatable {
        public let id: AudioObjectID
        public let name: String
        public let isCurrent: Bool
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) -> T? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func setProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> Bool {
        var address = address(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue else { return false }
        return withUnsafeBytes(of: value) { bytes in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!) == noErr
        }
    }

    private static func name(_ device: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func devices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// The device sound plays through now.
    public static var currentOutput: AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
    }

    /// Every sound output, without the hidden aggregate devices some apps make.
    public static func outputs() -> [Output] {
        let current = currentOutput
        return devices()
            .filter(hasOutputStreams)
            .filter { property($0, kAudioDevicePropertyTransportType, as: UInt32.self) != kAudioDeviceTransportTypeAggregate }
            .compactMap { id in name(id).map { Output(id: id, name: $0, isCurrent: id == current) } }
    }

    /// Makes `id` the sound output, and alert sounds follow it.
    public static func selectOutput(_ id: AudioObjectID) throws {
        guard outputs().contains(where: { $0.id == id }) else { throw LowtideError.notFound("That sound output") }
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard setProperty(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, id) else {
            throw LowtideError.denied("macOS wouldn't switch the sound output.")
        }
        _ = setProperty(system, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, id)
        Tools.changed()
    }

    /// The output's volume, 0–1; nil when the device has no volume of its
    /// own (HDMI, some interfaces).
    public static var volume: Double? {
        guard let device = currentOutput else { return nil }
        if let main = property(device, virtualMainVolume, kAudioObjectPropertyScopeOutput, as: Float32.self) { return Double(main) }
        return property(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, as: Float32.self).map(Double.init)
    }

    /// Sets the output volume, 0–1 (unmutes when raised above 0).
    public static func setVolume(_ level: Double) throws {
        guard let device = currentOutput else { throw LowtideError.notFound("A sound output") }
        let value = Float32(min(max(level, 0), 1))
        guard setProperty(device, virtualMainVolume, kAudioObjectPropertyScopeOutput, value)
            || setProperty(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, value)
        else { throw LowtideError.denied("This sound output doesn't let its volume be changed.") }
        if value > 0, isMuted == true { try? setMuted(false) }
        Tools.changed()
    }

    public static var isMuted: Bool? {
        guard let device = currentOutput else { return nil }
        return property(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, as: UInt32.self).map { $0 != 0 }
    }

    public static func setMuted(_ muted: Bool) throws {
        guard let device = currentOutput,
              setProperty(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(muted ? 1 : 0))
        else { throw LowtideError.denied("This sound output can't be muted.") }
        Tools.changed()
    }

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc'): the
    /// volume the menu bar slider moves, across channels.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766d_7663

    // MARK: Microphone

    /// The input level before muting, to put back on unmute.
    private static let before = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// The microphone's input volume, 0–100.
    public static func inputVolume() async -> Int? {
        let out = try? await Shell.run("/usr/bin/osascript", ["-e", "input volume of (get volume settings)"], timeout: .seconds(5))
        return out.flatMap { Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func setInputVolume(_ level: Int) async throws {
        let out = try await Shell.run("/usr/bin/osascript", ["-e", "set volume input volume \(min(max(level, 0), 100))"],
                                      timeout: .seconds(5))
        guard out.ok else { throw LowtideError.denied("macOS wouldn't change the microphone level.") }
    }

    public static func isMicrophoneMuted() async -> Bool { await inputVolume() == 0 }

    /// Mutes the microphone, or brings it back to where it was. Returns
    /// whether it's muted now.
    @discardableResult
    public static func toggleMicrophone() async throws -> Bool {
        let now = await inputVolume() ?? 0
        if now == 0 {
            let back = before.withLock { value in defer { value = nil }; return value }
            try await setInputVolume(back.flatMap { $0 > 0 ? $0 : nil } ?? 75)
            Tools.changed()
            return false
        }
        before.withLock { $0 = now }
        try await setInputVolume(0)
        Tools.changed()
        return true
    }
}
