import Foundation
import Testing
@testable import LowtideKit

@Suite struct VoiceProtocolTests {
    /// Lines as the helper prints them (copied from a real session's log of
    /// stdout), including the odd ones.
    @Test func parsesEveryHelperMessage() {
        let done = HelperMessage.parse(#"{"type":"state","phase":"done","message":"","method":"paste","app":"Notes","text":"Hi","queued":2}"#)
        #expect(done == .state(VoiceState(phase: .done, method: "paste", app: "Notes", text: "Hi", queued: 2)))

        let error = HelperMessage.parse(#"{"type":"state","phase":"error","message":"Pick and download a model in Lowtide → Extensions → Dictation.","kind":"no-model","action":"download-model"}"#)
        guard case .state(let state)? = error else { Issue.record("no state"); return }
        #expect(state.kind == "no-model" && state.action == .downloadModel && state.shownFor == .seconds(5))

        // Unknown phases and actions read as idle and none.
        guard case .state(let odd)? = HelperMessage.parse(#"{"type":"state","phase":"warming","action":"dance"}"#) else {
            Issue.record("no state"); return
        }
        #expect(odd.phase == .idle && odd.action == nil)

        #expect(HelperMessage.parse(#"{"type":"level","value":1.7}"#) == .level(1))
        #expect(HelperMessage.parse(#"{"type":"preview","text":"so far"}"#) == .preview("so far"))
        #expect(HelperMessage.parse(#"{"type":"model","model":"parakeet-v3","state":"loading","message":""}"#)
            == .model(id: "parakeet-v3", state: .loading, message: ""))
        #expect(HelperMessage.parse(#"{"type":"download","model":"qwen3-0.6b","progress":0.25,"done":false}"#)
            == .download(model: "qwen3-0.6b", progress: 0.25, done: false, error: nil))
        #expect(HelperMessage.parse(#"{"type":"download","model":"qwen3-0.6b","progress":0,"done":false,"error":""}"#)
            == .download(model: "qwen3-0.6b", progress: 0, done: false, error: ""))
        #expect(HelperMessage.parse(#"{"type":"access","shortcut":true,"polish":false,"fnUsage":null}"#)
            == .access(shortcut: true, polish: false, fnUsage: .some(nil)))
        #expect(HelperMessage.parse(#"{"type":"access","shortcut":false,"polish":true,"fnUsage":0}"#)
            == .access(shortcut: false, polish: true, fnUsage: .some(0)))
        #expect(HelperMessage.parse(#"{"type":"blocked","by":"1Password"}"#) == nil, "a retired message reads as unknown")
        #expect(HelperMessage.parse(#"{"type":"shortcut","shortcut":{"modifiers":["control","option"],"key":49},"label":"⌃⌥ Space"}"#)
            == .shortcut(VoiceShortcut(key: 49, modifiers: ["control", "option"]), label: "⌃⌥ Space"))
        #expect(HelperMessage.parse(#"{"type":"devices","devices":[{"uid":"BuiltInMicrophoneDevice","name":"MacBook Pro Microphone","isDefault":true}]}"#)
            == .devices([VoiceDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isDefault: true)]))
        let result = HelperMessage.parse(#"{"type":"result","text":"Hello there.","raw":"hello there","app":"Notes","bundleId":"com.apple.Notes","model":"parakeet-v3","seconds":2.4,"elapsedMs":180,"typed":true,"secure":false,"method":"paste"}"#)
        #expect(result == .result(DictationResult(text: "Hello there.", raw: "hello there", app: "Notes", bundleId: "com.apple.Notes",
                                                  model: "parakeet-v3", seconds: 2.4, elapsedMs: 180, typed: true, secure: false, method: "paste")))
        #expect(HelperMessage.parse("not json") == nil)
        #expect(HelperMessage.parse(#"{"type":"nonsense"}"#) == nil)
    }

    @Test func linesSurviveBytesThatAreNotUTF8() {
        var splitter = LineSplitter()
        var lines = splitter.append(Data("one\n".utf8) + Data([0xFF, 0xFE, 0x0D, 0x0A]) + Data("thr".utf8))
        lines += splitter.append(Data("ee".utf8))
        lines += splitter.finish()
        #expect(lines == ["one", "\u{FFFD}\u{FFFD}", "three"])
    }

    @Test func configureCarriesEverySetting() throws {
        var prefs = VoicePrefs()
        prefs.replacements = [Replacement(spoken: "low tide", typed: "Lowtide")]
        prefs.vocabulary = ["Kubernetes"]
        prefs.shortcut = VoiceShortcut(button: 3, modifiers: ["command"])
        let line = prefs.configureLine(enabled: true, modelsDir: URL(fileURLWithPath: "/tmp/models"))
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["type"] as? String == "configure")
        #expect(object["modelsDir"] as? String == "/tmp/models")
        #expect(object["model"] as? String == "parakeet-v3")
        #expect(object["mode"] as? String == "auto")
        #expect(object["microphone"] is NSNull)
        #expect((object["replacements"] as? [[String]]) == [["low tide", "Lowtide"]])
        let shortcut = try #require(object["shortcut"] as? [String: Any])
        #expect(shortcut["button"] as? Int == 3 && shortcut["key"] == nil)
    }

    @Test func prefsReadOlderSavesWithDefaults() throws {
        let saved = Data(#"{"model":"qwen3-0.6b","mode":"toggle","keepDays":7}"#.utf8)
        let prefs = try JSONDecoder().decode(VoicePrefs.self, from: saved)
        #expect(prefs.model == "qwen3-0.6b" && prefs.mode == .toggle && prefs.keepDays == 7)
        #expect(prefs.shortcut == .rightOption && prefs.history && prefs.excluded.count == 5)
        let round = try JSONDecoder().decode(VoicePrefs.self, from: JSONEncoder().encode(prefs))
        #expect(round == prefs)
    }

    @Test func notesOnlyKeysThatType() {
        // The key above Tab, as it was saved before the recorder took it.
        #expect(VoiceShortcut(key: 50, modifiers: []).note(label: "`") == "` no longer types")
        #expect(VoiceShortcut(key: 50, modifiers: ["control"]).note(label: "⌃`") == nil)
        #expect(VoiceShortcut(key: 49, modifiers: []).note(label: "Space") != nil)
        // ⇧ and fn still type, so they note; ⌘, ⌥ and ⌃ don't.
        #expect(VoiceShortcut(key: 0, modifiers: ["shift"]).note(label: "⇧A") != nil)
        #expect(VoiceShortcut(key: 0, modifiers: ["fn"]).note(label: "fn A") != nil)
        #expect(VoiceShortcut(key: 0, modifiers: ["command"]).note(label: "⌘A") == nil)
        // A key that only moves gives nothing up.
        #expect(VoiceShortcut(key: 122, modifiers: []).note(label: "F1") == nil)
        #expect(VoiceShortcut(key: 123, modifiers: []).note(label: "←") == nil)
        #expect(VoiceShortcut(button: 3, modifiers: []).note(label: "Mouse 4") == nil)
        #expect(VoiceShortcut.rightOption.note(label: "Right ⌥") == nil)
    }

    @Test func everyModelHasAUniqueID() {
        #expect(Set(VoiceModelInfo.all.map(\.id)).count == VoiceModelInfo.all.count)
        #expect(VoiceModelInfo.named(VoicePrefs().model) != nil)
    }

    @Test func statusFoldsMessages() {
        var status = VoiceStatus()
        let changed = status.apply(.download(model: "phonon-2", progress: 0.4, done: false, error: nil))
        #expect(changed)
        #expect(status.download?.progress == 0.4)
        status.apply(.download(model: "phonon-2", progress: 0, done: false, error: ""))
        #expect(status.download == nil, "a cancel clears the bar")
        status.apply(.download(model: "phonon-2", progress: 0, done: false, error: "The network went away"))
        #expect(status.download?.error == "The network went away")
        status.apply(.access(shortcut: true, polish: nil, fnUsage: nil))
        #expect(status.shortcutAccess == true && status.fnUsage == nil)
        status.apply(.access(shortcut: true, polish: true, fnUsage: .some(2)))
        #expect(status.fnUsage == 2 && status.polishAvailable)
        let quiet = status.apply(.level(0.5))
        #expect(!quiet)
    }

    @Test func diagnosticsNeverHoldWhatWasSaid() {
        var status = VoiceStatus()
        status.apply(.state(VoiceState(phase: .transcribing, message: "my secret words")))
        let report = VoiceDiagnostics.report(version: "1.0", os: "macOS 26", prefs: VoicePrefs(), status: status,
                                             stderr: ["loaded"], log: #"{"event":"take"}"#)
        #expect(!report.contains("my secret words"))
        #expect(report.contains("Right ⌥") && report.contains(#"{"event":"take"}"#))
    }

    @Test func restartsBackOffAfterThreeInAMinute() {
        var policy = RestartPolicy()
        let start = Date()
        #expect(policy.next(now: start).wait == .seconds(1))
        #expect(policy.next(now: start.addingTimeInterval(1)).wait == .seconds(1))
        #expect(policy.next(now: start.addingTimeInterval(2)).wait == .seconds(1))
        let slow = policy.next(now: start.addingTimeInterval(3))
        #expect(slow.wait == .seconds(60) && slow.slow)
        #expect(policy.next(now: start.addingTimeInterval(70)).wait == .seconds(1))
    }
}

@Suite struct VoiceHistoryTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lowtide-voice-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func historyKeepsItsDaysAndSkipsLeftOutApps() {
        let day: Int64 = 86_400_000
        let now = 100 * day
        var rules = HistoryRules(keepDays: 7, excluded: ["com.1password.1password"])
        var entries = [
            DictationEntry(id: 1, text: "a", bundleId: "com.apple.Notes", at: now - day),
            DictationEntry(id: 2, text: "b", bundleId: "com.1password.1password", at: now - day),
            DictationEntry(id: 3, text: "c", bundleId: "com.apple.Notes", at: now - 8 * day),
        ]
        #expect(rules.prune(&entries, now: now))
        #expect(entries.map(\.id) == [1])
        rules.keepDays = 0
        entries.append(DictationEntry(id: 4, text: "d", bundleId: "com.apple.Notes", at: 0))
        #expect(!rules.prune(&entries, now: now))
    }

    @Test func remembersForgetsAndNeverKeepsPasswords() async {
        let dir = temp()
        let history = DictationHistory(url: dir.appending(path: "dictation-history.json"))
        let rules = HistoryRules(keepDays: 30, excluded: ["com.1password.1password"])
        #expect(await history.remember(DictationResult(text: "First", app: "Notes", bundleId: "com.apple.Notes"), rules: rules, now: 1000))
        #expect(await history.remember(DictationResult(text: "Second"), rules: rules, now: 1000))
        #expect(!(await history.remember(DictationResult(text: "pw", secure: true), rules: rules, now: 2000)))
        #expect(!(await history.remember(DictationResult(text: "x", bundleId: "com.1password.1password"), rules: rules, now: 2000)))
        let kept = await history.load()
        #expect(kept.map(\.text) == ["Second", "First"])
        #expect(kept[0].id != kept[1].id, "same millisecond, different ids")
        #expect(await history.newest() == "Second")
        await history.forget(kept[0].id)
        #expect(await history.load().map(\.text) == ["First"])
        await history.forget(nil)
        #expect(await history.load().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A saved `dictation-history.json` reads unchanged.
    @Test func readsHistory() throws {
        let json = #"[{"id":1731500000000,"text":"Ship it.","raw":"ship it","app":"Slack","bundleId":"com.tinyspeck.slackmacgap","model":"parakeet-v3","seconds":1.2,"elapsedMs":95,"at":1731500000000}]"#
        let entries = try JSONDecoder().decode([DictationEntry].self, from: Data(json.utf8))
        #expect(entries.first?.app == "Slack" && entries.first?.elapsedMs == 95)
    }
}

@Suite struct VoiceStatsTests {
    @Test func countsWordsInEveryScript() {
        #expect(wordCount("Hello there, world.") == 3)
        #expect(wordCount("  ") == 0)
        // Whitespace splitting counted this as one word.
        #expect(wordCount("今日は良い天気です") > 1)
    }

    @Test func localDayUsesThatDaysOffset() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        // 2025-03-29 23:30 in Paris (UTC+1), the night before summer time.
        let before = Int64(Date(timeIntervalSince1970: 1_743_287_400).timeIntervalSince1970 * 1000)
        // 2025-03-30 23:30 in Paris (UTC+2).
        let after = before + 86_400_000 - 3_600_000
        #expect(DictationStats.localDay(after, zone: paris) - DictationStats.localDay(before, zone: paris) == 1)
        // Midnight UTC is 01:00 in Paris in winter: still the same day locally.
        #expect(DictationStats.localDay(0, zone: paris) == 0)
        #expect(DictationStats.localDay(-1, zone: TimeZone(identifier: "UTC")!) == -1)
    }

    @Test func addsUpTotalsPaceAndTimeSaved() {
        let utc = TimeZone(identifier: "UTC")!
        var stats = DictationStats(since: 0)
        let day: Int64 = 86_400_000
        stats.add(at: 10 * day, model: "parakeet-v3", app: "Notes", words: 40, seconds: 15, elapsedMs: 500, zone: utc)
        stats.add(at: 12 * day, model: "parakeet-v3", app: "Notes", words: 20, seconds: 15, elapsedMs: 500, zone: utc)
        stats.add(at: 12 * day + 5, model: "qwen3-0.6b", app: "Slack", words: 0, seconds: 0, elapsedMs: 0, zone: utc)
        stats.empty = 1
        #expect(stats.total().dictations == 3 && stats.total(from: 12).dictations == 2)
        #expect(stats.pace == 120)
        // 60 words at 40 wpm = 90 s, minus 30 s spoken and 1 s waiting.
        #expect(stats.saved == 59)
        #expect(stats.topApps().map(\.app) == ["Notes", "Slack"])
        #expect(stats.speeds.map(\.model) == ["parakeet-v3"])
        #expect(stats.speeds.first?.ratio == 30)
        let strip = stats.strip(today: 12, count: 3)
        #expect(strip.map(\.day) == [10, 11, 12] && strip.map(\.words) == [40, 0, 20])
        #expect(stats.counted)
        #expect(!DictationStats().counted)
    }

    @Test func formatsDurations() {
        #expect(spokenDuration(45) == "45 s")
        #expect(spokenDuration(12 * 60) == "12 min")
        #expect(spokenDuration(3 * 3600 + 20 * 60) == "3 h 20 min")
        #expect(spokenDuration(2 * 3600) == "2 h")
    }

    @Test func statsAreRebuiltFromHistoryOnceThenKept() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-stats-\(UUID().uuidString)")
        let history = DictationHistory(url: dir.appending(path: "h.json"))
        _ = await history.remember(DictationResult(text: "one two three", app: "Notes", model: "parakeet-v3", seconds: 2),
                                   rules: HistoryRules(keepDays: 0, excluded: []), now: 5_000)
        let store = DictationStatsStore(url: dir.appending(path: "s.json"), history: history)
        let first = await store.load(now: 9_000)
        #expect(first.total().words == 3 && first.since == 5_000)
        await history.forget(nil)
        #expect(await store.load().total().words == 3, "clearing history keeps the counts")
        await store.count(DictationResult(text: "four", app: "Mail", model: "parakeet-v3", seconds: 1))
        #expect(await store.load().total().dictations == 2)
        await store.reset(now: 10_000)
        let reset = await store.load()
        #expect(!reset.counted && reset.since == 10_000)
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite struct VoiceHUDTests {
    @Test func labelsSayWhereTheTextWent() {
        #expect(HUDLabel.of(VoiceState(phase: .done, method: "paste", app: "Notes"))?.text == "Pasted into Notes")
        #expect(HUDLabel.of(VoiceState(phase: .done, method: "accessibility"))?.text == "Typed")
        #expect(HUDLabel.of(VoiceState(phase: .done, method: "copied", app: "Notes"))?.text == "Copied: press ⌘V")
        #expect(HUDLabel.of(VoiceState(phase: .done, message: "Went to Mail"))?.text == "Went to Mail")
        let empty = HUDLabel.of(VoiceState(phase: .empty))
        #expect(empty?.quiet == true && empty?.glyph == .flat)
        let error = HUDLabel.of(VoiceState(phase: .error, kind: "secure-input", action: .pasteLast))
        #expect(error?.text == "Keys are blocked" && error?.action == .pasteLast)
        #expect(HUDLabel.of(VoiceState(phase: .recording)) == nil)
    }

    @Test func plateSizesFollowThePhase() {
        #expect(HUDPlate.width(.recording, label: nil, labelWidth: 0, right: 22) == 146)
        #expect(HUDPlate.width(.transcribing, label: nil, labelWidth: 0, right: 0) == 80)
        #expect(HUDPlate.width(.idle, label: nil, labelWidth: 0, right: 0) == nil)
        let label = HUDLabel(glyph: .alert, quiet: false, text: "x", action: .openSettings)
        #expect(HUDPlate.width(.error, label: label, labelWidth: 1000, right: 0) == HUDPlate.maxWidth)
        #expect(HUDPlate.delay(showing: .recording, over: .error, elapsed: 0) == 0)
        #expect(HUDPlate.delay(showing: .idle, over: .error, elapsed: 1) == 1.6000000000000001)
    }

    @Test func springsSettleTheSameAtAnyFrameRate() {
        var coarse = HUDSpring(0), fine = HUDSpring(0)
        coarse.target = 1
        fine.target = 1
        for _ in 0..<30 { coarse.step(.morph, 1.0 / 60) }
        for _ in 0..<120 { fine.step(.morph, 1.0 / 240) }
        #expect(abs(coarse.x - fine.x) < 1e-9)
        for _ in 0..<120 { coarse.step(.morph, 1.0 / 60) }
        #expect(coarse.settled())
        var overdamped = HUDSpring(0)
        overdamped.target = 1
        for _ in 0..<200 { overdamped.step(HUDSpring.Spec(bounce: -0.5, duration: 0.3), 1.0 / 60) }
        #expect(overdamped.settled())
    }

    @Test func filamentRingsWithTheVoiceAndRestsInSilence() {
        var filament = Filament()
        filament.live = true
        for i in 0..<240 {
            filament.input = i % 40 < 20 ? 0.9 : 0.2
            filament.advance(1.0 / 60)
        }
        let loud = filament.shape(room: 11).main.map(abs).max() ?? 0
        #expect(filament.energy > 0 && loud > 0.5 && loud <= 11)
        filament.live = false
        for _ in 0..<180 { filament.advance(1.0 / 60) }
        #expect((filament.shape(room: 11).main.map(abs).max() ?? 1) < 0.05)
    }

    @Test func motionComesInAndGoes() {
        var motion = HUDMotion()
        motion.aim(.recording, labelled: false, width: 124, words: false)
        for _ in 0..<60 { motion.step(1.0 / 60, reduced: false, labelled: false, previewSize: (120, 36)) }
        #expect(motion.opacity.x > 0.99 && abs(motion.width.x - 124) < 0.5)
        motion.aim(.idle, labelled: false, width: nil, words: false)
        for _ in 0..<90 { motion.step(1.0 / 60, reduced: true, labelled: false, previewSize: (120, 36)) }
        #expect(motion.gone && motion.width.x == 124)
    }
}

/// The helper process client, against a stand-in written in shell.
@Suite(.serialized) struct VoiceHelperTests {
    @Test func talksToAHelperAndHearsItEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "fake-voice")
        // Echoes a state for each line it reads, says something on stderr,
        // and quits on "bye".
        try """
        #!/bin/sh
        echo '{"type":"model","model":"parakeet-v3","state":"ready","message":""}'
        while IFS= read -r line; do
          case "$line" in
            *bye*) exit 3 ;;
            *) echo '{"type":"state","phase":"recording","message":""}'; echo "got it" 1>&2 ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let received = Received()
        let (ended, endedContinuation) = AsyncStream<Int32>.makeStream()
        let helper = VoiceHelper(executable: script, onMessage: { received.add($0) },
                                 onExit: { _, status in endedContinuation.yield(status) })
        #expect(try helper.start(first: VoiceLine.command("configure")))
        #expect(try !helper.start(first: VoiceLine.command("configure")), "one helper at a time")
        try helper.send(VoiceLine.command("status"))
        for _ in 0..<50 where received.count < 3 { try await Task.sleep(for: .milliseconds(40)) }
        #expect(received.messages.first == .model(id: "parakeet-v3", state: .ready, message: ""))
        #expect(received.count == 3)
        #expect(helper.stderrTail.contains("got it"))
        let pid = try #require(helper.pid)
        try helper.send(VoiceLine.command("bye"))
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == 3)
        #expect(helper.isCurrent(pid))
        helper.ended(pid)
        #expect(!helper.isRunning)
        #expect(throws: LowtideError.self) { try helper.send(VoiceLine.command("status")) }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Messages collected from the reader's queue.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [HelperMessage] = []
    func add(_ message: HelperMessage) { lock.withLock { list.append(message) } }
    var messages: [HelperMessage] { lock.withLock { list } }
    var count: Int { messages.count }
}
