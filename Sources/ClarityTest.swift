// ClarityTest.swift — `Pip --clarity-test`: scores how understandable each voice style is.
//
// For each style it renders a few typical lines into the exact tones the motor would play, turns those into
// audio, and asks Apple's on-device speech recognizer to transcribe them. The share of words it gets right is
// the score. It can't model the trackpad glass itself, so use it to compare styles, then trust your ears.

import AVFoundation
import Speech

enum ClarityTest {
    static let lines = [
        "Hey, you're back. I missed you.",
        "Whoa, thirty deletes. Rough draft?",
        "Two hours of code. Time for a stretch.",
        "It's really late. Bed soon?",
        "Ooh, music time. Play something good.",
        "What time is it? It's half past nine.",
    ]

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty }
    }

    /// Share of reference words recovered (1 − word error rate, floored at 0).
    static func accuracy(_ ref: String, _ hyp: String) -> Double {
        let r = words(ref), h = words(hyp)
        guard !r.isEmpty else { return 0 }
        var d = Array(0...h.count)
        for i in 1...r.count {
            var prev = d[0]; d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return max(0, 1 - Double(d[h.count]) / Double(r.count))
    }

    static func transcribe(_ samples: [Float]) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pip-clarity-\(getpid()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return "" }
        buf.frameLength = AVAudioFrameCount(samples.count)
        let peak = max(samples.map(abs).max() ?? 1, 1e-6)
        for i in samples.indices { buf.floatChannelData![0][i] = samples[i] / peak * 0.9 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buf)
        } catch { return "" }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        recognizer.queue = OperationQueue()
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        var text = ""
        let done = DispatchSemaphore(value: 0)
        let task = recognizer.recognitionTask(with: req) { res, err in
            if let res, res.isFinal { text = res.bestTranscription.formattedString; done.signal() } else if err != nil { done.signal() }
        }
        _ = done.wait(timeout: .now() + 30)
        task.cancel()
        return text
    }

    static func run() {
        var styles: [(String, VoiceStyle)] = [
            ("nospeaker original", .nospeaker),
            ("slower (150 wpm)", VoiceStyle(rate: 150, curve: 0.45, f2Boost: 1.8, hiss: 0.7)),
            ("slowest (130 wpm)", VoiceStyle(rate: 130, curve: 0.45, f2Boost: 1.8, hiss: 0.7)),
            ("150 + lift quiet sounds", VoiceStyle(rate: 150, curve: 0.3, f2Boost: 1.8, hiss: 0.7)),
            ("150 + more F2", VoiceStyle(rate: 150, curve: 0.45, f2Boost: 2.6, hiss: 0.7)),
            ("150 + stronger hiss", VoiceStyle(rate: 150, curve: 0.45, f2Boost: 1.8, hiss: 1.0)),
        ]
        for v in ["Samantha", "Daniel", "Karen", "Fred"] { styles.append(("150, voice \(v)", VoiceStyle(rate: 150, voice: v))) }
        // CLARITY_VOICES=Karen,Moira tests those voices at 150 wpm and with each tweak.
        if let vs = ProcessInfo.processInfo.environment["CLARITY_VOICES"] {
            styles = []
            for v in vs.split(separator: ",").map(String.init) {
                styles.append(("\(v)", VoiceStyle(rate: 150, voice: v)))
                if ProcessInfo.processInfo.environment["CLARITY_TWEAKS"] != nil {
                    styles.append(("\(v), 130 wpm", VoiceStyle(rate: 130, voice: v)))
                    styles.append(("\(v), lift quiet", VoiceStyle(rate: 150, voice: v, curve: 0.3)))
                    styles.append(("\(v), more F2", VoiceStyle(rate: 150, voice: v, f2Boost: 2.6)))
                    styles.append(("\(v), default speed", VoiceStyle(rate: nil, voice: v)))
                }
            }
        }
        if let only = ProcessInfo.processInfo.environment["CLARITY_STYLES"] {
            let keep = only.split(separator: ",").compactMap { Int($0) }
            styles = keep.filter { $0 < styles.count }.map { styles[$0] }
        }

        print("Clarity test: \(lines.count) lines per style, scored by on-device speech recognition.\n")
        for (name, style) in styles {
            var total = 0.0
            var worst = (1.0, "", "")
            for line in lines {
                let heard = transcribe(simulate(render(line, style: style), style: style))
                let a = accuracy(line, heard)
                total += a
                if a < worst.0 { worst = (a, line, heard) }
            }
            let score = Int((total / Double(lines.count) * 100).rounded())
            print(String(format: "%3d%%  %@", score, name) + (worst.0 < 1 ? "   (worst: \"\(worst.1)\" → \"\(worst.2)\")" : ""))
        }
    }
}
