using System.Net.Http;
using SherpaOnnx;
using PowerTools.Core;

namespace PowerTools.Asr;

/// <summary>
/// Local Parakeet-TDT ASR via sherpa-onnx — the Windows replacement for the
/// Mac app's vendored FluidAudio/CoreML engine. Same model family (Parakeet
/// TDT 0.6b v3, multilingual), int8 ONNX export, downloaded from HuggingFace
/// on first use exactly like the Mac app downloads its CoreML build.
///
/// Platform-neutral on purpose: sherpa-onnx ships native libs for Windows,
/// macOS, and Linux, so the engine is exercised end-to-end by tests on any
/// dev machine — only audio capture and paste are Windows-bound.
/// </summary>
public sealed class ParakeetEngine : IDisposable
{
    private const string HfRepo = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";
    private static readonly string[] ModelFiles = { "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt" };

    public static string ModelDir => Path.Combine(Paths.AppSupportDir, "models", "parakeet-tdt-0.6b-v3-int8");

    private OfflineRecognizer? _recognizer;
    private readonly object _gate = new();

    public static bool ModelsPresent => ModelFiles.All(f => File.Exists(Path.Combine(ModelDir, f)));

    /// <summary>
    /// Download any missing model files (~700 MB total on first run).
    /// Hardened for real-world networks: HTTP-Range resume of a partial .part,
    /// a per-read stall watchdog (a hung connection fails fast instead of
    /// sitting inside the request timeout), and retries with backoff. The
    /// .part → rename step keeps a killed download from ever leaving a
    /// truncated model that sherpa-onnx would choke on.
    /// </summary>
    public static async Task EnsureModels(Action<string>? progress = null)
    {
        if (ModelsPresent) return;
        Directory.CreateDirectory(ModelDir);
        using var http = new HttpClient() { Timeout = Timeout.InfiniteTimeSpan };
        foreach (var file in ModelFiles)
        {
            var dest = Path.Combine(ModelDir, file);
            if (File.Exists(dest)) continue;
            var url = $"https://huggingface.co/{HfRepo}/resolve/main/{file}";
            var part = dest + ".part";
            progress?.Invoke($"Downloading {file}…");
            const int maxAttempts = 8;
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    await DownloadResumable(http, url, part);
                    break;
                }
                catch (Exception ex) when (attempt < maxAttempts)
                {
                    Logger.Log($"asr: {file} attempt {attempt} failed ({ex.Message}) — resuming in 3s");
                    await Task.Delay(3000);
                }
            }
            File.Move(part, dest, overwrite: true);
            Logger.Log($"asr: {file} done ({new FileInfo(dest).Length / 1_000_000} MB)");
        }
        progress?.Invoke("Models ready");
    }

    private static async Task DownloadResumable(HttpClient http, string url, string part)
    {
        var existing = File.Exists(part) ? new FileInfo(part).Length : 0;
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        if (existing > 0)
            req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(existing, null);
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
        if (existing > 0 && resp.StatusCode != System.Net.HttpStatusCode.PartialContent)
            existing = 0;   // server ignored the range — start over
        resp.EnsureSuccessStatusCode();
        Logger.Log($"asr: downloading {url}" + (existing > 0 ? $" (resuming at {existing / 1_000_000} MB)" : ""));

        await using var stream = await resp.Content.ReadAsStreamAsync();
        await using var outFile = new FileStream(part, existing > 0 ? FileMode.Append : FileMode.Create,
                                                 FileAccess.Write, FileShare.None);
        var buffer = new byte[1 << 16];
        while (true)
        {
            // Stall watchdog: any single read that takes >45s means a hung
            // connection — abort so the retry loop resumes from this offset.
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            int read;
            try { read = await stream.ReadAsync(buffer, cts.Token); }
            catch (OperationCanceledException) { throw new TimeoutException("download stalled"); }
            if (read == 0) break;
            await outFile.WriteAsync(buffer.AsMemory(0, read));
        }
    }

    /// <summary>Load the recognizer (models must already be present). Idempotent.</summary>
    public void Load()
    {
        lock (_gate)
        {
            if (_recognizer is not null) return;
            var config = new OfflineRecognizerConfig();
            config.ModelConfig.Transducer.Encoder = Path.Combine(ModelDir, "encoder.int8.onnx");
            config.ModelConfig.Transducer.Decoder = Path.Combine(ModelDir, "decoder.int8.onnx");
            config.ModelConfig.Transducer.Joiner = Path.Combine(ModelDir, "joiner.int8.onnx");
            config.ModelConfig.Tokens = Path.Combine(ModelDir, "tokens.txt");
            config.ModelConfig.ModelType = "nemo_transducer";
            config.ModelConfig.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 2, 8);
            config.DecodingMethod = "greedy_search";
            var sw = System.Diagnostics.Stopwatch.StartNew();
            _recognizer = new OfflineRecognizer(config);
            Logger.Log($"asr: recognizer loaded in {sw.ElapsedMilliseconds}ms");
        }
    }

    /// <summary>Transcribe mono 16 kHz float samples. Returns the raw transcript.</summary>
    public string Transcribe(float[] samples, int sampleRate = 16000)
    {
        lock (_gate)
        {
            if (_recognizer is null) throw new InvalidOperationException("ParakeetEngine.Load() not called");
            var sw = System.Diagnostics.Stopwatch.StartNew();
            using var stream = _recognizer.CreateStream();
            stream.AcceptWaveform(sampleRate, samples);
            _recognizer.Decode(stream);
            var text = stream.Result.Text.Trim();
            Logger.Log($"asr: {samples.Length / (double)sampleRate:F1}s audio → {sw.ElapsedMilliseconds}ms decode");
            return text;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _recognizer?.Dispose();
            _recognizer = null;
        }
    }
}
