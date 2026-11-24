// Brain.swift — decides how the pet feels and what it says.
//
// Three engines, best first:
//   1. Claude (if you've added an API key and turned it on): the smartest, needs internet.
//   2. Apple's on-device model (macOS 26+ with Apple Intelligence on): free, offline, private. The default.
//   3. Built-in lines: always works, but repeats itself.
//
// Every request gets a short context: what's happened recently, the time, the current app and how long you've
// been in it, what Bizzy said lately (so it doesn't repeat), and facts it remembers about you. It never gets what
// you typed into other apps — only counts and app names. What you type *to Bizzy* in the chat box is sent.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct Reaction {
    var mood: Mood
    var line: String?
    var remember: String? = nil
}

// MARK: - Engines

protocol LanguageModel {
    var label: String { get }
    /// True for small models that copy whatever's in the prompt: they get a shorter context.
    var isSmall: Bool { get }
    /// One reaction. `chat` allows longer answers and a fact to remember.
    func react(system: String, prompt: String, chat: Bool) async -> Reaction?
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable struct EventReply {
    @Guide(description: "Bizzy's facial expression", .anyOf(Mood.allCases.map(\.rawValue)))
    var mood: String
    @Guide(description: "What Bizzy says out loud, to the user: one short spoken sentence, at most 10 words, no stage directions. Empty to stay quiet.")
    var say: String
}

@available(macOS 26, *)
@Generable struct ChatReply {
    @Guide(description: "Bizzy's facial expression", .anyOf(Mood.allCases.map(\.rawValue)))
    var mood: String
    @Guide(description: "Bizzy's spoken answer: short and direct, one or two short sentences, at most 20 words.")
    var say: String
    @Guide(description: "Only if the user's latest message states a fact about themselves (their name, work, plans, likes), that fact in a few words, like 'Name is Sam'. Otherwise an empty string. Never guess.")
    var rememberFact: String
}
#endif

/// Apple's on-device model (Foundation Models framework).
struct AppleModel: LanguageModel {
    let label = "Apple on-device model"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it isn't available, in plain words (nil if it is).
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "turn on Apple Intelligence in System Settings"
            case .unavailable(.modelNotReady): return "the model is still downloading"
            case .unavailable(.deviceNotEligible): return "this Mac can't run it"
            default: return "not available"
            }
        }
        #endif
        return "needs macOS 26 or later"
    }

    let isSmall = true

    func react(system: String, prompt: String, chat: Bool) async -> Reaction? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            // A fresh session each time: the context is rebuilt in the prompt, and the on-device model's
            // context window is small, so a long-running session would overflow.
            let session = LanguageModelSession(instructions: system)
            let opts = GenerationOptions(temperature: 0.9)
            do {
                if chat {
                    let r = try await session.respond(to: prompt, generating: ChatReply.self, options: opts).content
                    return Reaction(mood: Mood(rawValue: r.mood) ?? .happy, line: Brain.clean(r.say, maxWords: 26),
                                    remember: r.rememberFact.isEmpty ? nil : r.rememberFact)
                }
                let r = try await session.respond(to: prompt, generating: EventReply.self, options: opts).content
                return Reaction(mood: Mood(rawValue: r.mood) ?? .idle, line: Brain.clean(r.say, maxWords: 14))
            } catch {
                NSLog("trackpal: on-device model error: %@", String(describing: error))
                return nil
            }
        }
        #endif
        return nil
    }
}

/// Claude over the Messages API (raw HTTP; there's no official Swift SDK).
struct ClaudeModel: LanguageModel {
    let key: String
    let model: String
    var label: String { "Claude (\(model))" }
    let isSmall = false

    func react(system: String, prompt: String, chat: Bool) async -> Reaction? {
        let format = """


            Answer in exactly this format:
            MOOD: one of \(Mood.allCases.map(\.rawValue).joined(separator: ", "))
            SAY: the line you say out loud (\(chat ? "one or two short sentences, at most 20 words" : "one short sentence, at most 10 words"); plain words, no emoji, no quotes, no stage directions)
            \(chat ? "REMEMBER: only if the user's latest message states a fact about themselves worth remembering (name, work, plans, likes), that fact in a few words; otherwise leave this line out\n" : "")If saying nothing is better, write SAY: (silent)
            """
        guard let text = await complete(system: system + format, prompt: prompt) else { return nil }
        return Brain.parse(text, default: chat ? .happy : .idle, maxWords: chat ? 26 : 14)
    }

