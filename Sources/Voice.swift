// Voice.swift — how the pet talks.
//
// The haptic part (trackpad motor + formant analysis) is adapted from NO SPEAKER by Cody Collier,
// https://github.com/os6/nospeaker, MIT License (see NOTICE). It drives the Force Touch motor through
// MultitouchSupport, a private framework, so a macOS update could break it. The motor is never driven past
// its normal maximum.
//
// If no Force Touch trackpad is found, the pet talks through the speakers instead.

import AVFoundation
import Darwin
import Foundation

// MARK: - Clock

private var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
private let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)

/// Set from any thread to cut the current line short.
var voiceStopRequested = false

/// Sleeps until a moment on the clock, spinning only for the last ~1.5 ms to keep timing tight.
private func waitUntil(_ t: UInt64) {
    let margin = UInt64(0.0015 * ticksPerSecond)
    while !voiceStopRequested {
        let n = mach_absolute_time()
        if n >= t { return }
        if t - n > margin { usleep(useconds_t(Double(t - n - margin) / ticksPerSecond * 1e6)) }
    }
}

// MARK: - The haptic motor (MultitouchSupport, resolved at run time)

private let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
private func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mt, let p = dlsym(mt, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

private let createList = sym("MTDeviceCreateList", CreateList.self)
private let getID = sym("MTDeviceGetDeviceID", GetID.self)
private let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
private let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
private let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
private let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
private let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)

/// Opens the first Force Touch motor it finds (built-in first). Nil if there isn't one.
private func openMotor() -> CFTypeRef? {
    guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuationCreate != nil, actuationPlay != nil,
          let list = createList()?.takeRetainedValue() else { return nil }
    var ids: [(id: UInt64, builtIn: Bool)] = []
    for i in 0..<CFArrayGetCount(list) {
        guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
        let dev = UnsafeMutableRawPointer(mutating: raw)
        var id: UInt64 = 0
        if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
    }
    for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
        if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 { return ref }
    }
    return nil
}

private var motor: CFTypeRef?
private var motorPointer: UnsafeMutableRawPointer?

/// Plays tones (Hz, relative strength) together for `ms` at `level` (0…1). Strengths add up to 1.
private func play(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float) {
    guard let motorPointer, !tones.isEmpty else { return }
    let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
    let shape: [String: Any] = [
        "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
        "Tones": tones.map { ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000] },
    ]
    guard let act = actuationCreate!(shape as CFDictionary, 0) else { return }
    _ = actuationPlay!(act, motorPointer, 0, min(1, max(0, level)), 0)
    Unmanaged<AnyObject>.fromOpaque(act).release()
}

// MARK: - Voice style (what makes it clearer)

/// The knobs that change how understandable the trackpad voice is. The motor's strength is already at its
/// normal maximum, so clarity comes from pacing and from how the sound is shaped, not from more power.
struct VoiceStyle: Equatable {
    /// Words per minute for `say` (nil = the voice's default, around 175).
    var rate: Int? = 150
    /// A macOS voice (nil = system default).
    var voice: String? = nil
    /// Loudness curve: lower lifts quiet sounds (consonants, word endings) closer to the vowels.
    /// nospeaker uses 0.45.
    var curve: Double = 0.45
    /// How much the second formant (F2, which carries most of a vowel's identity) is favoured over F1.
    var f2Boost: Double = 1.8
    /// Strength of the hiss bursts for s, f, t, sh.
    var hiss: Float = 0.7

    static let nospeaker = VoiceStyle(rate: nil, curve: 0.45, f2Boost: 1.8, hiss: 0.7)
}

// MARK: - Speech analysis (formants per 10 ms)

struct Frame {
    var formants: [Double] = [500, 1500, 2500]
    var amps: [Double] = [1, 0.5, 0.25]
    var level: Float = 0
    var voiced = false
    var f0 = 110.0
}
private let hop = 0.010
private let sampleRate = 16000.0

/// Has macOS's `say` speak the line into memory, then analyses it. Empty if `say` failed.
func render(_ text: String, style: VoiceStyle) -> [Frame] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("trackpadai-\(getpid()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000"] + (style.voice.map { ["-v", $0] } ?? []) + (style.rate.map { ["-r", String($0)] } ?? []) + [text]
    guard (try? p.run()) != nil else { return [] }
    p.waitUntilExit()
    guard p.terminationStatus == 0, let file = try? AVAudioFile(forReading: url),
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return [] }
    var f = analyse(Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))), curve: style.curve)
    while let first = f.first, first.level == 0 { f.removeFirst() }
    while let last = f.last, last.level == 0 { f.removeLast() }
    return f
}

