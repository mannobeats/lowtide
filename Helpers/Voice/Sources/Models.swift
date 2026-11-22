import CoreML
import FluidAudio
import Foundation
import MLX
import MLXAudioSTT
import PhononCoreML

/// The speech models Lowtide offers. Each lives in its own folder under
/// the models directory, with a `.complete` marker once fully downloaded.
enum ModelID: String, CaseIterable {
    case parakeetV3 = "parakeet-v3"
    case parakeetUltra = "parakeet-ultra"
    case qwen06 = "qwen3-0.6b"
    case qwen17 = "qwen3-1.7b"
    case phonon2 = "phonon-2"

    var parakeet: AsrModelVersion? {
        switch self {
        case .parakeetV3: .v3
        case .parakeetUltra: .ultra
        default: nil
        }
    }

    /// FluidAudio keeps each Parakeet build in a folder named after its repo.
    var parakeetFolder: String {
        self == .parakeetUltra ? "parakeet-ultra-coreml" : "parakeet-tdt-0.6b-v3-coreml"
    }

    /// The Hugging Face repo of a model FluidAudio doesn't fetch itself.
    var repo: String? {
        switch self {
        case .qwen06: "mlx-community/Qwen3-ASR-0.6B-8bit"
        case .qwen17: "mlx-community/Qwen3-ASR-1.7B-6bit"
        case .phonon2: "FermionResearch/Phonon-2-CoreML"
        default: nil
        }
    }
}

/// Recognises 16 kHz mono speech.
protocol Engine: AnyObject {
    /// `context` lists words to expect (names, jargon); `language` is an ISO
    /// code or nil to detect it.
    func transcribe(_ samples: [Float], language: String?, context: String) async throws -> String
}

enum Models {
    static func folder(_ id: ModelID, in root: URL) -> URL {
        root.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    static func installed(_ id: ModelID, in root: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder(id, in: root).appendingPathComponent(".complete").path)
    }

    static func download(
        _ id: ModelID, into root: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let dir = folder(id, in: root)
        if id == .phonon2 {
            guard #available(macOS 15, *) else { throw VoiceError("Phonon-2 needs macOS 15 or later.") }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let version = id.parakeet {
            try await AsrModels.download(
                to: dir.appendingPathComponent(id.parakeetFolder),
                version: version,
                progressHandler: { progress($0.fractionCompleted) })
        } else if let repo = id.repo {
            try await HuggingFace.download(repo, into: dir, progress: progress)
        }
        if #available(macOS 15, *), id == .phonon2 {
            try await PhononEngine.compile(dir)
        }
        try Data().write(to: dir.appendingPathComponent(".complete"))
    }

    static func load(_ id: ModelID, from root: URL) async throws -> Engine {
        guard installed(id, in: root) else {
            throw VoiceError("Download the model in Extensions → Dictation first.")
        }
        let dir = folder(id, in: root)
        if let version = id.parakeet {
            return try await ParakeetEngine.load(
                dir.appendingPathComponent(id.parakeetFolder), version: version)
        }
        if id == .phonon2 {
            guard #available(macOS 15, *) else { throw VoiceError("Phonon-2 needs macOS 15 or later.") }
            return try await PhononEngine.load(dir)
        }
        return try await QwenEngine.load(dir)
    }
}

// MARK: - Parakeet (FluidAudio, Neural Engine)

final class ParakeetEngine: Engine {
    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    static func load(_ dir: URL, version: AsrModelVersion) async throws -> ParakeetEngine {
        let models = try await AsrModels.load(from: dir, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let engine = ParakeetEngine(manager: manager)
        // The first run compiles for the Neural Engine; pay it now, not on
        // the first word.
        _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), language: nil, context: "")
        return engine
    }

    func transcribe(_ samples: [Float], language: String?, context: String) async throws -> String {
        var state = TdtDecoderState.make()
        let hint = language.flatMap(Language.init(rawValue:))
        return try await manager.transcribe(samples, decoderState: &state, language: hint).text
    }
}

// MARK: - Phonon-2 (Core ML, Neural Engine)

@available(macOS 15, *)
final class PhononEngine: Engine {
    private let transcriber: Transcriber
    /// The transcriber blocks while it works, and long takes share its
    /// decoders: one at a time, off the main thread.
    private static let queue = DispatchQueue(label: "voice.phonon", qos: .userInitiated)

