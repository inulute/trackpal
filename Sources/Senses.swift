// Senses.swift — what the pet notices. Everything here is counts and timing: it never reads or keeps which
// keys you typed, only how many, how fast, and whether they were delete or ⌘Z.

import AppKit
import ApplicationServices
import IOKit.ps

enum Event: Equatable {
    case hello(partOfDay: String)
    case appSwitched(app: String)
    case switchingFrenzy(count: Int)          // lots of app hopping in a minute
    case typingBurst(keysPerMinute: Int)
    case deleteRage(deletes: Int)             // many deletes in a short time
    case undoSpam(count: Int)
    case longSession(minutes: Int)            // typing/clicking without a real break
    case wentIdle(minutes: Int)
    case cameBack(afterMinutes: Int)
    case lateNight(hour: Int)
    case batteryLow(percent: Int)
    case pluggedIn
    case wokeUp                               // screen or Mac woke from sleep
    case poked(times: Int)
    case musing                               // nothing in particular; occasional small talk

    /// A short key for cooldowns: one kind of event shouldn't repeat too often.
    var kind: String {
        switch self {
        case .hello: return "hello"
        case .appSwitched: return "app"
        case .switchingFrenzy: return "frenzy"
        case .typingBurst: return "typing"
        case .deleteRage: return "delete"
        case .undoSpam: return "undo"
        case .longSession: return "session"
        case .wentIdle: return "idle"
        case .cameBack: return "back"
        case .lateNight: return "late"
        case .batteryLow: return "battery"
        case .pluggedIn: return "plug"
        case .wokeUp: return "wake"
        case .poked: return "poke"
        case .musing: return "muse"
        }
    }

    /// A plain-language summary for the AI brain. Never contains anything typed.
    var summary: String {
        switch self {
        case .hello(let p): return "The user just started you up. It is \(p)."
        case .appSwitched(let a): return "The user switched to the app \(a)."
        case .switchingFrenzy(let n): return "The user switched apps \(n) times in the last minute, looking distracted."
        case .typingBurst(let k): return "The user is typing very fast, about \(k) keys per minute."
        case .deleteRage(let d): return "The user just hit delete \(d) times in a few seconds."
        case .undoSpam(let n): return "The user pressed undo \(n) times in a row."
        case .longSession(let m): return "The user has been working for \(m) minutes without a break."
        case .wentIdle(let m): return "The user has been away from the keyboard for \(m) minutes."
        case .cameBack(let m): return "The user just came back after \(m) minutes away."
        case .lateNight(let h): return "It is \(h > 12 ? h - 12 : h) \(h >= 12 ? "pm" : "am") and the user is still on the computer."
        case .batteryLow(let p): return "The laptop battery is at \(p) percent and not charging."
        case .pluggedIn: return "The laptop was just plugged in to charge."
        case .wokeUp: return "The computer just woke up from sleep."
        case .poked(let n): return "The user poked you with the mouse\(n > 1 ? ", \(n) times in a row" : "")."
        case .musing: return "Nothing special is happening. Make a little small talk."
        }
    }
}

/// What's going on right now, for the brain's context. Counts and names only.
struct Snapshot {
    var app: String?
    var minutesInApp: Int
    var keysLastMinute: Int
    var minutesSinceBreak: Int
    var typingNow: Bool
    var keyboardSeen: Bool
}

final class Senses {
    var onEvent: ((Event) -> Void)?
    /// Called continuously with whether the user is typing right now (for the "focused" face).
    var onTypingChanged: ((Bool) -> Void)?

    private(set) var keyboardAllowed = false
    private var keyMonitor: Any?
    private var timer: Timer?

    // Rolling windows of timestamps.
    private var keyTimes: [TimeInterval] = []
    private var deleteTimes: [TimeInterval] = []
    private var undoStreak = 0, lastUndo: TimeInterval = 0
    private var switchTimes: [TimeInterval] = []
    private var pokeTimes: [TimeInterval] = []

    private var sessionStart = Date().timeIntervalSince1970
    private var wasIdle = false, idleSince: TimeInterval = 0
    private var lastBatteryWarned = 101, wasCharging: Bool?
    private var typing = false
    private var lastMusing = Date().timeIntervalSince1970
    private var lastLateNightHour = -1
    private var currentApp: String? = NSWorkspace.shared.frontmostApplication?.localizedName
    private var appSince = Date().timeIntervalSince1970