private func lpc(_ x: [Double], order p: Int) -> ([Double], Double) {
    var r = [Double](repeating: 0, count: p + 1)
    for k in 0...p { var s = 0.0; for i in k..<x.count { s += x[i] * x[i - k] }; r[k] = s }
    var a = [Double](repeating: 0, count: p + 1); a[0] = 1
    guard r[0] > 1e-12 else { return (a, 0) }
    r[0] *= 1.0001
    var e = r[0]
    for i in 1...p {
        var acc = r[i]
        for j in 1..<i { acc += a[j] * r[i - j] }
        let k = -acc / e
        var na = a
        for j in 1..<i { na[j] = a[j] + k * a[i - j] }
        na[i] = k
        a = na
        e *= 1 - k * k
    }
    return (a, e)
}

private struct C {
    var re: Double, im: Double
    static func + (l: C, r: C) -> C { C(re: l.re + r.re, im: l.im + r.im) }
    static func - (l: C, r: C) -> C { C(re: l.re - r.re, im: l.im - r.im) }
    static func * (l: C, r: C) -> C { C(re: l.re * r.re - l.im * r.im, im: l.re * r.im + l.im * r.re) }
    static func / (l: C, r: C) -> C {
        let d = r.re * r.re + r.im * r.im
        return C(re: (l.re * r.re + l.im * r.im) / d, im: (l.im * r.re - l.re * r.im) / d)
    }
}

private func roots(_ a: [Double]) -> [C] {
    let p = a.count - 1
    var z = (0..<p).map { k -> C in
        let ang = 2 * Double.pi * Double(k) / Double(p) + 0.4
        return C(re: 0.9 * cos(ang), im: 0.9 * sin(ang))
    }
    func poly(_ x: C) -> C { var s = C(re: 1, im: 0); for k in 1...p { s = s * x + C(re: a[k], im: 0) }; return s }
    for _ in 0..<300 {
        var moved = 0.0
        for i in 0..<p {
            var d = C(re: 1, im: 0)
            for j in 0..<p where j != i { d = d * (z[i] - z[j]) }
            if d.re == 0 && d.im == 0 { d = C(re: 1e-12, im: 0) }
            let step = poly(z[i]) / d
            z[i] = z[i] - step
            moved = max(moved, abs(step.re) + abs(step.im))
        }
        if moved < 1e-10 { break }
    }
    return z
}

