# Steam Link VR over USB on Bazzite

Play PC VR on a Meta Quest through **Steam Link over the USB cable** on Bazzite, while the
headset's Wi-Fi stays on (Steam sign-in, PC discovery and controllers keep working).

A small user service watches for a Steam Link session. Once the stream is running and the cable
answers, it blocks the Steam Link video port over Wi-Fi, so SteamVR's vrlink driver sends the
video through the cable instead. If anything goes wrong (cable unplugged, headset switching USB
modes, stream ended), it unblocks immediately and the stream falls back to Wi-Fi instead of
freezing. It works the same in desktop mode and in Gaming Mode (gamescope).

## Requirements

- Bazzite (other Fedora Atomic images should work), native Steam.
- Steam client on the beta channel and **SteamVR on the beta branch** (both required: with the
  stable SteamVR 2.18.4 the headset connects and the stream drops seconds later; 2.19 beta works).
- Meta Quest with **Developer Mode** enabled and **Steam Link** installed (beta channel).
- A USB **data** cable (USB 3 recommended).

`install.sh` checks all of this and walks you through what is missing.

## Install

```bash
git clone https://github.com/felipearmat/steamlink-usb-bazzite.git
cd steamlink-usb-bazzite
./install.sh            # or ./install.sh --check to only see what is missing
```

Connect the Quest with the cable and put it on before running it: the installer needs to accept
the USB debugging prompt and to see the headset's USB network once. It asks before every change
and needs your password once (for the firewall helper, and for `setcap` on SteamVR if needed).

## Use

1. Plug the Quest in and open **Steam Link** in the headset.
2. Connect to the PC as usual. The session starts over Wi-Fi; a few seconds later the video moves
   to the cable.

Nothing to run on the PC. The **first** connection from a headset asks for pairing: the headset
shows a PIN and Steam opens a dialog on the PC's screen to type it (once per headset). Close any
VR game started from the desktop before connecting; Steam Link starts SteamVR itself.

```bash
journalctl --user -u quest-cable -f       # what the service is doing
systemctl --user stop quest-cable         # pause until the next login
./install.sh --uninstall                  # remove everything
```

## How it works

| Piece | Where | What it does |
| --- | --- | --- |
| `quest-cable-daemon` | `~/.local/bin` | The watch loop (see below). |
| `quest-cable.service` | `~/.config/systemd/user` | Starts the daemon with every login. |
| `quest-cable.conf` | `~/.config` | adb path, headset USB address, Steam folder. |
| `quest-wifi-video-block` | `/usr/local/bin` | Adds/removes the two firewall rules (runtime only). |
| sudoers rule | `/etc/sudoers.d/quest-wifi-video-block` | Lets the service run only that helper without a password. |
| `quest-usb` profile | NetworkManager | Static address on the headset's USB network. |
| `51-meta-quest.rules` | `/etc/udev/rules.d` | Lets adb open the Quest as your user (no reboot needed). |
| `steamvr-setcap` + `.path` unit | `/usr/local/bin`, `/etc/systemd/system` | Re-grants `cap_sys_nice` to SteamVR's compositor after every SteamVR update. |
| `LegacySteamRuntime` link | Steam's default library | Only when SteamVR lives in another library (see Troubleshooting). |

