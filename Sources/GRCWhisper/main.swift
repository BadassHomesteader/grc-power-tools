import Foundation
import AppKit

// GRC Whisper — fully-local voice dictation for macOS 26+.
// No arguments: run the menu-bar app. Subcommands below are for testing/administration.

/// Run async work to completion from the synchronous CLI entry point.
/// Detached so nothing accidentally hops onto the (blocked) main actor.
func runBlocking<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await op()) }
        catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    grc-whisper — fully-local voice dictation (hold a key, speak, release)

    usage:
      grc-whisper                     run the menu-bar app
      grc-whisper transcribe <file>   transcribe an audio file (engine test)
      grc-whisper polish <text>       run the cleanup pipeline on text (LLM test)
      grc-whisper doctor              check permissions and on-device models
      grc-whisper dict add <term> [misheard,variants]
      grc-whisper dict rm <term>
      grc-whisper dict list
      grc-whisper history [n]         show recent transcriptions
    """)
    exit(1)
}

switch args.first {
case nil, "run":
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

case "transcribe":
    guard args.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args[1])
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("no such file: \(url.path)"); exit(1)
    }
    let locale = Locale(identifier: Config.load().localeIdentifier)
    do {
        let started = Date()
        let text = try runBlocking { try await transcribeFile(url: url, locale: locale) }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        FileHandle.standardError.write("(transcribed in \(elapsed)s)\n".data(using: .utf8)!)
        print(text)
    } catch {
        print("transcription failed: \(error)"); exit(1)
    }

case "polish":
    guard args.count >= 2 else { usage() }
    let input = args.dropFirst().joined(separator: " ")
    let store = Store()
    let cfg = Config.load()
    let text = try! runBlocking {
        let polisher = Polisher(store: store)
        return await polisher.polish(input, config: cfg, appName: "Terminal")
    }
    print(text)

case "doctor":
    let report = try! runBlocking { await Doctor.report() }
    print(report)

case "render-overlay":
    // Offscreen preview of the dictation pill for design checks.
    let out = args.count >= 2 ? args[1] : "overlay-preview.png"
    MainActor.assumeIsolated {
        let (content, wave, text) = OverlayPanel.buildContent()
        let fake: [CGFloat] = (0..<64).map { i in
            let t = Double(i)
            let env = 0.5 + 0.45 * sin(t / 7) * cos(t / 3)
            return CGFloat(min(max(0.08, abs(env)), 1))
        }
        wave.setSamples(fake)
        text.stringValue = "meeting on Wednesday at 3 p.m."
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        }
    }

case "dict":
    let store = Store()
    switch args.count > 1 ? args[1] : "" {
    case "add":
        guard args.count >= 3 else { usage() }
        store.addDictTerm(args[2], misheard: args.count >= 4 ? args[3] : "")
        print("added: \(args[2])")
    case "rm":
        guard args.count >= 3 else { usage() }
        store.removeDictTerm(args[2])
        print("removed: \(args[2])")
    case "list":
        let entries = store.dictionary()
        if entries.isEmpty { print("(dictionary is empty — add terms with: grc-whisper dict add KYAW)") }
        for e in entries {
            print(e.misheard.isEmpty ? e.term : "\(e.term)  (misheard: \(e.misheard))")
        }
    default: usage()
    }

case "history":
    let n = args.count >= 2 ? Int(args[1]) ?? 10 : 10
    let store = Store()
    for entry in store.recentHistory(n) {
        print("[\(entry.timestamp)] \(entry.app)")
        print("  \(entry.polished)")
        if entry.polished != entry.raw { print("  (raw: \(entry.raw))") }
    }

default:
    usage()
}