    private init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    /// Compiles the downloaded package next to it, where the transcriber
    /// looks first, so removing the model folder leaves nothing behind (it
    /// would otherwise compile into ~/Library/Caches). The package isn't read
    /// again, so its 330 MB go.
    static func compile(_ dir: URL) async throws {
        let package = dir.appendingPathComponent("Phonon-2.mlpackage")
        let target = dir.appendingPathComponent("Phonon-2.mlmodelc")
        let compiled = try await MLModel.compileModel(at: package)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: compiled, to: target)
        try? FileManager.default.removeItem(at: package)
    }

    static func load(_ dir: URL) async throws -> PhononEngine {
        var options = Transcriber.Options()
        // Each take length has its own encoder, prepared for the Neural
        // Engine the first time it's used (slow, once per Mac). The 15 s one
        // loads now and serves every length up to it while the rest load.
        options.backgroundLoad = true
        let transcriber = try await run { try Transcriber(bundle: dir, options: options) }
        let engine = PhononEngine(transcriber: transcriber)
        _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), language: nil, context: "")
        return engine
    }

    /// English only, and no hints: `language` and `context` don't apply.
    func transcribe(_ samples: [Float], language: String?, context: String) async throws -> String {
        try await Self.run { [transcriber] in try transcriber.transcribe(samples).text }
    }

    private static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}

// MARK: - Qwen3-ASR (MLX, GPU)

/// MLX isn't safe to drive from two threads at once: Metal aborts the helper
/// ("completed handler provided after commit"). Every load and every
/// transcription, of every engine, takes its turn here, so a model loading
/// can't overlap one that is listening.
actor MLXGate {
    static let shared = MLXGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ work: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer { handOver() }
        return try await work()
    }

    /// The next waiter inherits the turn; `busy` stays set for it.
    private func handOver() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

final class QwenEngine: Engine {
    private let model: Qwen3ASRModel
    private static let queue = DispatchQueue(label: "voice.qwen", qos: .userInitiated)

    private init(model: Qwen3ASRModel) {
        self.model = model
    }

    static func load(_ dir: URL) async throws -> QwenEngine {
        // MLX aborts the process when its GPU shaders are missing; say so instead.
        let shaders = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap {
            $0?.appendingPathComponent("mlx-swift_Cmlx.bundle")
        }
        guard shaders.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw VoiceError("This build can't run Qwen: its GPU shaders are missing.")
        }
        let model = try await MLXGate.shared.run { try await Qwen3ASRModel.fromModelDirectory(dir) }
        let engine = QwenEngine(model: model)
        _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), language: "en", context: "")
        return engine
    }

    func transcribe(_ samples: [Float], language: String?, context: String) async throws -> String {
        // Not Sendable, but MLXGate lets one load or transcription at a time
        // touch MLX, so the queue never shares it.
        nonisolated(unsafe) let model = model
        return try await MLXGate.shared.run {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    let output = model.generate(
                        audio: MLXArray(samples),
                        maxTokens: 1024,
                        context: context,
                        language: language)
                    MLX.Memory.clearCache()
                    continuation.resume(returning: output.text)
                }
            }
        }
    }
}

// MARK: - Hugging Face

/// Fetches every file of a model repo over HTTPS, skipping what's already
/// there at the right size.
enum HuggingFace {
    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    static func download(
        _ repo: String, into dir: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let listing = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: listing)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceError("Hugging Face didn't list \(repo).")
        }
        let files = try JSONDecoder().decode([Entry].self, from: data).filter {
            $0.type == "file" && !$0.path.hasPrefix(".") && $0.path != "README.md"
        }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = dir.appendingPathComponent(file.path)
            let have = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
            if have != file.size {
                let base = done
                try await fetch(
                    URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)")!,
                    to: target
                ) { bytes in
                    progress(Double(base + bytes) / Double(total))
                }
            }
            done += file.size ?? 0
            progress(Double(done) / Double(total))
        }
    }

    private static func fetch(
        _ url: URL, to target: URL, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fetcher = Fetcher(target: target, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: fetcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                fetcher.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One file to disk, reporting bytes as they arrive.
private final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let target: URL
    let progress: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?

    init(target: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.target = target
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temporary file is gone once this returns: move it now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(VoiceError("Couldn't download \(target.lastPathComponent) (HTTP \(status))."))
            return
        }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