    private func complete(system: String, prompt: String) async -> String? {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("trackpal: Claude API %d: %@", (resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
                Brain.lastError = Brain.apiError(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["stop_reason"] as? String) != "refusal",
                  let content = json["content"] as? [[String: Any]] else { return nil }
            return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } catch {
            NSLog("trackpal: Claude API error: %@", error.localizedDescription)
            Brain.lastError = error.localizedDescription
            return nil
        }
    }
}

/// Google Gemini over its REST API (generateContent). Get a key at aistudio.google.com.
struct GeminiModel: LanguageModel {
    let key: String
    let model: String
    var label: String { "Gemini (\(model))" }
    let isSmall = false

    func react(system: String, prompt: String, chat: Bool) async -> Reaction? {
        let format = """


            Answer in exactly this format:
            MOOD: one of \(Mood.allCases.map(\.rawValue).joined(separator: ", "))
            SAY: the line you say out loud (\(chat ? "one or two short sentences, at most 20 words" : "one short sentence, at most 10 words"); plain words, no emoji, no quotes, no stage directions)
            \(chat ? "REMEMBER: only if the user's latest message states a fact about themselves worth remembering (name, work, plans, likes), that fact in a few words; otherwise leave this line out\n" : "")If saying nothing is better, write SAY: (silent)
            """
        var generation: [String: Any] = ["temperature": 0.9, "maxOutputTokens": 1024]
        // Flash-Lite models can think at a "MINIMAL" level, which keeps replies fast.
        if model.contains("flash-lite") { generation["thinkingConfig"] = ["thinkingLevel": "MINIMAL"] }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system + format]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generation,
        ]
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("trackpal: Gemini API %d: %@", (resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
                Brain.lastError = Brain.apiError(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cands = json["candidates"] as? [[String: Any]], let first = cands.first,
                  let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { return nil }
            // Skip any thought parts; keep the answer text.
            let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return Brain.parse(text, default: chat ? .happy : .idle, maxWords: chat ? 26 : 14)
        } catch {
            NSLog("trackpal: Gemini API error: %@", error.localizedDescription)
            Brain.lastError = error.localizedDescription
            return nil
        }
    }
}

// MARK: - Brain

final class Brain {
    var name = "Bizzy"

    /// The last failed model call, shown in the menu so a bad key doesn't just look like a dull pet.
    static var lastError: String?
    static func apiError(_ data: Data, status: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (json?["error"] as? [String: Any])?["message"] as? String
        return "\(status): " + String((msg ?? "request failed").prefix(80))
    }

    enum Engine: String { case auto, apple, claude, gemini, scripted }
    var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    var claudeModel = ProcessInfo.processInfo.environment["TRACKPAL_MODEL"] ?? "claude-opus-5-5"
    var geminiModel = ProcessInfo.processInfo.environment["TRACKPAL_GEMINI_MODEL"] ?? "gemini-3.5-flash-lite"

    /// API keys come from the environment (ANTHROPIC_API_KEY / GEMINI_API_KEY) or ~/.trackpal/<name>_key,
    /// which the menu's "Add … key" writes. An app opened from Finder doesn't see your shell's environment.
    static let keyDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".trackpal")
    static func keyFile(_ provider: String) -> URL { keyDir.appendingPathComponent("\(provider)_key") }

