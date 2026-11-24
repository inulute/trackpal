// Listener.swift — "Hey Bizzy": listens for its name, then hears what you say and hands it to the brain.
//
// Speech recognition runs on the Mac only (requiresOnDeviceRecognition): audio never leaves the computer.
// If this Mac can't recognise speech on-device, listening stays off rather than sending audio to a server.
// While Bizzy is talking, what the mic hears is ignored so it doesn't answer itself.

import AVFoundation
import Speech

/// With TRACKPAL_LOG=/some/file set, appends debug lines there (what it heard, why it stopped).
func debugLog(_ msg: String) {
    guard let path = ProcessInfo.processInfo.environment["TRACKPAL_LOG"] else { return }
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
}

final class Listener {
    /// Heard its name. Show that it's listening.
    var onWake: (() -> Void)?
    /// The words heard so far after the name (live, for the speech bubble).
    var onHeard: ((String) -> Void)?
    /// A finished request, e.g. "what time is it".
    var onCommand: ((String) -> Void)?
    /// Woke up but nothing was said; going back to waiting for its name.
    var onDoze: (() -> Void)?

    private(set) var running = false
    private(set) var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()

    private enum State { case waiting, awake(since: Date) }
    private var state = State.waiting
    private var paused = false
    private var silenceTimer: Timer?
    private var awakeTimeout: Timer?
    private var restartTimer: Timer?
    private var lastCommandText = ""

    /// "Hey Bizzy" (or Hi/OK/Yo), and what speech recognition tends to hear instead. The greeting is required,
    /// so "busy" on its own doesn't wake it.
    private let wake = try! NSRegularExpression(pattern: #"(?:\b(?:hey|hi|hello|ok|okay|yo)[ ,]+(?:bizzy|bizzie|bizzi|bizzee|bizy|busy|busey|lizzie|lizzy|dizzy|bitsy)\b)[ ,.!?]*"#, options: [.caseInsensitive])

    // MARK: Start / stop

    /// Asks for microphone and speech permission (first time only), then starts listening.
    func start(completion: @escaping (Bool) -> Void) {
        guard let recognizer else { problem = "speech recognition isn't available for English"; completion(false); return }
        guard recognizer.supportsOnDeviceRecognition else {
            problem = "this Mac can't recognise speech on-device"; completion(false); return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    guard status == .authorized else { self.problem = "allow Speech Recognition in System Settings › Privacy"; completion(false); return }
                    guard micOK else { self.problem = "allow the Microphone in System Settings › Privacy"; completion(false); return }
                    debugLog("speech auth \(status.rawValue), mic \(micOK)")
                    do {
                        try self.startEngine()
                        self.problem = nil
                        completion(true)
                    } catch {
                        debugLog("engine failed: \(error)")
                        self.problem = "couldn't open the microphone"
                        completion(false)
                    }
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        endTask()
        [silenceTimer, awakeTimeout, restartTimer].forEach { $0?.invalidate() }
        state = .waiting
    }

    /// Ignores the mic (while Bizzy talks). `resume` starts fresh so it doesn't act on its own voice.
    func pause() { paused = true; silenceTimer?.invalidate() }
    func resume() {
        guard paused else { return }
        paused = false
        if running { newTask() }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            lock.lock(); let r = request; lock.unlock()
            r?.append(buf)
        }
        engine.prepare()
        try engine.start()
        running = true
        newTask()
        // Recognition tasks are limited to about a minute; start a new one regularly while waiting.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, case .waiting = state, Date().timeIntervalSince(taskStarted) > 50 else { return }
            newTask()
        }
    }

    // MARK: Recognition

    private func endTask() {
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
    }

    private func newTask() {
        endTask()
        guard running, let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = true
        r.addsPunctuation = true
        r.contextualStrings = ["Bizzy", "Hey Bizzy"]
        r.taskHint = .dictation
        lock.lock(); request = r; lock.unlock()
        taskStarted = Date()
        lastCommandText = ""
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error, request: r) }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, request r: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); let current = request === r; lock.unlock()
        guard current, running else { return }
        if let error { debugLog("recognition error: \(error.localizedDescription)") }
        if let result { debugLog("heard\(paused ? " (paused)" : ""): \(result.bestTranscription.formattedString)") }
        if error != nil {
            // Usually "no speech" or the task timing out: just start listening again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, running else { return }
                lock.lock(); let still = request === r; lock.unlock()
                if still { newTask() }
            }
            return
        }
        guard let result else { return }
        // A finished task hears nothing more: start a fresh one (unless the code below takes over).
        defer {
            if result.isFinal, case .waiting = state {
                lock.lock(); let still = request === r; lock.unlock()
                if still { newTask() }
            }
        }
        guard !paused else { return }
        let text = result.bestTranscription.formattedString

        switch state {
        case .waiting:
            let ns = text as NSString
            guard let m = wake.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return }
            state = .awake(since: Date())
            onWake?()
            // Keep the same recognition task (restarting mid-sentence loses words); the request is whatever
            // comes after the last "Hey Bizzy" in this transcript.
            let after = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { lastCommandText = after; onHeard?(after); armSilence() }
            armAwakeTimeout()
        case .awake:
            let cleaned = afterLastWake(text)
            guard !cleaned.isEmpty else { return }
            lastCommandText = cleaned
            onHeard?(cleaned)
            awakeTimeout?.invalidate()
            armSilence()
            if result.isFinal { finishCommand() }
        }
    }

    /// The words after the last "Hey Bizzy" (or all of them, if the task restarted after it).
    private func afterLastWake(_ text: String) -> String {
        let ns = text as NSString
        guard let m = wake.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When you stop talking for a moment, the request is done.
    private func armSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in self?.finishCommand() }
    }

    /// Woken but nothing said for a while: doze off again.
    private func armAwakeTimeout() {
        awakeTimeout?.invalidate()
        awakeTimeout = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
            guard let self, case .awake = state, lastCommandText.isEmpty else { return }
            state = .waiting
            newTask()
            onDoze?()
        }
    }

    private func finishCommand() {
        silenceTimer?.invalidate(); awakeTimeout?.invalidate()
        guard case .awake = state else { return }
        let command = lastCommandText
        state = .waiting
        newTask()
        if command.isEmpty { onDoze?() } else { onCommand?(command) }
    }
}