private func analyse(_ x: [Float], curve: Double) -> [Frame] {
    let win = Int(0.025 * sampleRate), hopN = Int(hop * sampleRate), order = 18
    let hamming = (0..<win).map { 0.54 - 0.46 * cos(2 * .pi * Double($0) / Double(win - 1)) }
    var frames: [Frame] = [], rmsList: [Double] = []
    var prev = Frame()
    var i = 0
    while i + win <= x.count {
        let seg = (0..<win).map { Double(x[i + $0]) }
        rmsList.append(sqrt(seg.reduce(0) { $0 + $1 * $1 } / Double(win)))
        var f = prev
        var zc = 0
        for k in 1..<win where (seg[k] >= 0) != (seg[k - 1] >= 0) { zc += 1 }
        var bestLag = 0, bestR = 0.0
        for lag in Int(sampleRate / 300)...Int(sampleRate / 70) where lag < win - 40 {
            var s = 0.0, ea = 0.0, eb = 0.0
            for k in 0..<(win - lag) { s += seg[k] * seg[k + lag]; ea += seg[k] * seg[k]; eb += seg[k + lag] * seg[k + lag] }
            let r = s / max(sqrt(ea * eb), 1e-12)
            if r > bestR { bestR = r; bestLag = lag }
        }
        f.voiced = bestR > 0.35 && Double(zc) / Double(win) < 0.22
        if f.voiced, bestLag > 0 { f.f0 = sampleRate / Double(bestLag) }
        var pe = [Double](repeating: 0, count: win)
        for k in 0..<win { pe[k] = (seg[k] - 0.97 * (k > 0 ? seg[k - 1] : 0)) * hamming[k] }
        let (a, err) = lpc(pe, order: order)
        var cands: [Double] = []
        if err > 0 {
            for z in roots(a) where z.im > 0 {
                let hz = atan2(z.im, z.re) * sampleRate / (2 * .pi)
                let bw = -log(max(1e-9, sqrt(z.re * z.re + z.im * z.im))) * sampleRate / .pi
                if hz > 150, hz < 4200, bw < 500 { cands.append(hz) }
            }
        }
        func pick(_ lo: Double, _ hi: Double, near: Double) -> Double? {
            cands.filter { $0 >= lo && $0 <= hi }.min { abs($0 - near) < abs($1 - near) }
        }
        if let f1 = pick(200, 1000, near: prev.formants[0]) { f.formants[0] = f1 }
        if let f2 = pick(max(f.formants[0] + 200, 650), 2700, near: prev.formants[1]) { f.formants[1] = f2 }
        if let f3 = pick(max(f.formants[1] + 300, 1700), 3900, near: prev.formants[2]) { f.formants[2] = f3 }
        if err > 0 {
            f.amps = f.formants.map { hz in
                let w = 2 * Double.pi * hz / sampleRate
                var re = 0.0, im = 0.0
                for k in 0...order { re += a[k] * cos(w * Double(k)); im -= a[k] * sin(w * Double(k)) }
                return 1 / max(sqrt(re * re + im * im), 1e-6)
            }
        }
        frames.append(f)
        prev = f
        i += hopN
    }
    let peak = rmsList.max() ?? 1
    for k in frames.indices {
        let rel = rmsList[k] / max(peak, 1e-9)
        frames[k].level = rel < 0.02 ? 0 : Float(min(1, pow(rel, curve)))
        if frames[k].level == 0 { frames[k].voiced = false }
    }
    func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    let raw = frames
    for k in frames.indices {
        let lo = max(0, k - 2), hi = min(frames.count - 1, k + 2)
        for j in 0..<3 { frames[k].formants[j] = median((lo...hi).map { raw[$0].formants[j] }) }
        frames[k].f0 = min(250, max(70, median((lo...hi).map { raw[$0].f0 })))
    }
    return frames
}

/// A voiced frame as two tones, F1 and F2 (two were clearer than three in nospeaker's blind test).
private func voiceTones(_ f: Frame, f2Boost: Double) -> [(hz: Double, amp: Double)] {
    let w = [f.amps[0], f.amps[1] * f2Boost]
    let sum = max(w[0] + w[1], 1e-9)
    return [(f.formants[0], w[0] / sum), (f.formants[1], w[1] / sum)]
}

/// What the motor plays for one step of the voice: tones, how long, how strong.
private func step(_ f: Frame, style: VoiceStyle) -> (tones: [(hz: Double, amp: Double)], seconds: Double, level: Float)? {
    guard f.level > 0 else { return nil }
    if f.voiced { return (voiceTones(f, f2Boost: style.f2Boost), 1 / f.f0, f.level) }
    return ((0..<3).map { _ in (Double.random(in: 2700...4300), 1.0) }, 0.004, f.level * style.hiss)
}

/// Plays analysed frames on the motor. `onLevel` gets the loudness (0…1) and how far through it is (0…1).
private func talk(_ frames: [Frame], style: VoiceStyle, onLevel: (Float, Double) -> Void) {
    guard !frames.isEmpty else { return }
    let total = Double(frames.count) * hop
    let start = mach_absolute_time()
    var t = 0.0, lastReport = -1.0
    while t < total && !voiceStopRequested {
        let f = frames[min(frames.count - 1, Int(t / hop))]
        var dt = 0.005
        if let s = step(f, style: style) {
            dt = s.seconds
            play(s.tones, ms: dt * 1000, level: s.level)
        }
        if t - lastReport > 0.03 { onLevel(f.level, t / total); lastReport = t }
        t += dt
        waitUntil(start + UInt64(t * ticksPerSecond))
    }
    onLevel(0, 1)
}

/// The same tones the motor would play, as audio samples at 16 kHz. Not what the glass sounds like (that also
/// depends on the motor and glass), but good for comparing styles against each other.
func simulate(_ frames: [Frame], style: VoiceStyle) -> [Float] {
    let total = Double(frames.count) * hop
    var out = [Float](repeating: 0, count: Int(total * sampleRate) + 800)
    var t = 0.0
    while t < total {
        let f = frames[min(frames.count - 1, Int(t / hop))]
        var dt = 0.005
        if let s = step(f, style: style) {
            dt = s.seconds
            let sum = max(s.tones.reduce(0) { $0 + $1.amp }, 0.0001)
            let n0 = Int(t * sampleRate), n = Int(dt * sampleRate)
            for k in 0..<n where n0 + k < out.count {
                let time = Double(k) / sampleRate
                var v = 0.0
                for tone in s.tones { v += tone.amp / sum * sin(2 * .pi * tone.hz * time) }
                out[n0 + k] += Float(v) * s.level * 0.5
            }
        }
        t += dt
    }
    return out
}