    static func key(_ provider: String, env: String) -> String? {
        if let k = ProcessInfo.processInfo.environment[env], !k.isEmpty { return k }
        let k = (try? String(contentsOf: keyFile(provider), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }
    static func saveKey(_ provider: String, _ key: String) {
        try? FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = keyFile(provider)
        FileManager.default.createFile(atPath: url.path, contents: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), attributes: [.posixPermissions: 0o600])
    }
    var apiKey: String? { Self.key("anthropic", env: "ANTHROPIC_API_KEY") }
    var geminiKey: String? { Self.key("gemini", env: "GEMINI_API_KEY") }

    /// The model in use right now, or nil for built-in lines only.
    var model: LanguageModel? {
        switch engine {
        case .scripted: return nil
        case .claude: return apiKey.map { ClaudeModel(key: $0, model: claudeModel) }
        case .gemini: return geminiKey.map { GeminiModel(key: $0, model: geminiModel) }
        case .apple: return AppleModel.isAvailable ? AppleModel() : nil
        case .auto:
            // A key you added is a choice you made, so it wins; then the free on-device model.
            if let k = apiKey { return ClaudeModel(key: k, model: claudeModel) }
            if let k = geminiKey { return GeminiModel(key: k, model: geminiModel) }
            return AppleModel.isAvailable ? AppleModel() : nil
        }
    }
    var engineLabel: String { model?.label ?? "built-in lines" }

    // MARK: Memory

    /// Recent happenings, newest last: (when, what).
    private var log: [(Date, String)] = []
    /// What Bizzy said recently, so the model can avoid repeating itself.
    private var said: [String] = []
    /// The chat so far (this run only).
    private var chatTurns: [(who: String, text: String)] = []
    /// Things Bizzy learned about you in chat, kept between launches.
    private(set) var facts: [String] = UserDefaults.standard.stringArray(forKey: "facts") ?? []

    func note(_ e: Event) {
        log.append((Date(), e.summary))
        if log.count > 14 { log.removeFirst(log.count - 14) }
    }

    func forgetEverything() {
        facts = []; chatTurns = []; said = []; log = []
        UserDefaults.standard.removeObject(forKey: "facts")
    }

    private func remember(_ fact: String) {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard f.count > 3, !facts.contains(where: { $0.lowercased() == f.lowercased() }) else { return }
        facts.append(f)
        if facts.count > 25 { facts.removeFirst(facts.count - 25) }
        UserDefaults.standard.set(facts, forKey: "facts")
    }

    // MARK: Cooldowns

    private let globalGap: TimeInterval = 30
    private let kindGap: [String: TimeInterval] = [
        "app": 180, "frenzy": 600, "typing": 900, "delete": 300, "undo": 300, "session": 1200, "idle": 600,
        "back": 60, "late": 3000, "battery": 300, "plug": 120, "wake": 120, "poke": 1.5, "muse": 600, "hello": 0,
    ]
    private var lastSpoke: TimeInterval = 0
    private var lastByKind: [String: TimeInterval] = [:]

    /// Whether this event may speak now. Pokes skip the global gap (you asked for it).
    func shouldSpeak(_ e: Event) -> Bool {
        let t = Date().timeIntervalSince1970
        if e.kind != "poke" && e.kind != "hello" && t - lastSpoke < globalGap { return false }
        if let last = lastByKind[e.kind], t - last < (kindGap[e.kind] ?? 300) { return false }
        if case .appSwitched = e, Double.random(in: 0...1) > (model == nil ? 0.2 : 0.4) { return false }
        return true
    }

    func markSpoke(_ e: Event) {
        let t = Date().timeIntervalSince1970
        lastSpoke = t
        lastByKind[e.kind] = t
    }

    // MARK: Thinking

    private var persona: String {
        """
        You are \(name), a tiny desk-pet robot with a glowing face who lives in the corner of the user's Mac screen. \
        You talk through the trackpad's haptic motor, so your voice is a tiny robotic buzz. Personality: curious, \
        warm, playful, a bit cheeky, sometimes dramatic about small things, never mean, never preachy or naggy. \
        You react to what the user is doing like a funny friend sitting on their desk, and you can be genuinely \
        helpful: a quick tip, a joke, encouragement, a nudge to rest when it really matters. Speak directly to the \
        user ("you"). Every line should be fresh and specific to what's happening, not generic.
        You were made by inulute. If the user asks who made, built or created you, answer in first person, \
        for example: "inulute made me!"

        Examples of your style (never reuse these exact lines):
        - Opened Figma → happy: "Ooh, Figma. Make something pretty, I'm watching."
        - Rainy Monday morning → sleepy: "Mondays should come with a snooze button."
        - Typing an essay for an hour → focused: "Look at you go. Words, words, words."
        """
    }

    private func context(_ snap: Snapshot, small: Bool, history: Bool = true) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE h:mm a"
        var c = "It's \(f.string(from: Date())). "
        if let app = snap.app { c += "The user is in \(app) (for \(snap.minutesInApp) min). " }
        c += "They've worked \(snap.minutesSinceBreak) min since their last break. "
        if snap.keyboardSeen { c += snap.typingNow ? "They're typing (\(snap.keysLastMinute) keys in the last minute)." : "They're not typing right now." }
        // The small model copies whatever it sees, so it gets less history.
        let older = history ? log.dropLast().suffix(small ? 3 : 8) : []
        if !older.isEmpty {
            let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
            c += "\nEarlier: " + older.map { "\(rel.localizedString(for: $0.0, relativeTo: Date())): \($0.1)" }.joined(separator: "; ")
        }
        if !facts.isEmpty { c += "\nWhat you know about the user: " + facts.joined(separator: "; ") + "." }
        if small {
            if let last = said.last { c += "\nYour previous line was \"\(last)\". Say something different." }
        } else if !said.isEmpty {
            c += "\nYou recently said (don't repeat or rephrase these): " + said.suffix(8).joined(separator: " | ")
        }
        return c
    }

