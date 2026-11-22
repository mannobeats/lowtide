import Foundation
import FoundationModels
import Synchronization

/// What the conversation sees while a question is answered.
public enum AskEvent: Equatable, Sendable {
    /// The model is looking something up.
    case tool(name: String, arguments: AskArguments)
    /// The answer so far.
    case partial(String)
    case done(String)
    case failed(String)
}

/// Ask: plain questions about this Mac, answered by Apple's on-device model
/// (FoundationModels, in this process). Nothing leaves the Mac. Questions
/// are answered one at a time; each conversation keeps its own session so
/// follow-ups have context.
public actor AskEngine {
    public static let shared = AskEngine()

    public struct Availability: Equatable, Sendable {
        public var available: Bool
        public var reason: String
    }

    private var sessions: [String: LanguageModelSession] = [:]
    /// Where the running question's tool calls are reported (questions run
    /// one at a time; the model calls tools from its own tasks).
    private nonisolated let sink = EventSink()

    public init() {}

    /// Whether questions can be answered on this Mac, and why not.
    public nonisolated static func availability() -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return Availability(available: true, reason: "")
        case .unavailable(.deviceNotEligible):
            return Availability(available: false, reason: "This Mac can't run Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return Availability(available: false, reason: "Turn on Apple Intelligence in System Settings to ask questions.")
        case .unavailable(.modelNotReady):
            return Availability(available: false, reason: "Apple Intelligence is still getting ready. Try again in a few minutes.")
        case .unavailable:
            return Availability(available: false, reason: "Apple Intelligence isn't available right now.")
        }
    }

    static func instructions(now: Date, tools: [String]) -> String {
        """
        You are the assistant of Lowtide, an app running entirely on this Mac. You answer questions about this Mac: \
        its apps, disks, battery, network traffic, terminal commands and package installs, local services, the \
        user's servers and its security. It is now \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())).
        Call exactly one tool, the one whose description fits the question, then answer from its result. Tool \
        results are already ranked: the first item is the largest. Never invent apps, numbers, hosts or countries; \
        copy numbers exactly. Answer in one or two short sentences, leading with the answer. If the result has \
        nothing on it, say so plainly.\(tools.isEmpty ? "" : " If no tool fits the question, say Lowtide can't see that yet.")
        """
    }

    func session(_ key: String) -> LanguageModelSession {
        if let existing = sessions[key] { return existing }
        let wired = AskTools.wired
        let report: @Sendable (AskEvent) -> Void = { [sink] event in sink.yield(event) }
        let tools: [any Tool] = wired.map { DynamicTool($0, report: report) }
        let created = LanguageModelSession(tools: tools, instructions: Self.instructions(now: .now, tools: wired.map(\.name)))
        sessions[key] = created
        return created
    }

    /// Warms the model so the first answer starts sooner.
    public func prewarm() {
        guard Self.availability().available else { return }
        session("default").prewarm()
    }

    /// Starts a new conversation under `key` (the model forgets the old one).
    public func reset(_ key: String) { sessions[key] = nil }

    /// Answers `question`, streaming what happens. Cancelling the consuming
    /// task stops the answer.
    public nonisolated func ask(_ question: String, conversation: String) -> AsyncStream<AskEvent> {
        AsyncStream { continuation in
            let task = Task { await self.answer(question, conversation: conversation, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ question: String, conversation: String, into continuation: AsyncStream<AskEvent>.Continuation,
                        retry: Bool = true) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let availability = Self.availability()
        guard !question.isEmpty, availability.available else {
            continuation.yield(.failed(question.isEmpty ? "Ask something first." : availability.reason))
            continuation.finish()
            return
        }
        sink.set(continuation)
        defer { sink.set(nil) }
        let session = session(conversation)
        do {
            var text = ""
            for try await snapshot in session.streamResponse(to: question) {
                try Task.checkCancellation()
                text = snapshot.content
                continuation.yield(.partial(text))
            }
            continuation.yield(.done(text))
        } catch is CancellationError {
        } catch {
            let (contextFull, message) = Self.explain(error)
            if contextFull, retry {
                // A long conversation filled the model's memory: start afresh.
                sessions[conversation] = nil
                await answer(question, conversation: conversation, into: continuation, retry: false)
                return
            }
            continuation.yield(.failed(message))
        }
        continuation.finish()
    }

    /// Whether the conversation outgrew the model's memory, and what to say.
    static func explain(_ error: any Error) -> (Bool, String) {
        if #available(macOS 27, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return (true, "The conversation got too long. Start a new chat.")
            case .guardrailViolation, .refusal: return (false, "The on-device model declined to answer that.")
            case .unsupportedLanguageOrLocale: return (false, "Ask in a language Apple Intelligence supports.")
            case .rateLimited, .timeout: return (false, "The on-device model is busy. Try again in a moment.")
            default: return (false, "The on-device model couldn't answer (\(error.localizedDescription)).")
            }
        }
        guard let error = error as? LanguageModelSession.GenerationError else { return (false, error.localizedDescription) }
        switch error {
        case .exceededContextWindowSize: return (true, "The conversation got too long. Start a new chat.")
        case .guardrailViolation: return (false, "The on-device model declined to answer that.")
        case .unsupportedLanguageOrLocale: return (false, "Ask in a language Apple Intelligence supports.")
        case .rateLimited: return (false, "The on-device model is busy. Try again in a moment.")
        case .assetsUnavailable: return (false, "Apple Intelligence is still getting ready. Try again in a few minutes.")
        default: return (false, "The on-device model couldn't answer (\(error.localizedDescription)).")
        }
    }
}

