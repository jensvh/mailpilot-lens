# What only the glasses can answer

The app was written without the glasses at hand. These are the things that could not be known from a desk, each with how to find out and what in the app depends on the answer. Fill in the "Found" lines after trying; nothing below has been measured yet.

Most tests are in the app under Settings → **Try the glasses**. Settings → **Share the log** gives the numbers.

## First: does it run at all

Do these once, in this order, with the screen on. Each line is something that was never run on a device.

| # | Do | Expect | Found |
|---|---|---|---|
| 1 | Install, open the app | The home screen, "not paired" | |
| 2 | Settings → Register with the Meta AI app | The Meta AI app opens, asks, and returns; "registered" | |
| 3 | Scan MailPilot's pairing code with the camera | The app opens; within seconds the first row shows the PC's name and a card appears on the phone | |
| 4 | Tap a button on the phone's card | MailPilot's Glasses page shows the same change | |
| 5 | Type "triage" in the box | The card changes to the first mail | |
| 6 | Start walk, glasses on | A rising tone, the brief spoken through the glasses, the home card on the lens | |
| 7 | Say "triage", then "next", then "home" | Each is heard (the words show on the phone) and the lens follows | |
| 8 | Pinch a button on the lens | Same as saying it | |
| 9 | End walk | The summary is spoken, then the lens clears and the headset link is released | |

Then the same with the phone **locked in a pocket** from step 6 on. If the app is suspended there, the log shows a gap in the timestamps.

## The seven questions

### 1. How much fits on the lens

*Try the glasses → How much fits.* Add lines until the buttons leave the lens or text is cut off.

- Depends on it: the length limits MailPilot clamps every card to (its `Lens:Card` settings), and the layout in `Sources/Glasses/CardRenderer.swift`. Today a card is at most one headline, three lines, one row of at most four buttons.
- Found: heading lines ___, body lines ___, meta lines ___, buttons in a row ___, characters per body line about ___.

### 2. A drawn picture

*Try the glasses → A picture.* Is it sharp at lens size, and how long until it shows (the result line has the send time)?

Then the real one: on a walk, say "my day". The log line "a drawn card of 600×…, sent in … ms" has its size and time; "the picture wasn't shown" means the glasses refused it and the card came as text.

- Depends on it: Settings → Lens → "Draw the day as a picture". It is on now, without having been seen on the glasses. If the picture is slow or hard to read, switch it off: the day plan is then rows of text.
- Found: send time ___ ms, readable: ___, the day plan's picture: ___.

### 3. Does a card survive

Show any test card, let the lens go dark, and pinch a button after 5, 15 and 60 minutes. The result line says how many seconds passed; no pinch arriving means the card was gone.

- Depends on it: Settings → Lens → "Open the lens anew after". It is 45 seconds now, which costs a few seconds whenever a card comes after a longer silence. If cards survive, set it to Never.
- Found: after 5 min ___, 15 min ___, 60 min ___.

### 4. Battery

A whole walk with the headset link up and one session open: note the glasses' level at the start and the end (the home screen shows it).

- Depends on it: whether the session should be closed while the microphone sleeps.
- Found: ___ % per hour.

### 5. Does the microphone hear the glasses' own speakers

*Try the glasses → Echo*, during a walk, staying quiet.

- Depends on it: Settings → Voice → "Talk over it". Off now: while it speaks, the speech server gets silence, so you can only interrupt with a pinch.
- Found: level in silence ___, while speaking ___.

### 6. Waking it without a card

With Settings → Voice → "A tap on the frame wakes it" on: does one tap arrive (the log says "media button"), and does it also pause the glasses' session (the app says "paused")?

- Depends on it: whether there is a way to open the microphone when no card is in reach. Today that is a pinch on any button, the phone's own button, or waiting for MailPilot to speak. Two more ways are there to try, both off at first: the wake phrase (9) and the capture button (11).
- Found: ___.

### 7. Hearing you outdoors

A walk outside, in Dutch and in English, with wind and traffic. The log has every sentence as it was heard.

- Depends on it: how long the microphone may stay open (noise that is heard as words goes to the assistant), and whether the fixed words need more spellings.
- Found: ___.

### 8. The Neural Band

*Try the glasses → Look for the Neural Band.* Meta's toolkit doesn't report the band at all, so the app looks among the Bluetooth devices connected to the phone and reads the standard battery level if the band offers one.

- Depends on it: the "Neural Band" row on the home screen and the low-battery warning on the home card. If the band talks to the glasses only, the row stays "not seen by the phone" and only Meta's own app knows its battery.
- Found: listed devices ___, band name ___, battery read: ___.

