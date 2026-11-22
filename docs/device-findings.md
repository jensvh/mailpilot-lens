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

- Depends on it: whether the day plan becomes a timeline picture or stays text rows.
- Found: send time ___ ms, readable: ___.

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

- Depends on it: whether there is a way to open the microphone when no card is in reach. Today that is a pinch on any button, the phone's own button, or waiting for MailPilot to speak.
- Found: ___.

### 7. Hearing you outdoors

A walk outside, in Dutch and in English, with wind and traffic. The log has every sentence as it was heard.

- Depends on it: how long the microphone may stay open (noise that is heard as words goes to the assistant), and whether the fixed words need more spellings.
- Found: ___.

## Edge cases to try every time

- The back gesture on a card: the lens goes to Meta's home. Say "lens": the card is back within a few seconds.
- One tap on the frame: "paused" is said; a second tap resumes and the card is still there.
- Glasses taken off and put on again.
- A phone call during a walk: afterwards the microphone and the lens work again without touching the phone.
- Out of coverage for a minute: "No connection" is said once, the lens shows Offline, and afterwards the current card returns.
- MailPilot restarted during a walk: the home card returns by itself.
- Swiping the app away: the glasses and the headset link are released.