    var snapshot: Snapshot {
        let t = now()
        return Snapshot(app: currentApp, minutesInApp: Int((t - appSince) / 60), keysLastMinute: keyTimes.filter { t - $0 < 60 }.count,
                        minutesSinceBreak: Int((t - sessionStart) / 60), typingNow: typing, keyboardSeen: keyboardAllowed)
    }

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier, let name = app.localizedName else { return }
            let t = now()
            currentApp = name; appSince = t
            switchTimes.append(t); switchTimes.removeAll { t - $0 > 60 }
            if switchTimes.count >= 12 { onEvent?(.switchingFrenzy(count: switchTimes.count)); switchTimes.removeAll() }
            else { onEvent?(.appSwitched(app: name)) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?(.wokeUp)
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionStart = Date().timeIntervalSince1970
        }

        startKeyboard(prompt: false)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }

        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "the middle of the night" : h < 12 ? "morning" : h < 17 ? "afternoon" : h < 21 ? "evening" : "night"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.onEvent?(.hello(partOfDay: part)) }
    }

    /// Listens for key presses if the app has Accessibility access. With `prompt`, asks macOS to show
    /// the permission dialog. Without access everything else still works.
    func startKeyboard(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        keyboardAllowed = AXIsProcessTrustedWithOptions(opts)
        guard keyboardAllowed, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // Only the key's position and modifiers are looked at, never its character.
            self?.key(code: e.keyCode, command: e.modifierFlags.contains(.command), isRepeat: e.isARepeat)
        }
    }

    private func key(code: UInt16, command: Bool, isRepeat: Bool) {
        let t = now()
        keyTimes.append(t)
        if code == 51 || code == 117 {   // delete, forward delete
            deleteTimes.append(t); deleteTimes.removeAll { t - $0 > 4 }
            if deleteTimes.count >= 25 { onEvent?(.deleteRage(deletes: deleteTimes.count)); deleteTimes.removeAll() }
        }
        if command && code == 6 && !isRepeat {   // ⌘Z
            undoStreak = t - lastUndo < 2 ? undoStreak + 1 : 1
            lastUndo = t
            if undoStreak >= 6 { onEvent?(.undoSpam(count: undoStreak)); undoStreak = 0 }
        }
    }

    func poked() {
        let t = now()
        pokeTimes.append(t); pokeTimes.removeAll { t - $0 > 5 }
        onEvent?(.poked(times: pokeTimes.count))
    }

    private func poll() {
        let t = now()
        keyTimes.removeAll { t - $0 > 60 }

        // Typing state and bursts.
        let recent = keyTimes.filter { t - $0 < 5 }.count
        let nowTyping = recent >= 6
        if nowTyping != typing { typing = nowTyping; onTypingChanged?(typing) }
        if keyTimes.count >= 380 { onEvent?(.typingBurst(keysPerMinute: keyTimes.count)) }

        // Idle and coming back: any input (keyboard, mouse, trackpad) counts as activity.
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if !wasIdle && idle > 300 {
            wasIdle = true; idleSince = t - idle
            onEvent?(.wentIdle(minutes: Int(idle / 60)))
        } else if wasIdle && idle < 3 {
            wasIdle = false
            let away = Int((t - idleSince) / 60)
            sessionStart = t
            onEvent?(.cameBack(afterMinutes: away))
        }
        if wasIdle, t - idleSince > 600 { sessionStart = t }

        // Long session without a break of 5+ minutes.
        let worked = Int((t - sessionStart) / 60)
        if !wasIdle && worked >= 50 && worked % 25 == 0 { onEvent?(.longSession(minutes: worked)) }

        // Late night, once per hour.
        let hour = Calendar.current.component(.hour, from: Date())
        if !wasIdle && (hour >= 23 || hour < 4) && hour != lastLateNightHour {
            lastLateNightHour = hour
            onEvent?(.lateNight(hour: hour))
        }

        pollBattery()

        // Occasional small talk while the user is around, every 25–45 minutes.
        if !wasIdle && t - lastMusing > Double.random(in: 1500...2700) {
            lastMusing = t
            onEvent?(.musing)
        }
    }

    private func pollBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let pct = cap * 100 / max
            let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if let was = wasCharging, !was && charging { onEvent?(.pluggedIn); lastBatteryWarned = 101 }
            wasCharging = charging
            if !charging, pct <= 15, pct < lastBatteryWarned - 4 {
                lastBatteryWarned = pct
                onEvent?(.batteryLow(percent: pct))
            }
        }
    }
}
