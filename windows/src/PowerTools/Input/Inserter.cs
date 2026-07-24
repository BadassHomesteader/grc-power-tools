using System.Windows;
using PowerTools.Core;

namespace PowerTools.Input;

/// <summary>
/// Inserts text into the focused app via clipboard-swap paste — port of
/// Inserter.swift, same recipe:
/// 1. snapshot the clipboard (text / files / image — the practical formats)
/// 2. write the transcript tagged with a session-UUID format, plus the
///    Windows "concealed" markers so Win+V and clipboard managers skip it
/// 3. synthesize Ctrl+V
/// 4. restore the snapshot later ONLY if the clipboard still holds our UUID
///    (never clobber something the user copied mid-cycle)
/// Must be called on the UI (STA) thread.
/// </summary>
public static class Inserter
{
    private const string SessionFormat = "GRCWhisperSession";
    // Standard exclusion formats: history/pinning and clipboard monitors.
    private static readonly string[] ConcealFormats =
        { "ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard" };

    private sealed record Snapshot(string? Text, System.Collections.Specialized.StringCollection? Files,
                                   System.Windows.Media.Imaging.BitmapSource? Image);

    /// <summary>Snapshot carried across back-to-back pastes whose restore hasn't fired.</summary>
    private static Snapshot? _pendingSnapshot;

    public static void Insert(string text, int restoreDelayMs)
    {
        // 1. Snapshot — but never snapshot our own not-yet-restored transcript.
        Snapshot snapshot;
        if (Clipboard.ContainsData(SessionFormat) && _pendingSnapshot is not null)
        {
            snapshot = _pendingSnapshot;
        }
        else
        {
            snapshot = new Snapshot(
                Clipboard.ContainsText() ? Clipboard.GetText() : null,
                Clipboard.ContainsFileDropList() ? Clipboard.GetFileDropList() : null,
                Clipboard.ContainsImage() ? Clipboard.GetImage() : null);
        }

        // 2. Write transcript, marked as ours + concealed.
        var sessionId = Guid.NewGuid().ToString();
        var data = new DataObject();
        data.SetText(text);
        data.SetData(SessionFormat, sessionId);
        foreach (var fmt in ConcealFormats) data.SetData(fmt, new byte[] { 0, 0, 0, 0 });
        try
        {
            Clipboard.SetDataObject(data, copy: true);
        }
        catch (Exception ex)
        {
            Logger.Log($"insert: clipboard write failed: {ex.Message}");
            return;
        }
        _pendingSnapshot = snapshot;

        // 3. Give the clipboard a beat to settle, then synthetic Ctrl+V.
        Delay(100, InputSynth.SendCtrlV);

        // 4. Conditional restore.
        Delay(100 + Math.Max(restoreDelayMs, 250), () =>
        {
            try
            {
                if (!Clipboard.ContainsData(SessionFormat)
                    || Clipboard.GetData(SessionFormat) as string != sessionId)
                    return;   // user copied something meanwhile — leave it alone
                Restore(snapshot);
                _pendingSnapshot = null;
            }
            catch (Exception ex) { Logger.Log($"insert: restore failed: {ex.Message}"); }
        });
    }

    /// <summary>Paste text and LEAVE it on the clipboard (clipboard-history pick).</summary>
    public static void PasteLeavingOnClipboard(string text)
    {
        try { Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), copy: true); }
        catch (Exception ex) { Logger.Log($"paste: clipboard write failed: {ex.Message}"); return; }
        Delay(100, InputSynth.SendCtrlV);
    }

    private static void Restore(Snapshot snap)
    {
        var data = new DataObject();
        var any = false;
        if (snap.Text is not null) { data.SetText(snap.Text); any = true; }
        if (snap.Files is not null) { data.SetFileDropList(snap.Files); any = true; }
        if (snap.Image is not null) { data.SetImage(snap.Image); any = true; }
        if (any) Clipboard.SetDataObject(data, copy: true);
        else Clipboard.Clear();
    }

    /// <summary>Run `action` on this (UI) thread after a delay, without blocking it.</summary>
    private static void Delay(int ms, Action action)
    {
        var ctx = System.Threading.SynchronizationContext.Current;
        Task.Delay(ms).ContinueWith(_ =>
        {
            if (ctx is not null) ctx.Post(_ => action(), null);
            else action();
        });
    }
}
