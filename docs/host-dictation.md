# Host dictation

Try Omarchy can recognise dictation for Omarchy on the Mac, with Apple's on-device speech recognition (`SpeechAnalyzer`) listening to the Mac microphone. The guest says when to start and stop; the Mac returns the words as they are recognised and the final text when the key is released. Nothing leaves the Mac, and the microphone runs only while a recording is in progress, with the orange indicator showing in the Mac menu bar.

Try Omarchy adds the recogniser in the app, a virtio-serial port, a guest service that serves `$XDG_RUNTIME_DIR/apple-dictation.sock`, and Apple Speech, an Omarchy dictation backend that uses it. Nothing changes in Omarchy until the user chooses Apple Speech in Omarchy's menu; other dictation tools can use the socket directly.

## Requirements

- macOS 26 or newer. On macOS 15 the feature is absent: there is no setting, no port and no guest service.
- An app built with Xcode 26 (the macOS 26 SDK). A build made with an older Xcode leaves the recogniser out and behaves as on macOS 15.
- Microphone access for Try Omarchy. The bridge never asks itself; grant it from the launcher's **Microphone** row or in System Settings.

The first recording in a language downloads Apple's speech assets for it. That recording ends with "Downloading Apple speech assets; try again in a moment"; later ones work. The language follows Omarchy's locale when Apple's recogniser supports it and falls back to US English otherwise.

## Setting

**Dictation** in the launcher's settings is on by default. Turning it off removes the port at the next launch, so nothing in the guest can reach the recogniser. Like the other launch settings, it applies when Omarchy next starts.

## Using it in Omarchy

Choose **Setup > Defaults > Dictation > Apple Speech** in the Omarchy menu. The row shows only while Dictation is on. Omarchy's own dictation keys then use the Mac: hold Right Alt or F9 to dictate, or press Super+Ctrl+X to start and stop. The final text is typed into the focused window with `wtype`, and a problem the Mac reports (no microphone access, speech assets still downloading) shows as a notification. Custom bindings can run `apple-speech start|stop|cancel|toggle`, or `omarchy dictation start|stop|toggle` as for any backend.

Apple Speech uses the `dictation` model (DictationTranscriber) unless told otherwise. `apple-speech model speech` switches to SpeechTranscriber, Apple's newer general-purpose recogniser; `apple-speech model dictation` switches back, and `apple-speech model` shows the one in use. The choice is kept in `~/.config/apple-speech/model` and applies from the next recording.

With Dictation off in the launcher, Apple Speech does nothing and says nothing. Omarchy binds its dictation keys whenever the selected backend's program is installed, which this one always is, so at each login the backend Apple Speech replaced is selected again instead (Voxtype, say). With none, the selection is cleared and Omarchy binds no dictation keys. When Dictation is on again, so is Apple Speech. A backend the user chooses in the meantime is kept, and Apple Speech stops coming back. **Remove > Dictation > Apple Speech** puts the replaced backend back for good. The choice is recorded in `~/.local/state/try-omarchy/dictation-backend`.

## Protocol

A dedicated virtio-serial port, `dev.tryomarchy.dictation` (`nr=9`), carries newline-delimited JSON with a `type` field. Lines over 64 KiB, malformed lines and unknown types are dropped. The guest numbers its sessions; at most one is live, and the host handles commands in the order they arrive.

Guest to host:

```json
{"type":"hello","version":1}
{"type":"start","session":12,"model":"speech"}
{"type":"stop","session":12}
{"type":"cancel","session":12}
{"type":"ping","id":5}
```

Host to guest:

```json
{"type":"hello","version":1,"available":true,"models":["speech","dictation"],"locale":"en-US"}
{"type":"recording","session":12}
{"type":"level","session":12,"v":0.62}
{"type":"partial","session":12,"text":"Can you check whether"}
{"type":"processing","session":12}
{"type":"final","session":12,"text":"Can you check whether the service came back?","ms":141}
{"type":"cancelled","session":12}
{"type":"error","session":12,"message":"…"}
{"type":"pong","id":5,"session":12}
```

- The guest says `hello` whenever it opens the port. The host answers with its own and cancels any session it had, because the guest side restarted.
- `start` while a session is live cancels that session first.
- `stop` and `cancel` for a session that isn't live are ignored.
- `final`, `cancelled` and `error` end a session.
- `pong` names the live session only while there is one.
- `speech` is Apple's general `SpeechTranscriber`; `dictation` is `DictationTranscriber` with punctuation. Any other model is `speech`.

## Guest service

`omarchy-native-dictation-bridge` is a user service in the desktop session, started only while the port exists. It speaks the per-connection protocol the client tools use:

| Request | Reply |
|---|---|
| `{"cmd":"start","model":"speech"\|"dictation"}` | The connection stays open for `{"event":…}` lines: `recording`, `level`, `partial`, `processing`, then `final`, `cancelled` or `error`, then EOF. |
| `{"cmd":"stop"}`, `{"cmd":"cancel"}` | `{"ok":true}`; acts on whichever session is live. |
| `{"cmd":"ping"}` | `{"ok":true,"session":bool}` after a round trip to the Mac. `session` is true while the Mac records a session that hasn't been stopped, so a toggle during the final text starts the next one. |

A session is live from the moment its `start` is sent, so a quick tap whose `stop` arrives before `recording` still stops it. The owner closing its connection while the session is live cancels it, so the Mac microphone never runs for nobody. A Mac that stays silent for 5 seconds, or goes away, ends the session with an error. If another program already answers on the socket path, the service leaves it alone.

## Troubleshooting

- The launcher log has `[dictation-bridge] Apple dictation is available to Omarchy.` or the reason it isn't.
- In Omarchy: `ls /dev/virtio-ports/dev.tryomarchy.dictation` and `systemctl --user status omarchy-native-dictation-bridge`.
- `omarchy default dictation` names the selected backend; Apple Speech is `apple-speech`.
