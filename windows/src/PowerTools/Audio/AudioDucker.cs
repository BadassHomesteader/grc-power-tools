using NAudio.CoreAudioApi;
using PowerTools.Core;

namespace PowerTools.Audio;

/// <summary>
/// Mutes the default output device while dictating so a call or music playing
/// through the speakers can't bleed into the transcript — port of
/// AudioDucker.swift. Restores the previous mute state on release; if the
/// speakers were already muted, they stay muted afterwards.
/// </summary>
public sealed class AudioDucker
{
    private bool _active;
    private bool _wasMuted;

    public void Duck()
    {
        if (_active) return;
        try
        {
            using var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            _wasMuted = device.AudioEndpointVolume.Mute;
            device.AudioEndpointVolume.Mute = true;
            _active = true;
        }
        catch (Exception ex) { Logger.Log($"ducker: mute failed: {ex.Message}"); }
    }

    public void Restore()
    {
        if (!_active) return;
        _active = false;
        try
        {
            using var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            device.AudioEndpointVolume.Mute = _wasMuted;
        }
        catch (Exception ex) { Logger.Log($"ducker: restore failed: {ex.Message}"); }
    }
}
