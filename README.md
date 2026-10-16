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
- Steam client on the beta channel, SteamVR installed (beta branch recommended).
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

Nothing to run on the PC.

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

Every couple of seconds the daemon checks, in this order:

1. Quest on USB, reachable over adb, and the Steam Link app is running. Otherwise it does nothing.
2. The headset USB is in networking (NCM) mode. Horizon OS sometimes switches back to file
   transfer (MTP) on its own, so the daemon switches it back, at most once every 15 s.
3. SteamVR's vrlink session for the current `vrserver` is up, the headset has been streaming for
   8 s, and the headset answers a ping over the cable. Only then is the video port (UDP 10400)
   between the PC and the headset's Wi-Fi address blocked in both directions.

If any of these stops being true, the rules are removed at once. They are also removed when the
service stops, and they never survive a reboot.

## Notes

- **Bazzite-Deck: the Steam beta channel also moves the OS to `:testing`.** On the `bazzite-deck`
  images, Steam in the beta channel (shown as "RC" in the client) calls `steamos-select-branch
  beta` every time its UI loads, and Bazzite maps that to a rebase to the `:testing` image
  ([ublue-os/bazzite#5938](https://github.com/ublue-os/bazzite/issues/5938),
  [#1543](https://github.com/ublue-os/bazzite/issues/1543)). Steam Link VR needs the Steam beta,
  so expect the OS to follow it. To stay on `:stable` anyway you can switch the Steam client
  back to stable (Steam Link VR then stops working) or try denying the `pkexec` call to
  `steamos-polkit-helpers/steamos-select-branch` with a polkit rule (not tested here).
- If the headset shows **"Allow access to data?"** / file transfer, dismiss it: accepting switches
  the USB to MTP (the service switches it back, but the stream briefly falls back to Wi-Fi).
- Leaving the stream (Meta button > quit, or restarting SteamVR) unblocks Wi-Fi; reconnecting
  works as usual.
- The firewall rules only touch UDP port 10400 for the headset's current Wi-Fi address.
