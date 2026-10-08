// mic_arbiter.swift — who else is using the microphone, answered by the OS.
//
// The problem this solves (measured on macOS 26.5): an active VoiceProcessingIO
// unit on the built-in mic attenuates every OTHER reader of that device by ~40 dB,
// even with all voice processing bypassed. So if you join a Teams or Zoom call while
// Larmor holds the mic, the other side hears you "only at very high volume".
//
// The fix is to step aside, driven by the OS's own record of who is running input
// on the device: CoreAudio's Process Object API (macOS 14.2+), which pushes changes
// to a listener within ~80 ms. No polling, no app-name heuristics; works for Teams,
// Zoom, FaceTime, anything.

import CoreAudio
import Foundation

/// larmor_audio → caller: "another process needs this mic; I have stepped out."
let kYieldExit: Int32 = 75
/// caller → larmor_audio: "nobody else is on the mic any more; VPIO can come back."
let kReclaimExit: Int32 = 76

private func addr(_ sel: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultInputDeviceID() -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
    return id
}

func audioProcessObjects() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr,
          sz > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids
}

func processPID(_ obj: AudioObjectID) -> pid_t {
    var a = addr(kAudioProcessPropertyPID); var v: pid_t = 0; var sz = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v); return v
}

/// The devices this process currently has INPUT running on. Empty for taps
/// (replayd / ScreenCaptureKit) and for processes with a dormant stream —
/// which is exactly why we key on this rather than on IsRunningInput alone.
func processInputDevices(_ obj: AudioObjectID) -> [AudioObjectID] {
    var a = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &ids); return ids
}

func processLabel(_ obj: AudioObjectID) -> String {
    let pid = processPID(obj)
    var a = addr(kAudioProcessPropertyBundleID)
    var cf: Unmanaged<CFString>? = nil; var sz = UInt32(MemoryLayout<CFString?>.size)
    if AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &cf) == noErr,
       let s = cf?.takeRetainedValue(), (s as String).isEmpty == false {
        return "\(s as String)(\(pid))"
    }
    return "pid \(pid)"
}

/// Every process OTHER than us with input running on `device`.
func foreignInputUsers(on device: AudioObjectID) -> [String] {
    let me = getpid()
    return audioProcessObjects().compactMap { obj in
        guard processPID(obj) != me, processInputDevices(obj).contains(device) else { return nil }
        return processLabel(obj)
    }
}

/// Watches the process list and each process's input devices; calls `onChange`
/// with the current foreign-user set whenever anything relevant moves.
final class MicArbiter {
    let device: AudioObjectID
    let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "larmor.mic.arbiter")
    private var watched = Set<AudioObjectID>()
    private var last: [String]? = nil

    init(device: AudioObjectID, onChange: @escaping ([String]) -> Void) {
        self.device = device; self.onChange = onChange
    }

    func start() {
        var la = addr(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &la, queue) { [weak self] _, _ in
            guard let self = self else { return }
            audioProcessObjects().forEach(self.watch)
            self.recompute()
        }
        audioProcessObjects().forEach(watch)
        queue.async { self.recompute() }
    }

    private func watch(_ obj: AudioObjectID) {
        if watched.contains(obj) { return }
        watched.insert(obj)
        var d = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
        AudioObjectAddPropertyListenerBlock(obj, &d, queue) { [weak self] _, _ in self?.recompute() }
        var r = addr(kAudioProcessPropertyIsRunningInput)
        AudioObjectAddPropertyListenerBlock(obj, &r, queue) { [weak self] _, _ in self?.recompute() }
    }

    private func recompute() {
        let now = foreignInputUsers(on: device)
        if now != last { last = now; onChange(now) }
    }
}
