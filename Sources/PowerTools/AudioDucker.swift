import Foundation
import CoreAudio
import AudioToolbox

/// Mutes the default audio OUTPUT while you dictate, so a Zoom/Teams call (or
/// music) playing through the speakers can't leak into the microphone and land
/// in your transcript. Restores the exact prior state the moment recording
/// ends. No permissions involved — output control isn't TCC-gated.
@MainActor
final class AudioDucker {
    private var ducked = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var usedVolume = false
    private var previousMute: UInt32 = 0
    private var previousVolume: Float32 = 0

    func duck() {
        guard !ducked else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return }
        device = dev

        // Prefer the device's master mute switch (exact restore, no volume math).
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &muteAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(dev, &muteAddr, &settable) == noErr, settable.boolValue {
                size = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &size, &previousMute)
                var on: UInt32 = 1
                if AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &on) == noErr {
                    usedVolume = false
                    ducked = true
                    log("ducker: output muted for dictation")
                    return
                }
            }
        }

        // Fallback: zero the virtual main volume (some devices expose no mute).
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &volAddr, 0, nil, &size, &previousVolume) == noErr else { return }
        var zero: Float32 = 0
        if AudioObjectSetPropertyData(dev, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero) == noErr {
            usedVolume = true
            ducked = true
            log("ducker: output volume zeroed for dictation")
        }
    }

    func restore() {
        guard ducked else { return }
        ducked = false
        if usedVolume {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(device, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &previousVolume)
        } else {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &previousMute)
        }
        log("ducker: output restored")
    }
}
