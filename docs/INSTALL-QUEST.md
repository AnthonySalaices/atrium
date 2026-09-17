# Putting Glasshouse on a Quest

The headset app is not on the Meta store. You sideload it: build the APK (or take one from a
release), push it over `adb`, and pair it with your host once. Twenty minutes the first time,
about thirty seconds every time after.

Nothing secret is baked into the APK. It learns your host's address and a token from the pairing
card on first run, so the same file can be installed on any headset without leaking anything.

---

## 1. Turn on developer mode

Developer mode is a per-headset setting on your Meta account, not something in the headset's own
menus — you flip it in the phone app.

1. Create an organisation at <https://developer.oculus.com/manage/organizations/create/> if the
   account has never had one. A name is all it needs; there is no fee and no review.
2. Meta Horizon app on your phone → **Devices** → your headset → **Headset settings** →
   **Developer Mode** → on.
3. Reboot the headset (hold the power button → Restart). The toggle does not take effect until it
   comes back.

> _Screenshot pending: the Developer Mode toggle in the Meta Horizon app —
> `docs/img/quest-developer-mode.png`._

## 2. Connect adb

Plug the headset into the computer with a USB-C cable, put it on, and accept **Allow USB
debugging** when it appears inside the headset. You have to be wearing it; the dialog is in VR,
not on the computer.

```bash
adb devices          # your headset's serial, state "device"
```

If it says `unauthorized`, the dialog is still waiting inside the headset. If nothing is listed at
all, try another cable — plenty of USB-C cables carry power only.

### Optional: over Wi-Fi

```bash
adb tcpip 5555                       # with the cable still attached
adb connect <headset-ip>:5555        # then the cable can come out
```

⚠️ **Wireless adb does not survive a reboot** on a retail headset, and the headset drops off the
network entirely while it is asleep. Re-arming it means plugging the cable back in.

## 3. Install

```bash
tools/build-apk.sh                   # produces godot/build/glasshouse.apk
tools/deploy-quest.sh                # installs, launches, and tees logcat into logs/
```

Or by hand:

```bash
adb install -r -g godot/build/glasshouse.apk
adb shell monkey -p io.github.anthonysalaices.glasshouse \
    -c android.intent.category.LAUNCHER 1
```

`-g` grants the manifest's permissions up front, which saves a prompt in VR.

The app appears under **Library → Unknown Sources** — not in the main app grid. That list is
alphabetical and easy to miss; Glasshouse is under G.

## 4. Start the host and pair

On the computer:

```bash
glasshouse up          # or ./start.sh --lan from a checkout
glasshouse pair        # prints a 6-digit code, valid once
```

⛔ **The daemon must be bound to the LAN.** `./start.sh` alone binds loopback, which the headset
cannot reach — the card will find nothing and the app will sit at "Looking for hosts on this
network…".

Put the headset on. The first run shows the pairing card:

```
Glasshouse
Run  glasshouse pair  on your computer, then enter the code.

Found: <your computer> (<address>)   — Tab to accept the first
Host   ▏
Code
```

- Discovery is a broadcast on your network; every daemon that hears it answers with its name.
  **Tab** accepts the first one found, or type an address yourself.
- **Enter** moves to the code field (**Tab** switches back and forth). Type the six digits and
  press **Enter** again. **Esc** closes the card.
- A code is valid for **10 minutes** and can be redeemed once. Five wrong codes lock pairing for
  five minutes — the card says so rather than failing silently.
- The token is stored on the headset (`user://glasshouse.cfg`) and the card does not come back.

> _Screenshot pending: the pairing card as seen in the headset —
> `docs/img/quest-pairing-card.png`._

**ctrl+alt+P** opens the card again at any time — after moving the host to a new address, or to
point the headset at a different machine.

## 5. A keyboard

Typing needs a real Bluetooth keyboard paired to the **headset** (Settings → Devices →
Bluetooth). Anything that pairs will work; the app does not care what it is.

⚠️ **Check the keyboard is actually bonded before concluding anything is broken.** A keyboard
that looks connected on the desk but is bonded to a laptop produces exactly the same symptom as a
dead input path: a terminal that ignores every key.

Mac-layout keyboards send ⌘ where a PC sends Ctrl; the app accepts either as the chord modifier.

## When it does not work

| what you see | what it usually is |
|---|---|
| "Looking for hosts on this network…" forever | daemon bound to loopback (`./start.sh --lan`), or the headset is on a different network — a guest SSID will not see it |
| Card says the code is wrong when you are sure it is not | codes live in the daemon's memory: restarting it between `glasshouse pair` and typing the code voids them. Run `glasshouse pair` again |
| App installed but not in the library | look under **Unknown Sources**, not the app grid |
| Everything works until you take the headset off | doffing backgrounds the app. Putting it back on resumes it; if it does not, `adb shell am start -n io.github.anthonysalaices.glasshouse/.GodotAppLauncher` |
| `adb: no devices` after it worked yesterday | wireless adb does not survive a reboot — reconnect with the cable |

Logs from the headset, which is where anything unexplained ends up:

```bash
adb logcat -d -v brief godot:V "*:S" | grep -E '\[term\]|\[keys\]|\[backdrop\]|\[pair\]'
```