/// The running question's stream, shared with the tools.
final class EventSink: Sendable {
    private let current = Mutex<AsyncStream<AskEvent>.Continuation?>(nil)
    func set(_ continuation: AsyncStream<AskEvent>.Continuation?) { current.withLock { $0 = continuation } }
    func yield(_ event: AskEvent) { _ = current.withLock { $0?.yield(event) } }
}

/// One of `AskTools` as a FoundationModels tool: its parameters as a schema
/// built at runtime, its arguments read back by name.
struct DynamicTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let declared: [AskTool.Parameter]
    let report: @Sendable (AskEvent) -> Void

    init(_ tool: AskTool, report: @escaping @Sendable (AskEvent) -> Void) {
        name = tool.name
        description = tool.description
        declared = tool.parameters
        parameters = Self.schema(tool)
        self.report = report
    }

    static func schema(_ tool: AskTool) -> GenerationSchema {
        let properties = tool.parameters.map { parameter -> DynamicGenerationSchema.Property in
            switch parameter {
            case .integer(let name, let description, let range):
                DynamicGenerationSchema.Property(name: name, description: description,
                                                 schema: DynamicGenerationSchema(type: Int.self, guides: [.range(range)]))
            case .text(let name, let description):
                DynamicGenerationSchema.Property(name: name, description: description, schema: DynamicGenerationSchema(type: String.self))
            case .flag(let name, let description):
                DynamicGenerationSchema.Property(name: name, description: description, schema: DynamicGenerationSchema(type: Bool.self))
            }
        }
        let root = DynamicGenerationSchema(name: "\(tool.name)_arguments", properties: properties)
        do { return try GenerationSchema(root: root, dependencies: []) } catch {
            // A schema with no properties always builds.
            return try! GenerationSchema(root: DynamicGenerationSchema(name: "\(tool.name)_arguments", properties: []), dependencies: [])
        }
    }

    func arguments(_ content: GeneratedContent) -> AskArguments {
        var out = AskArguments()
        for parameter in declared {
            switch parameter {
            case .integer(let name, _, let range):
                if let value = try? content.value(Int.self, forProperty: name) {
                    out.integers[name] = min(max(value, range.lowerBound), range.upperBound)
                }
            case .text(let name, _):
                if let value = try? content.value(String.self, forProperty: name) { out.texts[name] = value }
            case .flag(let name, _):
                if let value = try? content.value(Bool.self, forProperty: name) { out.flags[name] = value }
            }
        }
        return out
    }

    @concurrent func call(arguments content: GeneratedContent) async throws -> String {
        let args = arguments(content)
        report(.tool(name: name, arguments: args))
        return await AskTools.run(name, args)
    }
}