### 9. "Hey pilot"

Settings → Voice → "Hey pilot" wakes it. Let it fall asleep (the falling tone), then say "hey pilot", and on another try "hey pilot, triage". The log has "wake phrase: …" for every time it woke and "wake phrase: not taken, …" for what came close, each with the words as the speech server heard them.

- Depends on it: whether the switch can be on by default, and which spellings `Sources/Voice/WakePhrase.swift` needs. The rules were only run against a made-up list of what a speech server might hear (`tools/wake/main.swift`), never against a voice.
- To check: does it wake, in Dutch and in English and outdoors; how often it wakes on a walk when nobody asked (other people talking, your own conversation); whether the speech stream stays up for a whole walk (the log says when it drops and comes back); the glasses' and the phone's battery per hour with it on, next to question 4 with it off.
- Found: wakes on ___, missed ___, false wakes per hour ___, battery ___ % per hour (glasses), ___ % (phone).

### 10. Siri and the Action button

Say "Hey Siri, start a walk with MailPilot Lens", and try the "Start walk" shortcut from the Shortcuts app (it is listed under MailPilot Lens without setting anything up).

- Depends on it: nothing in the app. If Siri doesn't know the phrase on an app signed from Windows, the shortcut in the Shortcuts app and on the Action button may still work.
- To check: does the phrase work on this sideloaded build; does the walk start with the phone locked (the app has to come to the front for the microphone, so iOS will ask to unlock); the log says "shortcut: starting a walk".
- Found: Siri ___, Shortcuts app ___, Action button ___, from a locked phone ___.

### 11. Buttons on the frame

Settings → Lens → "Buttons on the frame", then start a walk. With a card up: pinch its buttons as usual, press the capture button once, do the back gesture, swipe on the frame's touch strip. The log has a "frame: …" line for everything the glasses reported.

- Depends on it: whether the switch can be on by default. On: the capture button opens the microphone (also with no card up, which answers question 6), and the back gesture goes a card back instead of closing the app on the glasses. Swipes and "select" are only logged for now: on a card they may move the focus as well, and that has to be seen first.
- To check, in this order: do pinches on a card's buttons still work with it on (if not, switch it off: the glasses then hand the pinch to this instead of to the card); does the capture button arrive, and does it also take a photo; does the back gesture arrive and leave the card up; what a swipe on the frame reports.
- Found: inputs state ___, pinches still work ___, capture button ___, back ___, swipes ___.

## The toolkit

The app is built on Meta's Device Access Toolkit 1.0.1. Read from its interface files on 23 November 2026:

- **Inputs are in 1.0.1 already**, in a module of their own (`MWDATInputs`, marked experimental): `session.addInputs(…)` gives a stream of events for the capture button (short press, hold, double press), the action button, swipes and select from the frame's touch strip and the Neural Band, drags, and the back gesture, which the app can ask to get instead of being closed by it. Question 11 uses this.
- The same release has experimental `MWDATSpeech` (transcription on the glasses, with the toolkit's microphone permission) and `VoiceInvocationsStream` ("Hey Meta, open …" reaching the app). Neither is used: the microphone here is the headset link's, and the toolkit's own needs testing of its own.
- **1.1.0** (20 November 2026) adds `DeviceSession.pause()` and `resume()`, refuses a session with `notRegistered` when the app isn't registered, ends every session on unregistering, and drops the Wi-Fi Aware pairing types and the separate crash-reporting setting. Nothing this app calls changed, and nothing new reports input: there is still no event for "the glasses woke" or "the user looked at the lens".
- The branch `toolkit-next` is this app on 1.1.0, built as a second `.ipa`. Try it only after the 1.0.1 build has had its walk.

## Edge cases to try every time

- The back gesture on a card: the lens goes to Meta's home. Say "lens": the card is back within a few seconds.
- One tap on the frame: "paused" is said; a second tap resumes and the card is still there.
- Glasses taken off and put on again.
- A phone call during a walk: afterwards the microphone and the lens work again without touching the phone.
- Out of coverage for a minute: "No connection" is said once, the lens shows Offline, and afterwards the current card returns.
- MailPilot restarted during a walk: the home card returns by itself.
- The agent finishes a task during a walk: with the home card up, its result comes to the lens with a tone; in the middle of a mail it is one sentence that waits for what is being said, and the mail's card stays.
- Swiping the app away: the glasses and the headset link are released.