Every couple of seconds the daemon checks, in this order (before that, it links
`LegacySteamRuntime` into Steam's default library if Steam installed it elsewhere):

1. Quest on USB, reachable over adb, and the Steam Link app is running. Otherwise it does nothing.
2. The headset USB is in networking (NCM) mode. Horizon OS sometimes switches back to file
   transfer (MTP) on its own, so the daemon switches it back, at most once every 15 s.
3. SteamVR's vrlink session for the current `vrserver` is up, the headset has been streaming for
   8 s, and the headset answers a ping over the cable. Only then is the video port (UDP 10400)
   between the PC and the headset's Wi-Fi address blocked in both directions.

If any of these stops being true, the rules are removed at once. They are also removed when the
service stops, and they never survive a reboot.

## Troubleshooting

Problems found while setting this up on a real Bazzite desktop (November 2026); the installer and
the service now avoid the first three.

- **Connects, then "the PC stopped streaming" and SteamVR crashes.** `vrserver.txt` shows
  `timeout - vrcompositor process is not running` and `Failed Watchdog timeout ... Aborting`, and
  `vrstartup-linux.txt` loops on `vrcompositor-launcher.sh: Relaunch under scout LDLP runtime`
  until `Argument list too long`. Two causes, both required to fix:
  - SteamVR on the stable branch: switch it to the beta (`install.sh` offers to).
  - SteamVR in a library other than Steam's default one: the launcher looks for the
    `LegacySteamRuntime` tool (appid 4690330) only in the default library, while Steam installs
    it next to SteamVR. Fix: `ln -s <library>/steamapps/common/LegacySteamRuntime
    ~/.local/share/Steam/steamapps/common/LegacySteamRuntime` (done automatically).
- **Steam stuck at "Installing update..." forever.** Steam's update window blocks the whole
  client while the screen is off (DPMS) on KDE Wayland, e.g. when Steam is restarted over SSH or
  after the display went to sleep. Turn the screen on (`kscreen-doctor --dpms on` from a shell
  in the session) and it continues by itself.
- **`install.sh` waits forever when run without a terminal.** Fixed: it uses `sudo` directly
  when it needs no password, instead of a `pkexec` dialog on the local screen.
- **The headset keeps "searching".** Check `~/.local/share/Steam/logs/remote_connections.txt`:
  `k_ERemoteDeviceStreamingUnauthorized` means the headset is not paired yet; look for the PIN
  dialog on the PC's screen.

## Notes

- **Valve's own USB mode.** SteamVR 2.18 (October 2026) added official wired USB support for the
  Quest in Steam Link, built on the same USB networking (NCM). It was announced for Windows and
  has not been confirmed on Linux yet (the vrlink driver does open a socket on the USB
  interface, next to Wi-Fi). This service does not get in its way: if the official
  mode already sends the video over the cable, blocking the Wi-Fi video port changes nothing; if
  it does not, the service still moves the video to the cable.
- **adb.** The installer downloads Google's `platform-tools-latest-linux.zip` first. The
  Homebrew cask (`android-platform-tools`) pins a versioned URL that Google sometimes removes
  (it returned 404 in November 2026), so it is only offered as a fallback.
- **SteamVR updates.** Each update replaces `vrcompositor-launcher` and drops `cap_sys_nice`;
  the `steamvr-setcap.path` unit grants it again automatically, so SteamVR does not start
  asking for a password (an invisible dialog in Gaming Mode) after an update.
- **Beat Saber black screen.** If the game shows a black void through Steam Link, the usual fix
  on Linux is the legacy 1.40.8 build (Properties > Betas).
- **Bazzite-Deck: the Steam beta channel also moves the OS to `:testing`.** On the `bazzite-deck`
  images, Steam in the beta channel (shown as "RC" in the client) calls `steamos-select-branch
  beta` every time its UI loads, and Bazzite maps that to a rebase to the `:testing` image
  ([ublue-os/bazzite#5938](https://github.com/ublue-os/bazzite/issues/5938),
  [#1543](https://github.com/ublue-os/bazzite/issues/1543)). Steam Link VR needs the Steam beta,
  so expect the OS to follow it. To stay on `:stable` anyway you can switch the Steam client
  back to stable (Steam Link VR then stops working) or try denying the `pkexec` call to
  `steamos-polkit-helpers/steamos-select-branch` with a polkit rule (not tested here). The
  desktop images (`bazzite`, KDE/GNOME) do not ship that hook: a desktop install with the Steam
  beta stayed on `:stable` (tested November 2026).
- If the headset shows **"Allow access to data?"** / file transfer, dismiss it: accepting switches
  the USB to MTP (the service switches it back, but the stream briefly falls back to Wi-Fi).
- Leaving the stream (Meta button > quit, or restarting SteamVR) unblocks Wi-Fi; reconnecting
  works as usual.
- The firewall rules only touch UDP port 10400 for the headset's current Wi-Fi address.
