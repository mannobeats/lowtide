// lowtide-voice: Lowtide's on-device dictation. Hold (or tap) the
// shortcut, speak, and the words go into the app you're in. Speech is
// recognised on this Mac by Parakeet or Phonon-2 (Core ML, Neural Engine)
// or Qwen3-ASR (MLX, GPU); nothing leaves it. The only network use is
// downloading a model when the user asks for one.
//
// It speaks JSON lines over stdin/stdout with Lowtide:
//
//   in   {"type":"configure", …Settings}          what to listen for and how;
//                                                 sent on every start. With
//                                                 "enabled":false only
//                                                 downloads work. Mid-take
//                                                 it waits for the take to end.
//        {"type":"download","model":"…"}          fetch a model
//        {"type":"cancel-download"}
//        {"type":"record-shortcut"} / {"type":"stop-recording-shortcut"}
//        {"type":"devices"}                       list microphones
//        {"type":"status"}                        answered with "access"
//        {"type":"toggle"} / {"type":"cancel"}    from the overlay or a menu
//        {"type":"paste-last","text":"…"}         into the app in front (the
//                                                 one behind Lowtide if
//                                                 Lowtide is in front)
//   out  {"type":"state","phase":"…","message":"…", …}
//            phase: idle | listening (microphone opening) | recording |
//            transcribing | done | empty | error. Optional: "queued" (takes
//            waiting); on done "method" (paste | accessibility | typed |
//            copied), "app", "text"; on error "kind" (no-model |
//            model-loading | mic | permission | secure-input | no-focus) and
//            "action" (open-settings | allow-accessibility |
//            allow-microphone | download-model | paste-last). The app
//            follows done, empty and error with idle once they're shown.
//        {"type":"level","value":0…1}             ~30 Hz while recording
//        {"type":"preview","text":"…"}
//        {"type":"result","text":"…","raw":"…","app":"…","bundleId":"…",
//         "method":"…","typed":bool,"secure":bool,…}
//        {"type":"download","model":"…","progress":0…1,"done":bool,"error":"…"}
//        {"type":"model","model":"…","state":"loading|ready|error","message":"…"}
//        {"type":"shortcut","shortcut":{…},"label":"…"}
//        {"type":"devices","devices":[{"uid":"…","name":"…","isDefault":bool}]}
//        {"type":"access","shortcut":bool,"polish":bool,"fnUsage":n|null}
//            shortcut: a valid, enabled event tap. fnUsage: macOS's Globe
//            key setting (0 is Do Nothing).
//
// Diagnostics (never what was said) go to ~/Library/Logs/Lowtide/voice.ndjson.
//
// For testing without the app:
//   lowtide-voice --download <model> --models <dir>
//   lowtide-voice --transcribe <file> --model <model> --models <dir> [--language fr] [--context "Lowtide, …"]
//   lowtide-voice --self-test

import AppKit
import Foundation

let arguments = CommandLine.arguments

func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--self-test") {
    // The text handling that can't be seen without a field to type into.
    let strokes = Insert.strokes("a\r\nb", perKey: false, layout: Keys.Layout())
    precondition(strokes.count == 8 && strokes[2].key == 56 && strokes[3].key == 36, "a line break is one Shift-Return")
    precondition(Insert.strokes(String(repeating: "x", count: 25), perKey: false, layout: Keys.Layout()).count == 4,
                 "20 units per event")
    let pair = Insert.strokes(String(repeating: "x", count: 19) + "😀", perKey: false, layout: Keys.Layout())
    precondition(pair.count == 4 && pair[2].text?.count == 2, "a surrogate pair stays whole")
    precondition(Text.fitted("hello", after: "word") == " hello")
    precondition(Text.fitted("hello", after: ".") == " hello")
    precondition(Text.fitted("hello", after: " ") == "hello")
    precondition(Text.echoes("Claude Code, Tailscale.", vocabulary: ["Claude Code", "Tailscale"]), "a vocabulary echo")
    precondition(!Text.echoes("Tailscale", vocabulary: ["Claude Code", "Tailscale"]), "one word can be said")
    precondition(Audio.silent([Float](repeating: 0.001, count: 16_000)) && Audio.dead([0, 0]))
    precondition(Text.fitted("hello", after: "(") == "hello")
    precondition(Text.fitted(", fine", after: "ok") == ", fine")
    precondition(Text.fitted("hello", after: "") == "hello")
    precondition(Insert.chromiumMajor("155.0.7727.12") == 155 && Insert.chromiumMajor("A") == nil)
    let clockBefore = Clock.now()
    let huge = Clock.event(.max)
    precondition(huge >= clockBefore && huge <= Clock.now(), "a timestamp too large to convert reads as now")
    print("ok")
    exit(0)
}

if let model = argument("--download"), let dir = argument("--models"),
   let id = ModelID(rawValue: model)
{
    Task {
        do {
            try await Models.download(id, into: URL(fileURLWithPath: dir)) { progress in
                FileHandle.standardError.write("\r\(Int(progress * 100))%".data(using: .utf8)!)
            }
            print("\ndownloaded \(model)")
            exit(0)
        } catch {
            print("\nerror: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

if let file = argument("--transcribe"), let model = argument("--model"),
   let dir = argument("--models"), let id = ModelID(rawValue: model)
{
    Task {
        do {
            let started = Date()
            let engine = try await Models.load(id, from: URL(fileURLWithPath: dir))
            let loaded = Date()
            let samples = try Audio.read(URL(fileURLWithPath: file))
            let text = try await engine.transcribe(samples, language: argument("--language"), context: argument("--context") ?? "")
            let done = Date()
            print(text)
            print(String(
                format: "load %.2fs, transcribe %.0f ms for %.1fs of audio",
                loaded.timeIntervalSince(started),
                done.timeIntervalSince(loaded) * 1000,
                Double(samples.count) / 16_000))
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

// The app ended or closed the pipe: so does the helper.
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        DispatchQueue.main.async { MainActor.assumeIsolated { Session.shared.handle(message) } }
    }
    exit(0)
}

// A run loop for the shortcut's event tap; no Dock icon, no menu.
NSApplication.shared.setActivationPolicy(.prohibited)
RunLoop.main.run()
