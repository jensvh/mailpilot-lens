# MailPilot Lens

The iPhone side of MailPilot for Meta Ray-Ban Display glasses: decide on mail and tasks while you walk, by voice and by pinch.

MailPilot (a separate, private app on a PC) owns everything: the mail, the tasks, the assistant and every rule about what may be done. This app is the thin part in your pocket. It listens through the glasses, shows MailPilot's cards on the lens, speaks MailPilot's words, and sends back what you said and what you pinched. It holds no mail logic and stores no mail.

```
Glasses ──Bluetooth── iPhone (this app) ──wss──► your speech-to-text server
 lens cards, band        │
 microphone, speakers    └──wss──► relay (Azure Web PubSub) ◄──wss── MailPilot on the PC
                                   sees ciphertext only
```

> **Status: not yet tried on a phone or on the glasses.** It compiles, and the build proves that this app and MailPilot seal and read each other's messages the same way. Everything about the glasses comes from code that was tried on them in another project, but this app's own first walk is still to come. What has to be found out on the device is listed in [docs/device-findings.md](docs/device-findings.md).

## What you need

- Meta Ray-Ban Display glasses, connected to the Meta AI app, with **Developer Mode** on there (Settings → App Info → tap the version number five times). In Developer Mode no Meta app ID is needed.
- An iPhone with iOS 17.2 or newer, with Developer Mode on (Settings → Privacy & Security → Developer Mode).
- MailPilot running, with a relay set up on its Glasses page, and a speech-to-text server set in its settings.
- A Windows PC or a Mac to sign the app with your own Apple ID.

The app also works without glasses: the phone alone, by voice and with the card on its screen.

## Install

GitHub Actions builds an unsigned `MailPilotLens.ipa` on every push. Download the newest one:

```powershell
gh run download --repo jensvh/mailpilot-lens --name MailPilotLens --dir build-out
```

An unsigned app has to be signed with your Apple ID before iOS installs it. Without a Mac that means a signing tool on Windows (Sideloadly or AltStore), or a paid Apple developer account. With a free Apple ID the app works for 7 days and then needs signing again; AltStore can do that by itself over Wi-Fi.

The build holds no keys and no addresses. The app gets them when you pair it.

## First start

1. **Glasses.** Open the app, tap the gear, then **Register with the Meta AI app** and allow MailPilot Lens there.
2. **MailPilot.** On the PC, open MailPilot's Glasses page and choose **Pair a phone**. Scan the code with the iPhone camera: it opens this app, and a few seconds later the top row says the PC's name. The code works once and for 3 minutes.

Pairing gives the phone its own key, its address on the relay and the speech server's address and key, all sealed with the code's secret. They are kept in the iPhone's Keychain, on this device only. To remove a phone, use **Revoke** on MailPilot's Glasses page.

## A walk

1. Tap **Start walk** with the app open (iOS only lets an app open the microphone while it is in front). Allow the microphone the first time.
2. Lock the phone and put it away. You hear the brief ("4 mails need you…") and the home card is on the lens.
3. Pinch a button, or just say it. The first button on a card is the suggested one and is already in focus.
4. **End walk** on the phone, or say "end walk": you hear what you decided, and the app lets go of the glasses.

| Where | Say |
|---|---|
| Anywhere | next, back, repeat, stop, undo, home, more, help, quiet, sleep, "the second one" |
| A mail | delete, done, file it, later, read it, why, task, "task for Friday", "reply that…" |
| A draft | save, discard; anything else is a change ("shorter", "add that Tom joins") |
| A task | done, tomorrow, Friday, no date, high priority, "plan it at two", start it |
| Anything else | goes to MailPilot's assistant, with the card in front of you as "this" |

English and Dutch both work. The words are MailPilot's; this app only passes on what it heard.

**The microphone** opens when you pinch, when a card expects words, and after MailPilot has spoken. It closes when it stays quiet (45 seconds while a card waits for you, otherwise about 15), with a falling tone; a rising tone means it is open. Say "sleep" to close it at once. While it is closed nothing leaves the phone.