/// A soft felt-and-heard "boop": a quick pitch dive. Used when the pet is poked.
private func boop() {
    let start = mach_absolute_time()
    var t = 0.0
    while t < 0.09 {
        let f = 200 + 900 * exp(-t / 0.02)
        let seg = 1 / f
        play([(f, 1)], ms: seg * 1000, level: Float(0.8 * exp(-t / 0.04)))
        t += seg
        waitUntil(start + UInt64(t * ticksPerSecond))
    }
}

// MARK: - The voice the rest of the app uses

final class Voice {
    enum Output { case trackpad, speakers }

    /// True if a Force Touch motor opened.
    let hasTrackpad: Bool
    var output: Output
    /// How the trackpad voice is shaped (see VoiceStyle).
    var style = VoiceStyle()

    /// Voices that scored best in `--clarity-test` (two-tone speech recognised by Apple's recognizer).
    /// Karen came out on top; the system default voice scored near the bottom.
    static let clearVoices = ["Karen", "Junior", "Eddy (English (US))", "Kathy", "Fred"]

    /// True if `say` has this voice installed.
    static func voiceInstalled(_ name: String) -> Bool {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let list = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return list.split(separator: "\n").contains { $0.lowercased().hasPrefix(name.lowercased() + " ") }
    }

    private let queue = DispatchQueue(label: "trackpadai.voice", qos: .userInitiated)
    private var busy = false
    private let lock = NSLock()
    private let synth = NSSpeechSynthesizerShim()

    init() {
        motor = openMotor()
        if let motor { motorPointer = Unmanaged.passUnretained(motor as AnyObject).toOpaque() }
        hasTrackpad = motor != nil
        output = hasTrackpad ? .trackpad : .speakers
        let d = UserDefaults.standard
        if let v = d.string(forKey: "trackpadVoice") {
            style.voice = v == "default" ? nil : v
        } else {
            style.voice = Voice.clearVoices.first(where: Voice.voiceInstalled)
        }
        if d.object(forKey: "trackpadRate") != nil { let r = d.integer(forKey: "trackpadRate"); style.rate = r == 0 ? nil : r }
    }

    var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    /// Says a line once, on a background queue. Returns false (and says nothing) if it's already talking.
    /// `onLevel` is called on the main thread with the loudness, `done` when finished.
    @discardableResult
    func say(_ text: String, onLevel: @escaping (Float, Double) -> Void, done: @escaping () -> Void) -> Bool {
        lock.lock()
        if busy { lock.unlock(); return false }
        busy = true
        lock.unlock()
        voiceStopRequested = false
        let out = output, style = style
        queue.async { [self] in
            let report: (Float, Double) -> Void = { l, p in DispatchQueue.main.async { onLevel(l, p) } }
            if out == .trackpad && hasTrackpad {
                let frames = render(text, style: style)
                talk(frames, style: style, onLevel: report)
            } else {
                synth.speak(text, voice: style.voice, onLevel: { report($0, 0.5) })
            }
            lock.lock(); busy = false; lock.unlock()
            DispatchQueue.main.async { done() }
        }
        return true
    }

    func boopIfIdle() {
        guard hasTrackpad, output == .trackpad, !isSpeaking else { return }
        queue.async { boop() }
    }

    func stop() { voiceStopRequested = true; synth.stop() }
}

/// Speaks through the speakers with `say`, faking a mouth level while it runs.
private final class NSSpeechSynthesizerShim {
    private var process: Process?
    func speak(_ text: String, voice: String?, onLevel: (Float) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = (voice.map { ["-v", $0] } ?? []) + [text]
        process = p
        guard (try? p.run()) != nil else { return }
        while p.isRunning && !voiceStopRequested {
            onLevel(Float.random(in: 0.3...1)); usleep(90_000)
        }
        if p.isRunning { p.terminate() }
        onLevel(0)
    }
    func stop() { process?.terminate() }
}
