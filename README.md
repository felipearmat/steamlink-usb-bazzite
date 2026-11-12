# Steam Link VR over USB on Bazzite

Play PC VR on a Meta Quest through **Steam Link over the USB cable** on Bazzite, while the
headset's Wi-Fi stays on (Steam sign-in, PC discovery and controllers keep working).

Current SteamVR streams over every network path it finds at once ("Uber link"): with the Quest's
USB networking up, the video goes through the cable, with Wi-Fi as a live backup. This project
sets that up and keeps it working:

- configures the headset's USB networking (NCM) and a static address on the PC side, and keeps
  the headset in that mode (Horizon OS sometimes switches back to file transfer on its own);
- keeps the PC session active and its screen on while the Quest is plugged in and awake (with
  the screen off, the headset never manages to connect);
- fixes the SteamVR and Steam problems that otherwise break the stream on Linux (see
  [Troubleshooting](#troubleshooting)).

It works the same in desktop mode and in Gaming Mode (gamescope).

## Requirements

- Bazzite (other Fedora Atomic images should work), native Steam.
- Steam client on the **beta** channel and **SteamVR on the beta branch**. Both are required: with
  the stable SteamVR (2.18.4, November 2026) the headset connects and the stream drops seconds
  later; 2.19 beta works. The installer offers to switch both.
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
and needs your password once (firewall helper, udev rule, `setcap` on SteamVR). It also runs
unattended (`--yes`, over SSH): with passwordless sudo it never waits for a graphical prompt.

If the installer closes Steam (to switch a beta), reopen Steam **with the screen on**: see
[Troubleshooting](#troubleshooting).

## Use

1. Plug the Quest in and put it on. The PC screen turns on and the PC stays awake.
2. Open **Steam Link** in the headset and connect to the PC.

Nothing to run on the PC. The **first** connection from a headset asks for pairing: the headset
shows a PIN and Steam opens a dialog on the PC's screen to type it (once per headset). Close any
VR game started from the desktop before connecting; Steam Link starts SteamVR itself.

```bash
journalctl --user -u quest-cable -f       # what the service is doing
systemctl --user stop quest-cable         # pause until the next login
./install.sh --uninstall                  # remove everything
```

Over Wi-Fi only (no cable) the service cannot tell the headset is in use: make sure the PC's
screen is on when you connect.

## How it works

| Piece | Where | What it does |
| --- | --- | --- |
| `quest-cable-daemon` | `~/.local/bin` | The watch loop (see below). |
| `quest-cable.service` | `~/.config/systemd/user` | Starts the daemon with every login. |
| `quest-cable.conf` | `~/.config` | adb path, headset USB address, Steam folder, options below. |
| `quest-usb` profile | NetworkManager | Static address on the headset's USB network. |
| `51-meta-quest.rules` | `/etc/udev/rules.d` | Lets adb open the Quest as your user (no reboot needed). |
| `steamvr-setcap` + `.path` unit | `/usr/local/bin`, `/etc/systemd/system` | Re-grants `cap_sys_nice` to SteamVR's compositor after every SteamVR update. |
| `LegacySteamRuntime` link | Steam's default library | Only when SteamVR lives in another library (see Troubleshooting). |
| `quest-wifi-video-block` + sudoers rule | `/usr/local/bin`, `/etc/sudoers.d` | Wi-Fi video block, only used with an old vrlink (see below). |

Every couple of seconds the daemon:

1. Links `LegacySteamRuntime` into Steam's default library if Steam installed it elsewhere
   (needed over Wi-Fi too).
2. If the Quest is on USB, reachable over adb and **awake**: wakes the PC's screen and holds an
   idle inhibitor (the session stays active, the screen stays on, the PC does not suspend). It
   lets go when the headset sleeps (taken off, or left charging) or is unplugged.
3. If Steam Link is running: keeps the headset USB in networking (NCM) mode, switching it back
   at most once every 15 s.
4. Only with an old vrlink that lacks "Uber link": once the session is up, the headset has been
   streaming for 8 s and answers over the cable, it blocks the video port (UDP 10400) between the
   PC and the headset's Wi-Fi address so the video has to use the cable; unblocked at once if any
   of that stops being true. With current SteamVR this is skipped: blocking Wi-Fi freezes the
   stream.

Options in `~/.config/quest-cable.conf` (then `systemctl --user restart quest-cable`):

- `BLOCK_WIFI_VIDEO=auto|yes|no`: `auto` (default) blocks only without Uber link.
- `KEEP_SCREEN_ON=yes|no`: step 2 above.

## Troubleshooting

All of these happened while setting this up on a real Bazzite desktop (Quest 3, RX 9060 XT,
November 2026). The installer and the service handle the first five; the logs named here are in
`~/.local/share/Steam/logs/`.

- **The headset keeps "searching", and the PC's screen is off.** With the screen off (DPMS, KDE
  Wayland) Steam still answers discovery, but the headset never sends its connection request
  (nothing new in `remote_connections.txt`). The service now keeps the screen on while the Quest
  is plugged in and awake; over Wi-Fi only, turn the screen on yourself.
- **Connects, then "the PC stopped streaming" and SteamVR crashes.** `vrserver.txt` shows
  `timeout - vrcompositor process is not running` and `Failed Watchdog timeout ... Aborting`;
  `vrstartup-linux.txt` loops on `Relaunch under scout LDLP runtime` until `Argument list too
  long`. Two causes, both fixed:
  - SteamVR on the stable branch: switch it to the beta (`install.sh` offers to).
  - SteamVR in a library other than Steam's default one: `vrcompositor-launcher.sh` looks for the
    `LegacySteamRuntime` tool (appid 4690330) only in the default library, while Steam installs
    it next to SteamVR, the first time SteamVR starts. The installer and the service link it:
    `~/.local/share/Steam/steamapps/common/LegacySteamRuntime -> <library>/steamapps/common/LegacySteamRuntime`.
- **Connects, then the image freezes.** `driver_vrlink.txt` restarts its Wi-Fi socket every
  second (`RXThread start (<PC LAN address>)`). That was this project blocking the Wi-Fi video
  while vrlink's Uber link was using it; now only done for an old vrlink.
- **Steam stuck at "Installing update..." forever.** Steam's update window blocks the whole
  client while the screen is off, e.g. when Steam is restarted over SSH or after the display went
  to sleep. Turn the screen on (`kscreen-doctor --dpms on` from a shell in the session) and it
  continues by itself. The installer reminds you whenever it closes Steam.
- **`install.sh` waits forever when run without a terminal.** It used `pkexec`, which opens a
  password dialog on the local screen. It now uses `sudo` directly when it needs no password.
- **The headset keeps "searching" (screen on).** Check `remote_connections.txt`:
  `k_ERemoteDeviceStreamingUnauthorized` means the headset is not paired yet; look for the PIN
  dialog on the PC's screen.
- **Stuck on "Connecting..." after a disconnect, a headset reboot or a PC reboot.** Seen after
  changing the headset refresh rate: the headset first keeps sending to SteamVR's vrlink port
  (UDP 10400) as if resuming the old session, and only some minutes later sends the normal
  request to Steam (`Received streaming request` in `remote_connections.txt`), which then starts
  SteamVR and connects. Give it a few minutes; closing Steam Link in the headset and opening it
  again, or rebooting, also got it going. The cause is not known yet.
- **"Allow USB debugging" every time.** Tick "Always allow from this computer". Apps that use adb
  inside the headset (e.g. Quest Game Optimizer) ask on their own; granting them
  `WRITE_SECURE_SETTINGS` once (`adb shell pm grant <package> android.permission.WRITE_SECURE_SETTINGS`)
  usually stops their prompts.

## Notes

- **adb.** The installer downloads Google's `platform-tools-latest-linux.zip` first. The
  Homebrew cask (`android-platform-tools`) pins a versioned URL that Google sometimes removes
  (it returned 404 in November 2026), so it is only offered as a fallback.
- **SteamVR updates.** Each update replaces `vrcompositor-launcher` and drops `cap_sys_nice`;
  the `steamvr-setcap.path` unit grants it again automatically, so SteamVR does not start
  asking for a password (an invisible dialog in Gaming Mode) after an update.
- **Beat Saber black screen.** If the game shows a black void through Steam Link, the usual fix
  on Linux is the legacy 1.40.8 build (Properties > Betas, or a BSManager instance).
- **Bazzite-Deck: the Steam beta channel also moves the OS to `:testing`.** On the `bazzite-deck`
  images, Steam in the beta channel (shown as "RC" in the client) calls `steamos-select-branch
  beta` every time its UI loads, and Bazzite maps that to a rebase to the `:testing` image
  ([ublue-os/bazzite#5938](https://github.com/ublue-os/bazzite/issues/5938),
  [#1543](https://github.com/ublue-os/bazzite/issues/1543)). Steam Link VR needs the Steam beta,
  so expect the OS to follow it. The desktop images (`bazzite`, KDE/GNOME) do not ship that hook:
  a desktop install with the Steam beta stayed on `:stable` (tested November 2026).
- If the headset shows **"Allow access to data?"** / file transfer, dismiss it: accepting switches
  the USB to MTP (the service switches it back to networking).
- Leaving the stream (Meta button > quit, or restarting SteamVR) and reconnecting works as usual.