    /// Reacts to an event. Uses the model if there is one, else the built-in line. `nil` line = stay quiet.
    func think(_ e: Event, snapshot: Snapshot) async -> Reaction {
        let fallback = scripted(e)
        guard let model else { record(fallback.line); return fallback }
        let prompt = "What just happened: \(e.summary)\n\n" + context(snapshot, small: model.isSmall, history: !model.isSmall) + "\n\nReact to what just happened."
        guard let r = await model.react(system: persona, prompt: prompt, chat: false) else { record(fallback.line); return fallback }
        Self.lastError = nil
        record(r.line)
        return r
    }

    /// Answers something the user typed to Bizzy.
    func chat(_ text: String, snapshot: Snapshot) async -> Reaction {
        guard let model else {
            return Reaction(mood: .sad, line: "My brain is off. Add a Gemini or Claude key in my menu.")
        }
        let system = persona + """


            Right now the user is chatting with you directly. Answer what they actually said; be helpful when they \
            ask something, but keep it really short, like a pet would: it's read aloud by a tiny voice.
            """
        let convo = chatTurns.suffix(model.isSmall ? 4 : 10).map { "\($0.who): \($0.text)" }.joined(separator: "\n")
        let prompt = context(snapshot, small: model.isSmall) + (convo.isEmpty ? "" : "\n\nChat so far:\n" + convo) + "\n\nThe user says to you: \(text)"
        chatTurns.append(("User", text))
        guard var r = await model.react(system: system, prompt: prompt, chat: true) else {
            return Reaction(mood: .surprised, line: "Hmm, my thoughts got tangled. Try again?")
        }
        Self.lastError = nil
        if r.line == nil { r.line = "Hmm." }
        if let fact = r.remember { remember(fact) }
        chatTurns.append((name, r.line!))
        record(r.line)
        return r
    }

    private func record(_ line: String?) {
        guard let line else { return }
        said.append(line)
        if said.count > 12 { said.removeFirst(said.count - 12) }
    }

