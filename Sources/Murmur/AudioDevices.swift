import CoreAudio
import Foundation

/// A microphone as CoreAudio sees it.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// CoreAudio input-device enumeration and the user's microphone preference.
///
/// Murmur never changes the system default input. It records from the
/// built-in microphone unless the user picks another device, so that opening
/// the mic never drags a Bluetooth headset into its low-quality headset
/// profile (that is what makes playback sound washed out).
enum AudioDevices {
    static let preferenceKey = "MurmurInputDeviceUID"

    /// Empty means "built-in microphone (recommended)".
    static var preferredUID: String {
        get { UserDefaults.standard.string(forKey: preferenceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// The device Murmur should record from right now, resolving the
    /// preference against what is actually plugged in.
    static func resolveRecordingDevice() -> AudioInputDevice? {
        let devices = inputDevices()
        let preferred = preferredUID
        if !preferred.isEmpty, let match = devices.first(where: { $0.uid == preferred }) {
            return match
        }
        if let builtIn = devices.first(where: { $0.isBuiltIn }) {
            return builtIn
        }
        if let defaultID = systemDefaultInputID(),
            let match = devices.first(where: { $0.id == defaultID })
        {
            return match
        }
        return devices.first
    }

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0 else { return nil }
            guard let uid = stringProperty(of: id, kAudioDevicePropertyDeviceUID),
                let name = stringProperty(of: id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                transport: uint32Property(of: id, kAudioDevicePropertyTransportType) ?? 0)
        }
        .sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func systemDefaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// Calls `handler` on the main queue whenever a device is plugged in or
    /// removed. Returns a token that keeps the listener alive.
    static func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        let token = ListenerToken(handler: handler)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, token.block)
        return token
    }

    private final class ListenerToken {
        let block: AudioObjectPropertyListenerBlock
        init(handler: @escaping @Sendable () -> Void) {
            block = { _, _ in handler() }
        }
        deinit {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        of id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
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

    private static func uint32Property(
        of id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
