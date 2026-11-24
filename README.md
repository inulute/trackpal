# trackpal

**Pip**, a tiny desk pet for your Mac. It sits in the corner of your screen with a glowing robot face, notices what
you're doing, and talks to you **through your trackpad**. The Force Touch motor buzzes out a voice, the
NO SPEAKER way, so it works even with the Mac muted. Say **"Hey Pip"** and it listens and answers.

> **Built on [NO SPEAKER](https://github.com/os6/nospeaker) by [Cody Collier](https://github.com/os6).**
> The trackpad voice (driving the Force Touch motor through MultitouchSupport, and turning speech into
> formant tones it can play) is NO SPEAKER's work, adapted here under its MIT license. Go see the original.
> It talks, sings and raps through your trackpad.

## Run it

```sh
./build.sh run
```

Needs macOS 13+ and the Command Line Tools (`xcode-select --install`). The trackpad voice needs a Force Touch
trackpad. Without one, Pip talks through the speakers instead. For the trackpad voice, mute the Mac, put it on
a table, and keep your hands off the glass.

Pip has no Dock icon. **Right-click Pip** (or use the ◕‿◕ menu bar icon) for its menu. To quit, choose Quit there.

## Talking to it

| You do | Pip does |
| --- | --- |
| Say "Hey Pip, …" | Chirps, a ring glows while it listens, then it answers out loud |
| Double-click Pip | Opens a chat box. Type, then press Enter |
| Click Pip | Boop. Poke it too often and it gets annoyed |
| Drag Pip | Moves it, and it remembers where |

It also reacts on its own: app switches, typing streaks, delete storms, ⌘Z spam, long sessions without a
break, coming back after time away, late nights, low battery, wake from sleep. Its eyes follow your pointer.

## Making the trackpad voice clearer

The motor already runs at its normal maximum (nospeaker's safety limit), so clarity comes from shaping the voice:

- **Voice choice matters most.** `Pip --clarity-test` renders the motor's tones to audio and scores them with
  on-device speech recognition. Karen scored best (~25%), and the system default voice scored worst (~5%).
  Speed, consonant lift and formant weighting moved the score by less than the noise. Pip defaults to Karen
  at 150 wpm. Right-click → **Trackpad voice** picks another voice or speed and plays a test line.
- **Read along.** On the trackpad, the speech bubble types the words as they're buzzed.
- The score is a comparison between styles, not what you hear: the glass and motor change the sound. Trust
  your ears with **Test the voice**.

## Its brain

Pip picks the best brain it has. You can change it from the menu.

1. **A key you've added** (menu → *Add a Gemini key…* / *Add a Claude key…*). Gemini uses
   `gemini-3.5-flash-lite`, a cheap and fast model, and you can get a free key at aistudio.google.com. Claude
   uses `claude-opus-5-5`.
2. **Apple's on-device model**, on macOS 26+ with Apple Intelligence on. It's free, offline and private.
3. **Built-in lines**: always there, but they repeat.

Each request gets a short context: the time, the current app and how long you've been in it, minutes since
your last break, recent happenings, what Pip said lately (so it doesn't repeat itself), and anything it
learned about you in chat. It keeps those facts between launches. *Forget what Pip knows about me* in the menu
clears them.

Override the models with `TRACKPADAI_GEMINI_MODEL` / `TRACKPADAI_MODEL`. Keys can also come from
`GEMINI_API_KEY` / `ANTHROPIC_API_KEY` when you launch the binary from a shell.

## Privacy

- **Keyboard:** Pip counts keys (how many, how fast, and whether they were delete or ⌘Z). It never reads or
  stores which keys you typed. Keyboard reactions need Accessibility permission (menu → *Turn on keyboard
  reactions…*). Without it, everything else still works.
- **Microphone:** speech is recognised **on this Mac only**. If the Mac can't do on-device recognition,
  listening stays off instead of sending audio anywhere. Pip ignores the mic while it's talking. You can turn
  listening off in the menu.
- **What leaves the Mac:** only when you've added a Gemini or Claude key. Then that provider receives the
  context described above (app names, times, counts), what you say or type *to Pip*, and the facts it
  remembers. With the on-device model, nothing leaves the Mac.

## Debugging

```sh
open --env TRACKPADAI_LOG=/tmp/pip.log build/Pip.app      # what the listener hears
build/Pip.app/Contents/MacOS/Pip --ask "hello"             # print what the brain says to sample events
build/Pip.app/Contents/MacOS/Pip --snapshot /tmp/moods     # draw every face to PNGs
build/Pip.app/Contents/MacOS/Pip --clarity-test            # score trackpad voice styles
CLARITY_VOICES="Karen,Fred" CLARITY_TWEAKS=1 build/Pip.app/Contents/MacOS/Pip --clarity-test
```

## Files

| File | What it is |
| --- | --- |
| `Sources/Voice.swift` | Trackpad voice (adapted from NO SPEAKER) and the speaker fallback |
| `Sources/Face.swift` | The floating face: moods, blinking, gaze, speech bubble |
| `Sources/Senses.swift` | What it notices (apps, idle, keys as counts, battery, sleep) |
| `Sources/Brain.swift` | Gemini / Claude / on-device model, plus context and memory |
| `Sources/ClarityTest.swift` | Scores voice styles by speech-recognition accuracy |
| `Sources/Listener.swift` | "Hey Pip" wake word and on-device speech recognition |
| `Sources/Chat.swift` | The type-to-Pip box |
| `Sources/main.swift` | Wires it together and builds the menu |

## Credits

- **[NO SPEAKER](https://github.com/os6/nospeaker)** by Cody Collier: the haptic motor driver and the
  speech-to-formant voice in `Sources/Voice.swift` are adapted from it (MIT, see `NOTICE`). NO SPEAKER in turn
  credits the open-source Tactile project for the MultitouchSupport
  function names.
- The face is inspired by desk robots like EMO.

The trackpad motor is driven through MultitouchSupport, a private macOS framework, so a macOS update could
break it.

## License

MIT (see `LICENSE`). The code adapted from NO SPEAKER is also MIT, under its own copyright (see `NOTICE`).
