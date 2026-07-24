using NAudio.CoreAudioApi;
using NAudio.Wave;
using PowerTools.Asr;
using PowerTools.Core;

namespace PowerTools.Audio;

/// <summary>
/// Always-warm WASAPI mic capture with a pre-roll ring buffer — port of
/// AudioCapture.swift. The mic stream runs continuously; StartUtterance()
/// seeds the utterance with the last `preRollSeconds` of audio so the first
/// syllable spoken while the key travels down is never lost.
/// Samples are kept at device rate (mono float) and resampled to 16 kHz once,
/// at StopUtterance().
/// </summary>
public sealed class AudioCapture : IDisposable
{
    private WasapiCapture? _capture;
    private readonly object _gate = new();

    private float[] _ring = Array.Empty<float>();
    private int _ringWrite;
    private bool _ringFull;
    private List<float>? _utterance;
    private int _deviceRate = 48000;
    private readonly double _preRollSeconds;
    private readonly int _maxUtteranceSeconds;

    /// <summary>Most recent RMS level (0..1), for the overlay meter.</summary>
    public float Level { get; private set; }

    public AudioCapture(double preRollSeconds, int maxUtteranceSeconds)
    {
        _preRollSeconds = preRollSeconds;
        _maxUtteranceSeconds = maxUtteranceSeconds;
    }

    public bool Start()
    {
        try
        {
            var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            _capture = new WasapiCapture(device);
            _deviceRate = _capture.WaveFormat.SampleRate;
            _ring = new float[(int)(_deviceRate * _preRollSeconds)];
            _capture.DataAvailable += OnData;
            _capture.RecordingStopped += (_, e) =>
            {
                if (e.Exception is not null) Logger.Log($"audio: capture stopped: {e.Exception.Message}");
            };
            _capture.StartRecording();
            Logger.Log($"audio: warm capture started ({device.FriendlyName}, {_deviceRate} Hz, {_capture.WaveFormat.Channels}ch)");
            return true;
        }
        catch (Exception ex)
        {
            Logger.Log($"audio: failed to start capture: {ex.Message}");
            return false;
        }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        var format = _capture!.WaveFormat;
        var channels = format.Channels;
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat;
        var bytesPerSample = format.BitsPerSample / 8;
        var frames = e.BytesRecorded / (bytesPerSample * channels);
        if (frames <= 0) return;

        var mono = new float[frames];
        for (var i = 0; i < frames; i++)
        {
            var sum = 0f;
            for (var ch = 0; ch < channels; ch++)
            {
                var off = (i * channels + ch) * bytesPerSample;
                sum += isFloat
                    ? BitConverter.ToSingle(e.Buffer, off)
                    : BitConverter.ToInt16(e.Buffer, off) / 32768f;
            }
            mono[i] = sum / channels;
        }

        var sq = 0f;
        foreach (var s in mono) sq += s * s;
        Level = MathF.Min(1f, MathF.Sqrt(sq / frames) * 4f);

        lock (_gate)
        {
            foreach (var s in mono)
            {
                _ring[_ringWrite] = s;
                _ringWrite = (_ringWrite + 1) % _ring.Length;
                if (_ringWrite == 0) _ringFull = true;
            }
            if (_utterance is not null && _utterance.Count < _deviceRate * _maxUtteranceSeconds)
                _utterance.AddRange(mono);
        }
    }

    /// <summary>Begin an utterance, seeded with the pre-roll ring content.</summary>
    public void StartUtterance()
    {
        lock (_gate)
        {
            var seed = new List<float>();
            if (_ringFull)
            {
                seed.AddRange(_ring[_ringWrite..]);
                seed.AddRange(_ring[.._ringWrite]);
            }
            else
            {
                seed.AddRange(_ring[.._ringWrite]);
            }
            _utterance = seed;
        }
    }

    /// <summary>End the utterance; returns mono 16 kHz samples (empty if not recording).</summary>
    public float[] StopUtterance()
    {
        List<float>? taken;
        lock (_gate)
        {
            taken = _utterance;
            _utterance = null;
        }
        if (taken is null || taken.Count == 0) return Array.Empty<float>();
        return WavFile.Resample(taken.ToArray(), _deviceRate, 16000);
    }

    public void CancelUtterance()
    {
        lock (_gate) _utterance = null;
    }

    public void Dispose()
    {
        try
        {
            _capture?.StopRecording();
            _capture?.Dispose();
        }
        catch { }
    }
}
