namespace PowerTools.Asr;

/// <summary>
/// Minimal PCM16 WAV reader with resample-to-16k — enough for tests and file
/// transcription; live capture converts at the WASAPI layer instead.
/// </summary>
public static class WavFile
{
    /// <summary>Read a PCM16 WAV into mono float samples at 16 kHz.</summary>
    public static float[] ReadMono16k(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length < 44 || bytes[0] != 'R' || bytes[1] != 'I' || bytes[2] != 'F' || bytes[3] != 'F')
            throw new InvalidDataException("not a RIFF/WAV file");

        int channels = 1, sampleRate = 16000, bitsPerSample = 16;
        int dataOffset = -1, dataLength = 0;

        // Walk chunks: fmt then data (don't assume the canonical 44-byte header —
        // macOS `afconvert` and others insert extra chunks).
        var pos = 12;
        while (pos + 8 <= bytes.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(bytes, pos, 4);
            var size = BitConverter.ToInt32(bytes, pos + 4);
            if (id == "fmt ")
            {
                channels = BitConverter.ToInt16(bytes, pos + 10);
                sampleRate = BitConverter.ToInt32(bytes, pos + 12);
                bitsPerSample = BitConverter.ToInt16(bytes, pos + 22);
            }
            else if (id == "data")
            {
                dataOffset = pos + 8;
                dataLength = Math.Min(size, bytes.Length - dataOffset);
                break;
            }
            pos += 8 + size + (size % 2);
        }
        if (dataOffset < 0) throw new InvalidDataException("WAV has no data chunk");
        if (bitsPerSample != 16) throw new InvalidDataException($"expected PCM16, got {bitsPerSample}-bit");

        var frameCount = dataLength / 2 / channels;
        var mono = new float[frameCount];
        for (var i = 0; i < frameCount; i++)
        {
            var sum = 0f;
            for (var ch = 0; ch < channels; ch++)
                sum += BitConverter.ToInt16(bytes, dataOffset + (i * channels + ch) * 2) / 32768f;
            mono[i] = sum / channels;
        }
        return sampleRate == 16000 ? mono : Resample(mono, sampleRate, 16000);
    }

    /// <summary>Linear resampler — fine for speech into an ASR frontend.</summary>
    public static float[] Resample(float[] input, int fromRate, int toRate)
    {
        if (fromRate == toRate || input.Length == 0) return input;
        var outLen = (int)((long)input.Length * toRate / fromRate);
        var output = new float[outLen];
        var ratio = (double)fromRate / toRate;
        for (var i = 0; i < outLen; i++)
        {
            var src = i * ratio;
            var i0 = (int)src;
            var i1 = Math.Min(i0 + 1, input.Length - 1);
            var frac = (float)(src - i0);
            output[i] = input[i0] * (1 - frac) + input[i1] * frac;
        }
        return output;
    }
}