**While it speaks it doesn't listen**, so it can't answer itself. A pinch still works. If the echo test shows the microphone doesn't hear the glasses' speakers, "Talk over it" in Settings lets you interrupt by voice.

**Without coverage** it says so once, the lens shows "Offline", and nothing is decided until MailPilot answers again. Then the current card comes back by itself.

**If the lens is gone** (the back gesture closes the app on the glasses, and the phone isn't told), say "lens" or use Reset → Reopen the lens. Voice keeps working without it.

## What is safe

- **MailPilot never sends mail**, from the glasses either. A reply is saved to Outlook's Drafts.
- What can be undone (delete to Deleted Items, done, a date, filing) happens at once, and "undo" takes it back for the whole walk.
- What leaves MailPilot or can't be undone asks first, on a card that only your pinch or your own fixed words answer. The assistant can't answer its own card.
- The relay only ever carries ciphertext: AES-256-GCM with a key only this phone and MailPilot have, one key per direction, and the device, direction and time bound into every message. A recorded message can't be played again later.
- Audio goes from the phone straight to your own speech server, never through the relay.
- Nothing secret is in this repository or in what it builds.

## When something gets stuck

The home screen shows what is connected: MailPilot, the glasses, the lens, the microphone and the speech server. The arrow at the top left has **Reopen the lens** and **Reset the glasses connection**.

If the app says the glasses keep refusing, switch them off and on with the power switch, then use Reopen the lens. One tap on the side of the glasses pauses their session (the app says so); a second tap resumes it.

Settings → **Share the log** gives a text file with what the app did and the words it heard. It holds no mail text and no keys.

## How it is built

There is no Mac in this project. [project.yml](project.yml) is an XcodeGen recipe, and [the workflow](.github/workflows/ios.yml) is the compiler. Before it builds the app it compiles the link code on its own and opens messages that MailPilot's own code sealed with a made-up key ([tools/interop](tools/interop)): if the two sides ever disagree on a key or a field name, the build fails there.

| Folder | What is in it |
|---|---|
| `Sources/Link` | the messages, the encryption, the relay connection, pairing, the Keychain |
| `Sources/Voice` | the microphone, speech to text, speech out, and the conversation loop |
| `Sources/Glasses` | the glasses session, the lens, and how a card becomes the toolkit's layout |
| `Sources/Walk` | the order things start and stop in, and what happens when something drops |
| `Sources/UI` | the phone's screens |

Meta's Device Access Toolkit is pinned at 1.0.1, and the code is in Swift 5 mode.

## Rules of the glasses it follows

Found while testing another app on these glasses and confirmed on Meta's developer forum.

| Rule | What this app does |
|---|---|
| Bringing up the Bluetooth headset microphone while a toolkit session is open ends the session ([ios#342](https://github.com/meta/meta-wearables-dat-ios/issues/342)). | The headset link comes up before any session and goes down after the last one. |
| Dropping and re-making the headset link a few times can make the glasses refuse sessions until they are switched off and on ([ios#375](https://github.com/meta/meta-wearables-dat-ios/issues/375)). | The link stays up for the whole walk, also while the microphone "sleeps". |
| The back gesture closes the app on the glasses, and apps can't catch it ([ios#349](https://github.com/meta/meta-wearables-dat-ios/issues/349)). | Every card has a button. A card that has been up for a while without a pinch is shown on a new session; "lens" brings it back at any time. |
| One tap pauses a session, a second tap resumes ([ios#312](https://github.com/meta/meta-wearables-dat-ios/issues/312)). | It says "paused" and waits for the tap; it never restarts a paused session. |
| Keep one session, leave 2 seconds between sessions, and don't retry in a loop ([ios#292](https://github.com/meta/meta-wearables-dat-ios/issues/292)). | One session, a 2 second gap, one retry, and after two refusals it waits until you ask. |
| The display fails once when it is asked for too early. | It is retried every 0.75 seconds, up to ten times. |
| The toolkit's own microphone needs a camera stream, which mutes app sound and lights the LED. | The microphone is the headset link's; the camera is never used. |
