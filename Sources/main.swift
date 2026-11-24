// main.swift — wires it together: senses → brain → face + voice, a chat box, and a menu bar item.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let pet = PetWindow()
    let chatBox = ChatPanel()
    let voice = Voice()
    let brain = Brain()
    let senses = Senses()
    let listener = Listener()
    var listening = UserDefaults.standard.object(forKey: "listen") as? Bool ?? true
    var statusItem: NSStatusItem!
    var quiet = UserDefaults.standard.bool(forKey: "quiet")
    var moodResetWork: DispatchWorkItem?
    var bubbleHideWork: DispatchWorkItem?
    var baseMood: Mood = .idle
    var thinking = false { didSet { pet.face.thinking = thinking } }

    func applicationDidFinishLaunching(_ note: Notification) {
        if UserDefaults.standard.string(forKey: "output") == "speakers" { voice.output = .speakers }

        pet.orderFrontRegardless()
        pet.face.onPoke = { [weak self] in self?.voice.boopIfIdle(); self?.senses.poked() }
        pet.face.onDoubleClick = { [weak self] in self?.openChat() }
        // Right-click Pip for its menu (the menu bar icon can be hidden behind the notch).
        pet.face.onRightClick = { [weak self] e in
            guard let self, let menu = statusItem.menu else { return }
            NSMenu.popUpContextMenu(menu, with: e, for: pet.face)
        }
        chatBox.onSend = { [weak self] text in self?.userSaid(text) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◕‿◕"
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        senses.onEvent = { [weak self] e in self?.handle(e) }
        senses.onTypingChanged = { [weak self] typing in
            guard let self else { return }
            baseMood = typing ? .focused : .idle
            if moodResetWork == nil { pet.face.mood = baseMood }
        }
        senses.start()

        listener.onWake = { [weak self] in
            guard let self else { return }
            voice.stop()
            voice.boopIfIdle()              // a little chirp: "I heard you"
            bubbleHideWork?.cancel()
            pet.face.listening = true
            pet.face.bubbleText = "Yes?"
            setMood(.surprised, for: 8)
        }
        listener.onHeard = { [weak self] text in
            self?.pet.face.bubbleText = "“\(text)”"
            self?.setMood(.focused, for: 8)
        }
        listener.onCommand = { [weak self] text in
            guard let self else { return }
            pet.face.listening = false
            pet.face.bubbleText = nil
            userSaid(text)
        }
        listener.onDoze = { [weak self] in
            guard let self else { return }
            pet.face.listening = false
            pet.face.bubbleText = nil
            setMood(.idle, for: 1)
        }
        if listening { startListening() }
        NSLog("trackpadai: brain = %@, voice = %@", brain.engineLabel, voice.hasTrackpad ? "trackpad" : "speakers")
    }

    // MARK: Reacting

    func handle(_ e: Event) {
        brain.note(e)
        let quick = brain.scripted(e)
        // The face reacts instantly; the words follow once the brain has thought about it.
        setMood(quick.mood, for: 6)
        guard quick.line != nil || e.kind == "musing", brain.shouldSpeak(e), !voice.isSpeaking, !thinking else { return }
        brain.markSpoke(e)
        // Pokes answer instantly; a 2-second think would feel laggy.
        if e.kind == "poke" { speak(quick.line!, mood: quick.mood); return }
        think { await self.brain.think(e, snapshot: self.senses.snapshot) }
    }

    func userSaid(_ text: String) {
        voice.stop()
        think { await self.brain.chat(text, snapshot: self.senses.snapshot) }
    }

    /// Runs the brain off the main thread with a "thinking" bubble, then speaks the result.
    func think(_ work: @escaping () async -> Reaction) {
        thinking = true
        Task { @MainActor in
            let r = await work()
            thinking = false
            if let line = r.line { speak(line, mood: r.mood) } else { setMood(r.mood, for: 5) }
        }
    }

    func speak(_ line: String, mood: Mood) {
        bubbleHideWork?.cancel()
        pet.face.listening = false
        // On the trackpad the words appear as they're buzzed, karaoke-style: reading along is what makes the
        // haptic voice easy to follow.
        let karaoke = voice.output == .trackpad && voice.hasTrackpad && !quiet
        pet.face.bubbleText = karaoke ? nil : line
        pet.face.thinking = karaoke            // dots until the first word is buzzed
        setMood(mood, for: 60)
        let finish = { [weak self] in
            guard let self else { return }
            pet.face.mouthLevel = 0
            setMood(mood, for: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.listener.resume() }
            let hide = DispatchWorkItem { [weak self] in self?.pet.face.bubbleText = nil }
            bubbleHideWork = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
        }
        if quiet {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(2.5, Double(line.count) / 14), execute: finish)
            return
        }
        // If it's mid-sentence, cut that off and say the new line once it has stopped.
        if voice.isSpeaking {
            voice.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.speak(line, mood: mood) }
            return
        }
        listener.pause()   // don't hear itself
        let started = voice.say(line, onLevel: { [weak self] l, progress in
            guard let self else { return }
            pet.face.mouthLevel = CGFloat(l)
            if karaoke, case let shown = Self.revealed(line, progress), shown != " " {
                pet.face.thinking = false
                pet.face.bubbleText = shown
            }
        }, done: { [weak self] in
            self?.pet.face.thinking = false
            self?.pet.face.bubbleText = line
            finish()
        })
        if !started { pet.face.thinking = false; pet.face.bubbleText = line; finish() }
    }

    /// The part of `line` that has been "said" by `progress` (0…1), rounded up to whole words and a little
    /// ahead of the sound so your eyes lead your ears.
    static func revealed(_ line: String, _ progress: Double) -> String {
        let n = min(line.count, Int(Double(line.count) * min(1, progress + 0.06)))
        var end = line.index(line.startIndex, offsetBy: n)
        while end < line.endIndex, line[end] != " " { end = line.index(after: end) }
        let shown = String(line[..<end])
        return shown.isEmpty ? " " : shown
    }

    func setMood(_ m: Mood, for seconds: Double) {
        moodResetWork?.cancel()
        pet.face.mood = m
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            moodResetWork = nil
            pet.face.mood = baseMood
        }
        moodResetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func openChat() {
        NSApp.activate(ignoringOtherApps: true)
        chatBox.show(below: pet)
        setMood(.happy, for: 3)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        @discardableResult
        func item(_ title: String, _ action: Selector?, on: Bool = false, enabled: Bool = true, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off; i.isEnabled = enabled && action != nil; i.tag = tag
            menu.addItem(i)
            return i
        }
        item("Talk to \(brain.name)…  (or double-click it)", #selector(talk))
        item("Say something", #selector(saySomething))
        menu.addItem(.separator())

        item("Brain: \(brain.engineLabel)", nil)
        if let err = Brain.lastError { item("  ⚠︎ Last call failed: \(err)", nil) }
        item("  Automatic (a key you added, else on-device)", #selector(pickEngine(_:)), on: brain.engine == .auto, tag: 0)
        let apple = AppleModel.unavailableReason
        item("  Apple on-device model" + (apple.map { " (\($0))" } ?? ""), #selector(pickEngine(_:)), on: brain.engine == .apple, enabled: apple == nil, tag: 1)
        item("  Google Gemini" + (brain.geminiKey == nil ? " (no key yet)" : ""), #selector(pickEngine(_:)), on: brain.engine == .gemini, enabled: brain.geminiKey != nil, tag: 3)
        item("  Claude" + (brain.apiKey == nil ? " (no key yet)" : ""), #selector(pickEngine(_:)), on: brain.engine == .claude, enabled: brain.apiKey != nil, tag: 2)
        item("  Built-in lines only", #selector(pickEngine(_:)), on: brain.engine == .scripted, tag: 4)
        item(brain.geminiKey == nil ? "  Add a Gemini key…" : "  Change Gemini key…", #selector(addGeminiKey))
        item(brain.apiKey == nil ? "  Add a Claude key…" : "  Change Claude key…", #selector(addClaudeKey))
        if !brain.facts.isEmpty { item("  Forget what \(brain.name) knows about me (\(brain.facts.count))", #selector(forget)) }
        menu.addItem(.separator())

        item("Voice", nil)
        item(voice.hasTrackpad ? "  Through the trackpad" : "  Through the trackpad (no Force Touch found)",
             #selector(useTrackpad), on: voice.output == .trackpad && !quiet, enabled: voice.hasTrackpad)
        item("  Through the speakers", #selector(useSpeakers), on: voice.output == .speakers && !quiet)
        item("  Quiet (speech bubble only)", #selector(toggleQuiet), on: quiet)
        if voice.hasTrackpad {
            let sub = NSMenu()
            func voiceItem(_ title: String, _ name: String?) {
                let i = NSMenuItem(title: title, action: #selector(pickVoice(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = name ?? "default"; i.state = voice.style.voice == name ? .on : .off
                sub.addItem(i)
            }
            for (n, v) in Voice.clearVoices.enumerated() where installedVoices.contains(v) {
                let short = v.components(separatedBy: " (").first ?? v
                voiceItem(n == 0 ? "\(short) (clearest)" : short, v)
            }
            voiceItem("System voice", nil)
            sub.addItem(.separator())
            for (title, rate) in [("Slower", 150), ("Normal speed", 0)] {
                let i = NSMenuItem(title: title, action: #selector(pickRate(_:)), keyEquivalent: "")
                i.target = self; i.tag = rate; i.state = (voice.style.rate ?? 0) == rate ? .on : .off
                sub.addItem(i)
            }
            sub.addItem(.separator())
            let test = NSMenuItem(title: "Test the voice", action: #selector(testVoice), keyEquivalent: ""); test.target = self
            sub.addItem(test)
            let v = NSMenuItem(title: "  Trackpad voice", action: nil, keyEquivalent: ""); v.submenu = sub
            menu.addItem(v)
        }
        menu.addItem(.separator())

        item("Listen for “Hey \(brain.name)”" + (listening ? (listener.running ? "" : " (\(listener.problem ?? "starting…"))") : ""),
             #selector(toggleListening), on: listening && listener.running)
        if senses.keyboardAllowed {
            item("Keyboard reactions: on", nil)
        } else {
            item("Turn on keyboard reactions…", #selector(askKeyboard))
        }
        item(pet.isVisible ? "Hide \(brain.name)" : "Show \(brain.name)", #selector(toggleVisible))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func talk() { openChat() }
    @objc func saySomething() { brain.markSpoke(.musing); think { await self.brain.think(.musing, snapshot: self.senses.snapshot) } }
    @objc func pickEngine(_ sender: NSMenuItem) { brain.engine = [.auto, .apple, .claude, .gemini, .scripted][sender.tag] }
    @objc func addGeminiKey() { askForKey(provider: "gemini", title: "Google Gemini API key", hint: "Get one free at aistudio.google.com › Get API key.", engine: .gemini) }
    @objc func addClaudeKey() { askForKey(provider: "anthropic", title: "Claude API key", hint: "Get one at platform.claude.com › API keys.", engine: .claude) }

    /// A small dialog to paste a key. Saved to ~/.trackpadai/<provider>_key, readable only by you.
    func askForKey(provider: String, title: String, hint: String, engine: Brain.Engine) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = hint + "\nIt's stored only on this Mac, in ~/.trackpadai/\(provider)_key."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Paste key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Brain.saveKey(provider, key)
        brain.engine = engine
        think { await self.brain.chat("I just gave you a new brain. Say hi in a few words!", snapshot: self.senses.snapshot) }
    }

    func startListening() {
        listener.start { [weak self] ok in
            guard let self, !ok else { return }
            NSLog("trackpadai: listening off: %@", listener.problem ?? "?")
        }
    }
    @objc func toggleListening() {
        listening.toggle()
        UserDefaults.standard.set(listening, forKey: "listen")
        if listening { startListening() } else { listener.stop(); pet.face.listening = false }
    }
    @objc func forget() { brain.forgetEverything() }
    /// Which of the clear voices are installed (checked once; `say -v ?` is slow-ish).
    lazy var installedVoices: Set<String> = Set(Voice.clearVoices.filter(Voice.voiceInstalled))

    @objc func pickVoice(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? "default"
        voice.style.voice = name == "default" ? nil : name
        UserDefaults.standard.set(name, forKey: "trackpadVoice")
        testVoice()
    }
    @objc func pickRate(_ sender: NSMenuItem) {
        voice.style.rate = sender.tag == 0 ? nil : sender.tag
        UserDefaults.standard.set(sender.tag, forKey: "trackpadRate")
        testVoice()
    }
    @objc func testVoice() {
        voice.output = .trackpad; quiet = false; save()
        speak("Hi, I'm \(brain.name). Can you understand me now?", mood: .happy)
    }
    @objc func useTrackpad() { voice.output = .trackpad; quiet = false; save() }
    @objc func useSpeakers() { voice.output = .speakers; quiet = false; save() }
    @objc func toggleQuiet() { quiet.toggle(); if quiet { voice.stop() }; save() }
    @objc func askKeyboard() {
        senses.startKeyboard(prompt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.senses.startKeyboard(prompt: false) }
    }
    @objc func toggleVisible() { pet.isVisible ? pet.orderOut(nil) : pet.orderFrontRegardless() }

    func save() {
        UserDefaults.standard.set(quiet, forKey: "quiet")
        UserDefaults.standard.set(voice.output == .speakers ? "speakers" : "trackpad", forKey: "output")
    }
}

/// `Pip --clarity-test`: compares voice styles by how well speech recognition understands them.
if CommandLine.arguments.contains("--clarity-test") { ClarityTest.run(); exit(0) }

/// `Pip --snapshot <dir>`: draws every mood to <dir>/<mood>.png and exits (for checking the face).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let view = FaceView(frame: NSRect(x: 0, y: 0, width: 250, height: FaceView.faceSize.height + FaceView.bubbleHeight))
    for m in Mood.allCases {
        view.mood = m
        view.bubbleText = m == .happy ? "Hi! I'm Pip." : nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(m.rawValue).png"))
    }
    exit(0)
}

/// `Pip --ask "<event or message>"`: prints what the brain would say, then exits (for testing the brain).
if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
    let brain = Brain()
    let text = CommandLine.arguments[i + 1]
    let snap = Snapshot(app: "Xcode", minutesInApp: 42, keysLastMinute: 210, minutesSinceBreak: 95, typingNow: true, keyboardSeen: true)
    Task {
        print("brain:", brain.engineLabel)
        for e: Event in [.hello(partOfDay: "evening"), .deleteRage(deletes: 31), .appSwitched(app: "Slack"), .longSession(minutes: 95), .musing] {
            brain.note(e)
            let r = await brain.think(e, snapshot: snap)
            print("[\(e.kind)] \(r.mood.rawValue): \(r.line ?? "(silent)")")
        }
        let r = await brain.chat(text, snapshot: snap)
        print("[chat] \(r.mood.rawValue): \(r.line ?? "")" + (r.remember.map { "  (remember: \($0))" } ?? ""))
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar
app.run()
