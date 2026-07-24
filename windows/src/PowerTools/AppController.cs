using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using PowerTools.Asr;
using PowerTools.Audio;
using PowerTools.Core;
using PowerTools.Input;
using PowerTools.UI;

namespace PowerTools;

/// <summary>
/// The dictation state machine — port of AppController.swift's core loop:
/// idle → recording (key down) → processing (key up: transcribe → polish →
/// insert) → idle. Runs on the WPF dispatcher; ASR and polish run off-thread.
/// On Windows the ASR engine is always Parakeet (config `asrEngine: "apple"`
/// is preserved but has no Windows engine behind it).
/// </summary>
public sealed class AppController : IDisposable
{
    private enum State { Idle, Recording, Processing }

    private readonly Config _config;
    private readonly Store _store;
    private readonly Polisher _polisher;
    private readonly AudioCapture _capture;
    private readonly AudioDucker _ducker = new();
    private readonly ParakeetEngine _engine = new();
    private readonly Dispatcher _dispatcher;
    private readonly DispatcherTimer _levelTimer;

    private State _state = State.Idle;
    private DateTime _recordStart;
    private RecordingOverlay? _overlay;
    private volatile bool _modelsReady;

    public AppController(Config config, Store store, Dispatcher dispatcher)
    {
        _config = config;
        _store = store;
        _dispatcher = dispatcher;
        _polisher = new Polisher(store);
        _capture = new AudioCapture(config.PreRollSeconds, config.MaxUtteranceSeconds);
        _levelTimer = new DispatcherTimer(DispatcherPriority.Render, dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(50),
        };
        _levelTimer.Tick += (_, _) => _overlay?.SetLevel(_capture.Level);
    }

    public void Start()
    {
        _capture.Start();
        // Models fetch/load in the background so the first dictation is fast;
        // an utterance arriving before they're ready is refused with a hint.
        Task.Run(async () =>
        {
            try
            {
                if (!ParakeetEngine.ModelsPresent)
                    await ParakeetEngine.EnsureModels(msg => Logger.Log($"asr: {msg}"));
                _engine.Load();
                _modelsReady = true;
            }
            catch (Exception ex) { Logger.Log($"asr: model setup failed: {ex.Message}"); }
        });
    }

    /// <summary>Hook event entry point — called on the dispatcher thread.</summary>
    public void Handle(HookEvent e)
    {
        switch (e)
        {
            case HookEvent.Down:
                if (_state != State.Idle) return;
                _state = State.Recording;
                _recordStart = DateTime.UtcNow;
                _capture.StartUtterance();
                if (_config.MuteWhileDictating) _ducker.Duck();
                ShowOverlay("● Listening…");
                break;

            case HookEvent.Up up:
                if (_state != State.Recording) return;
                var heldMs = (DateTime.UtcNow - _recordStart).TotalMilliseconds;
                if (heldMs < _config.MinHoldMs)
                {
                    _capture.CancelUtterance();
                    Reset();
                    return;
                }
                FinishUtterance(up.Command, (int)heldMs);
                break;

            case HookEvent.Cancel:
                if (_state == State.Idle) return;
                _capture.CancelUtterance();
                Reset();
                break;

            case HookEvent.QuickCapture qc:
                Logger.Log($"hook: quick capture → {qc.ConnectionId} (panel lands later in Phase 5)");
                break;

            default:
                // Window management, pads, capture tools: later phases.
                Logger.Log($"hook: {e} (not yet implemented on Windows)");
                break;
        }
    }

    private void FinishUtterance(DictationCommand command, int durationMs)
    {
        _state = State.Processing;
        var samples = _capture.StopUtterance();
        _ducker.Restore();   // speakers come back at key-up, not after transcription
        if (!_modelsReady)
        {
            SetOverlay("Speech model still downloading…");
            Logger.Log("asr: dictation before models ready — dropped");
            _ = _dispatcher.BeginInvoke(async () => { await Task.Delay(1800); Reset(); });
            return;
        }
        if (samples.Length < 16000 / 4)   // <250ms of audio — nothing to transcribe
        {
            Reset();
            return;
        }

        SetOverlay("Transcribing…");
        var appName = ForegroundAppName();
        Task.Run(async () =>
        {
            string raw = "", polished = "";
            try
            {
                raw = _engine.Transcribe(samples);
                if (raw.Length > 0)
                {
                    // The AI shortcut routes through the preferred cloud engine.
                    Config.PolishMode? engineOverride = command == DictationCommand.Ai ? PreferredCloud() : null;
                    polished = await _polisher.Polish(raw, _config, appName, engineOverride);
                }
            }
            catch (Exception ex) { Logger.Log($"dictate: pipeline error: {ex.Message}"); }

            _ = _dispatcher.BeginInvoke(() =>
            {
                if (polished.Length > 0)
                {
                    Inserter.Insert(polished, _config.ClipboardRestoreDelayMs);
                    _store.AddHistory(appName, raw, polished, durationMs);
                }
                Reset();
            });
        });
    }

    private Config.PolishMode? PreferredCloud()
    {
        if (SecretsStore.Has("claude")) return Config.PolishMode.Claude;
        if (SecretsStore.Has("openai")) return Config.PolishMode.OpenAI;
        return null;
    }

    private void ShowOverlay(string text)
    {
        _overlay ??= new RecordingOverlay(_config);
        _overlay.SetState(text);
        _overlay.SetLevel(0);
        _overlay.Show();
        _levelTimer.Start();
    }

    private void SetOverlay(string text)
    {
        _levelTimer.Stop();
        _overlay?.SetState(text);
    }

    private void Reset()
    {
        _ducker.Restore();
        _levelTimer.Stop();
        _overlay?.Hide();
        _state = State.Idle;
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint hWnd, out uint processId);

    private static string ForegroundAppName()
    {
        try
        {
            GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
            return pid == 0 ? "" : Process.GetProcessById((int)pid).ProcessName;
        }
        catch { return ""; }
    }

    public void Dispose()
    {
        _capture.Dispose();
        _engine.Dispose();
    }
}