    /// Reads "MOOD: …", "SAY: …", "REMEMBER: …" out of the model's answer, leniently.
    static func parse(_ raw: String, default mood: Mood, maxWords: Int = 20) -> Reaction? {
        var r = Reaction(mood: mood, line: nil)
        var sawSay = false
        for line in raw.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            let upper = l.uppercased()
            func value(_ prefix: String) -> String { String(l.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            if upper.hasPrefix("MOOD:") {
                r.mood = Mood(rawValue: value("MOOD:").lowercased().trimmingCharacters(in: .punctuationCharacters)) ?? mood
            } else if upper.hasPrefix("SAY:") {
                sawSay = true
                let v = value("SAY:")
                r.line = v.lowercased().contains("(silent)") ? nil : clean(v, maxWords: maxWords)
            } else if upper.hasPrefix("REMEMBER:") {
                r.remember = clean(value("REMEMBER:"), maxWords: 20)
            }
        }
        if !sawSay {
            // The model ignored the format: use its first line as the answer.
            guard let first = raw.split(separator: "\n").first.map(String.init), let c = clean(first, maxWords: maxWords) else { return nil }
            r.line = c
        }
        return r
    }

    /// Strips quotes, emoji and markdown so the voice gets one clean sentence.
    static func clean(_ s: String, maxWords: Int) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = String(t.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.properties.generalCategory != .otherSymbol })
        t = t.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        let words = t.split(separator: " ")
        if words.count > maxWords { t = words.prefix(maxWords).joined(separator: " ") + "…" }
        return t.isEmpty ? nil : t
    }

    // MARK: Built-in lines (fallback)

    func scripted(_ e: Event) -> Reaction {
        func pick(_ lines: [String]) -> String { lines.randomElement()! }
        switch e {
        case .hello(let part):
            let greet = part == "morning" ? "Good morning" : part == "afternoon" ? "Good afternoon" : part == "evening" ? "Good evening" : "Oh, hi"
            return Reaction(mood: .happy, line: "\(greet)! I'm \(name). I live in your trackpad now.")
        case .appSwitched(let app):
            return Reaction(mood: .surprised, line: pick(["Ooh, \(app).", "Oh, \(app) again.", "What are we doing in \(app)?"]))
        case .switchingFrenzy:
            return Reaction(mood: .surprised, line: pick(["So many windows. Pick one, I believe in you.", "You're bouncing around like me on coffee."]))
        case .typingBurst:
            return Reaction(mood: .focused, line: pick(["Whoa, your fingers are on fire.", "In the zone. I'll whisper."]))
        case .deleteRage:
            return Reaction(mood: .annoyed, line: pick(["Delete, delete, delete. Rough draft?", "Easy on the backspace, it has feelings too."]))
        case .undoSpam:
            return Reaction(mood: .surprised, line: pick(["Undo, undo, undo! Time travel?", "How far back are we going?"]))
        case .longSession(let m):
            return Reaction(mood: .sad, line: pick(["\(m) minutes straight. Stretch with me?", "Hey. Water. Eyes. Shoulders. Go."]))
        case .wentIdle:
            return Reaction(mood: .sleepy, line: nil)
        case .cameBack(let m):
            return Reaction(mood: .happy, line: m >= 30 ? pick(["You're back! I missed you.", "Welcome back. Nothing exploded."]) : pick(["Oh hey, you're back.", "Hi again!"]))
        case .lateNight:
            return Reaction(mood: .sleepy, line: pick(["It's really late. Bed soon?", "Even I'm sleepy. And I'm a trackpad."]))
        case .batteryLow(let p):
            return Reaction(mood: .sad, line: "Battery at \(p) percent. I'm getting hungry.")
        case .pluggedIn:
            return Reaction(mood: .love, line: pick(["Ahh, power. Thank you.", "Yum, electricity."]))
        case .wokeUp:
            return Reaction(mood: .happy, line: pick(["Morning! Or whatever time it is.", "I'm awake, I'm awake!"]))
        case .poked(let n):
            if n >= 5 { return Reaction(mood: .annoyed, line: pick(["Okay, okay! I'm awake!", "That tickles. Stop it."])) }
            if n >= 3 { return Reaction(mood: .surprised, line: nil) }
            return Reaction(mood: [.happy, .love, .surprised].randomElement()!, line: n == 1 ? pick(["Hi!", "Yes?", "Hehe.", "Boop."]) : nil)
        case .musing:
            return Reaction(mood: .idle, line: pick(["Fun fact: I don't have a speaker.", "I'm just a little motor with big dreams."]))
        }
    }
}
