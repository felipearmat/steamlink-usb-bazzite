#!/usr/bin/env bash
# Steam Link VR over USB on Bazzite (Meta Quest).
#
# Checks every prerequisite, fixes what it can (always asking first) and installs the
# quest-cable user service, which keeps the Quest's USB network up so SteamVR streams over the
# cable, keeps the PC awake with the screen on while the headset is plugged in and awake, and
# works around the SteamVR/Steam problems listed in the README's Troubleshooting section.
#
#   ./install.sh              check + install
#   ./install.sh --check      only report what is missing, change nothing
#   ./install.sh --uninstall  remove everything this script installed
#   --yes                     answer yes to every question (with install or --uninstall)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN_DIR=$HOME/.local/bin
CONF=$HOME/.config/quest-cable.conf
UNIT_DIR=$HOME/.config/systemd/user
UNIT=quest-cable.service
HELPER=/usr/local/bin/quest-wifi-video-block
SUDOERS=/etc/sudoers.d/quest-wifi-video-block
SETCAP_HELPER=/usr/local/bin/steamvr-setcap
SETCAP_UNIT=steamvr-setcap
UDEV_RULE=/etc/udev/rules.d/51-meta-quest.rules
NM_CON=quest-usb
QUEST_VENDOR=2833
PKG=com.valvesoftware.steamlinkvr
STEAMVR_APPID=250820
PT_DIR=$HOME/.local/share/android-platform-tools
PT_URL=https://dl.google.com/android/repository/platform-tools-latest-linux.zip
export PATH="$BIN_DIR:/home/linuxbrew/.linuxbrew/bin:$PATH"

MODE=install
YES=0
for arg in "$@"; do
  case $arg in
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (use --check, --uninstall, --yes or --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
ISSUES=()
step() { echo; echo "${B}== $*${N}"; }
ok()   { echo "  ${G}✔${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
bad()  { echo "  ${R}✘${N} $*"; ISSUES+=("$*"); }
info() { echo "    $*"; }
die()  { echo; echo "${R}$*${N}" >&2; exit 1; }

# ask "question" -> 0 for yes. Never changes anything in --check mode.
ask() {
  local a
  [ "$MODE" = check ] && return 1
  (( YES )) && { echo "  ? $1 yes (--yes)"; return 0; }
  read -r -p "  ? $1 [y/N] " a < /dev/tty
  [[ $a =~ ^[Yy] ]]
}
pause() { [ "$MODE" = check ] || (( YES )) || read -r -p "  > $1 (Enter to continue) " _ < /dev/tty; }

# Root commands: sudo when it needs no password or there is a terminal, the graphical polkit
# prompt otherwise (e.g. started from a desktop shortcut). Without the sudo -n check, a run over
# SSH or from a script waits for a pkexec dialog on the local screen.
as_root() {
  if sudo -n true 2>/dev/null; then sudo -n "$@"
  elif [ -t 0 ]; then sudo "$@"
  else pkexec "$@"; fi
}

ADB=""
aq() { timeout 8 "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }
os_field() { (. /etc/os-release && eval "echo \"\${$1:-}\""); }

# ---------------------------------------------------------------------------------------------
check_system() {
  step "System"
  local id variant c
  id=$(os_field ID)
  variant=$(os_field VARIANT_ID)
  if [ "$id" = bazzite ]; then ok "Bazzite ($variant)"; else warn "not Bazzite ($id); Fedora Atomic should behave the same"; fi
  for c in systemctl nmcli firewall-cmd sudo ping timeout awk curl; do
    command -v "$c" >/dev/null || die "required command missing: $c"
  done
  if systemctl is-active -q firewalld; then ok "firewalld running"; else bad "firewalld is not running (sudo systemctl enable --now firewalld)"; fi
  if systemctl is-active -q NetworkManager; then ok "NetworkManager running"; else bad "NetworkManager is not running"; fi
  if id -nG | grep -qw wheel; then ok "$USER is an administrator (wheel)"; else bad "$USER is not in the wheel group: sudo will not work"; fi
}

# ---------------------------------------------------------------------------------------------
STEAM_DIR=""
in_gamescope() { [ "${XDG_CURRENT_DESKTOP:-}" = gamescope ] || pgrep -x gamescope-wl >/dev/null; }
steam_running() { pgrep -x steam >/dev/null; }

# Closes Steam (desktop mode). Returns 1 if it is still running after 90 s.
close_steam() {
  steam_running || return 0
  info "closing Steam..."
  steam -shutdown >/dev/null 2>&1 &
  local i
  for i in $(seq 1 45); do steam_running || return 0; sleep 2; done
  return 1
}

# Steam's update window (shown while a client update installs) blocks the whole client when the
# screen is off on KDE Wayland: Steam then sits at "Installing update..." forever. It happens
# when Steam is reopened over SSH or after the display went to sleep.
reopen_hint() {
  info "Reopen Steam with the screen on: while the display is off (DPMS) its update window"
  info "hangs at \"Installing update...\". Over SSH, wake it first: kscreen-doctor --dpms on"
}

# Steam's default library plus every library listed in libraryfolders.vdf.
steam_libraries() {
  { echo "$STEAM_DIR"; grep -oP '"path"\s*"\K[^"]+' "$STEAM_DIR/steamapps/libraryfolders.vdf" 2>/dev/null; } |
    awk '!seen[$0]++'
}

check_steam() {
  step "Steam client"
  local d
  for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [ -d "$d/steamapps" ] && { STEAM_DIR=$(readlink -f "$d"); break; }
  done
  [ -n "$STEAM_DIR" ] || die "Steam not found. Open Steam once, sign in and run this script again."
  ok "Steam at $STEAM_DIR"
  case $STEAM_DIR in */com.valvesoftware.Steam/*) warn "Flatpak Steam: only the native Steam that ships with Bazzite was tested" ;; esac

  local beta want
  beta=$(cat "$STEAM_DIR/package/beta" 2>/dev/null)
  if [ -n "$beta" ]; then ok "Steam client beta enabled ($beta)"; return; fi

  if pgrep -a steam | grep -q -- -steamdeck || [[ $(os_field VARIANT_ID) == *deck* ]]; then
    want=steamdeck_publicbeta
  else
    want=publicbeta
  fi
  warn "Steam client is not on the beta"
  info "Steam > Settings > Interface (desktop) or System (Gaming Mode) > Client Beta Participation"
  if in_gamescope; then
    pause "Switch to the beta there (Steam restarts by itself), then"
  elif ask "Switch the Steam client to the beta now? (closes Steam; it updates on the next start)"; then
    if close_steam; then
      echo "$want" > "$STEAM_DIR/package/beta"
      ok "beta set ($want). Open Steam and let it update before using VR."
      reopen_hint
    else
      bad "Steam did not close; switch to the beta in the settings instead"
    fi
    return
  fi
  [ -n "$(cat "$STEAM_DIR/package/beta" 2>/dev/null)" ] || bad "Steam client is not on the beta"
}

# ---------------------------------------------------------------------------------------------
STEAMVR_DIR=""
steamvr_branch() {
  local key
  key=$(awk '/"UserConfig"/{u=1} u && /"BetaKey"/{gsub(/"/,"",$2); print $2; exit}' "$1")
  echo "${key:-public}"
}

# Sets "BetaKey" "beta" in the UserConfig block of SteamVR's appmanifest (what the Betas tab
# writes). Only with Steam closed: a running Steam rewrites the file. Keeps a .bak copy.
set_steamvr_beta() {
  cp -p "$1" "$1.bak" || return 1
  python3 -I - "$1" <<'PY'
import re, sys
f = sys.argv[1]
t = open(f, encoding="utf-8").read()
m = re.search(r'("UserConfig"[ \t]*\n([ \t]*)\{)(.*?)(\n\2\})', t, re.S)
if m:
    body = m.group(3)
    if re.search(r'"BetaKey"', body):
        body = re.sub(r'"BetaKey"(\s*)"[^"]*"', r'"BetaKey"\1"beta"', body)
    else:
        body += '\n' + m.group(2) + '\t"BetaKey"\t\t"beta"'
    t = t[:m.start()] + m.group(1) + body + m.group(4) + t[m.end():]
else:
    i = t.rstrip().rfind("}")
    t = t[:i] + '\t"UserConfig"\n\t{\n\t\t"BetaKey"\t\t"beta"\n\t}\n' + t[i:]
open(f, "w", encoding="utf-8").write(t)
PY
}

# vrcompositor-launcher.sh looks for the LegacySteamRuntime tool (appid 4690330) only in Steam's
# default library. When SteamVR lives in another library Steam installs the tool there, the
# launcher falls back to ubuntu12_32/steam-runtime/run.sh (only a stub on current Steam betas)
# and relaunches itself until "Argument list too long": the compositor never starts and the
# stream drops. A symlink in the default library fixes it (the service keeps it in place too).
check_legacy_runtime() {
  local want="$STEAM_DIR/steamapps/common/LegacySteamRuntime" lib found=""
  if [ -x "$want/legacy-steam-runtime" ]; then
    ok "LegacySteamRuntime reachable from Steam's default library"
    return 0
  fi
  while read -r lib; do
    [ -x "$lib/steamapps/common/LegacySteamRuntime/legacy-steam-runtime" ] &&
      { found="$lib/steamapps/common/LegacySteamRuntime"; break; }
  done < <(steam_libraries)
  if [ -z "$found" ]; then
    warn "LegacySteamRuntime not installed yet (Steam adds it the first time SteamVR starts);"
    info "the quest-cable service links it into the default library when it appears"
    return 0
  fi
  if [ "$MODE" = check ]; then
    bad "LegacySteamRuntime is in $found, but SteamVR's compositor only looks in $want"
    return 0
  fi
  mkdir -p "$STEAM_DIR/steamapps/common" && ln -sfn "$found" "$want" &&
    ok "LegacySteamRuntime linked into Steam's default library (SteamVR's compositor looks only there)" ||
    bad "could not link $want -> $found"
}

check_steamvr() {
  step "SteamVR"
  local lib manifest=""
  while read -r lib; do
    if [ -f "$lib/steamapps/appmanifest_$STEAMVR_APPID.acf" ]; then
      manifest="$lib/steamapps/appmanifest_$STEAMVR_APPID.acf"
      STEAMVR_DIR="$lib/steamapps/common/SteamVR"
      break
    fi
  done < <(steam_libraries)
  if [ -z "$manifest" ]; then
    bad "SteamVR is not installed"
    ask "Open the SteamVR install page in Steam?" && (steam "steam://install/$STEAMVR_APPID" >/dev/null 2>&1 &)
    info "Install SteamVR, start it once, then run this script again."
    return
  fi
  ok "SteamVR installed ($STEAMVR_DIR)"

  # The beta branch is required: on the stable branch (2.18.4, Nov 2026) the headset connects
  # and the stream drops a few seconds later ("the PC stopped streaming"); 2.19 beta works.
  if [ "$(steamvr_branch "$manifest")" = beta ]; then
    ok "SteamVR on the beta branch"
  else
    warn "SteamVR is on '$(steamvr_branch "$manifest")': Steam Link VR on Linux needs the beta branch"
    info "Library > SteamVR > Properties > Betas > \"beta - SteamVR Beta Update\""
    if in_gamescope; then
      pause "Switch SteamVR to the beta there and let it update, then"
    elif ask "Switch SteamVR to the beta now? (closes Steam; SteamVR updates on the next start)"; then
      if ! close_steam; then
        bad "Steam did not close; switch SteamVR to the beta in its properties instead"
      elif set_steamvr_beta "$manifest"; then
        ok "SteamVR set to the beta. Open Steam and let SteamVR update before using VR."
        reopen_hint
      else
        bad "could not edit $manifest; switch SteamVR to the beta in its properties instead"
      fi
    fi
    [ "$(steamvr_branch "$manifest")" = beta ] || bad "SteamVR is not on the beta branch"
  fi

  check_legacy_runtime

  # Without this capability vrsetup.sh asks for it in a password dialog on every start; in
  # Gaming Mode that dialog is invisible and the connection just hangs.
  local launcher="$STEAMVR_DIR/bin/linux64/vrcompositor-launcher" getcap
  getcap=$(command -v getcap || echo /usr/sbin/getcap)
  if [ ! -f "$launcher" ]; then
    warn "vrcompositor-launcher not found; start SteamVR once and run this script again"
  elif "$getcap" "$launcher" 2>/dev/null | grep -q cap_sys_nice; then
    ok "vrcompositor has cap_sys_nice (no password prompt when SteamVR starts)"
  elif ask "vrcompositor lacks cap_sys_nice (SteamVR asks for a password at start). Grant it with sudo setcap?"; then
    if as_root setcap CAP_SYS_NICE=eip "$launcher"; then ok "capability granted"; else bad "setcap failed"; fi
  else
    bad "vrcompositor-launcher lacks cap_sys_nice (SteamVR will ask for a password at start)"
  fi
}

# ---------------------------------------------------------------------------------------------
install_adb_google() {
  local tmp
  tmp=$(mktemp -d) || return 1
  info "downloading $PT_URL"
  if ! curl -fsSL -o "$tmp/pt.zip" "$PT_URL"; then rm -rf "$tmp"; return 1; fi
  rm -rf "$PT_DIR" && mkdir -p "$PT_DIR" "$BIN_DIR"
  if command -v unzip >/dev/null; then
    unzip -q "$tmp/pt.zip" -d "$PT_DIR"
  else
    python3 -I -m zipfile -e "$tmp/pt.zip" "$PT_DIR" && chmod +x "$PT_DIR/platform-tools/adb"
  fi
  rm -rf "$tmp"
  ln -sf "$PT_DIR/platform-tools/adb" "$BIN_DIR/adb"
}

check_adb() {
  step "adb (Android platform tools)"
  ADB=$(command -v adb || true)
  if [ -z "$ADB" ]; then
    warn "adb not found"
    # Google's "latest" zip first: the Homebrew cask pins a versioned URL that Google sometimes
    # removes (404 for r37.0.2 in Nov 2026), so it is only the fallback.
    if ask "Download Google's platform-tools into $PT_DIR?"; then
      install_adb_google || warn "download failed"
    fi
    hash -r
    if ! command -v adb >/dev/null && command -v brew >/dev/null &&
       ask "Try Homebrew instead (brew install android-platform-tools)?"; then
      brew install android-platform-tools || warn "Homebrew install failed"
    fi
    hash -r
    ADB=$(command -v adb || true)
    [ -n "$ADB" ] || { bad "adb is not installed"; return 1; }
  fi
  # Keep the PATH entry (e.g. Homebrew's bin symlink), not its versioned target: survives upgrades.
  ok "adb: $ADB ($("$ADB" version | head -1))"
  "$ADB" start-server >/dev/null 2>&1
}

# ---------------------------------------------------------------------------------------------
quest_on_usb() { grep -qx "$QUEST_VENDOR" /sys/bus/usb/devices/*/idVendor 2>/dev/null; }

# Bazzite ships no udev rule for the Quest (vendor 2833), so adb cannot open it as a normal user.
# A local rule works right away, without layering android-udev-rules and rebooting.
check_udev() {
  step "USB access to the Quest (udev)"
  if grep -qs "$QUEST_VENDOR" /etc/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; then
    ok "udev rule for the Quest present"
    return 0
  fi
  [ "$MODE" = check ] && { bad "no udev rule for the Quest: adb will report 'no permissions'"; return 0; }
  ask "Install $UDEV_RULE so adb can reach the Quest without root (sudo)?" ||
    { bad "no udev rule for the Quest"; return 1; }
  local tmp
  tmp=$(mktemp)
  echo "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$QUEST_VENDOR\", MODE=\"0660\", GROUP=\"wheel\", TAG+=\"uaccess\"" > "$tmp"
  if as_root sh -c "install -m 0644 -o root -g root '$tmp' '$UDEV_RULE' && udevadm control --reload &&
                    udevadm trigger --subsystem-match=usb --attr-match=idVendor=$QUEST_VENDOR"; then
    ok "udev rule installed (unplug and replug the headset if it was already connected)"
  else
    bad "udev rule installation failed"
  fi
  rm -f "$tmp"
}

check_quest() {
  step "Quest connection"
  [ -n "$ADB" ] || { bad "headset checks skipped: adb is missing"; return 1; }
  local state why last="" a tries=0
  while :; do
    if ! quest_on_usb; then
      why=nousb
    else
      state=$(timeout 8 "$ADB" get-state 2>&1)
      case $state in
        device) ok "Quest connected and USB debugging authorized"; return 0 ;;
        *unauthorized*) why=unauthorized ;;
        *"no permissions"*|*"insufficient permissions"*) why=perms ;;
        *) why=noadb ;;
      esac
    fi
    if [ "$why" != "$last" ]; then
      case $why in
        nousb)
          warn "no Quest found on USB"
          info "Connect the headset with a USB data cable (USB 3 recommended) and put it on." ;;
        unauthorized)
          warn "USB debugging not authorized yet"
          info "Put the headset on and accept \"Allow USB debugging\" (tick \"Always allow\")." ;;
        perms)
          warn "no permission to open the headset over USB (udev rules)"
          info "Run this script again and accept the udev rule, then replug the headset." ;;
        noadb)
          warn "the Quest is on USB but adb does not see it"
          info "Enable Developer Mode: Meta Horizon phone app > Devices > Headset settings >"
          info "Developer Mode. Then accept the USB debugging prompt in the headset." ;;
      esac
      last=$why
    fi
    [ "$MODE" = check ] && { bad "Quest not reachable over adb"; return 1; }
    if (( YES )); then
      (( tries++ == 0 )) && info "waiting up to 2 minutes..."
      (( tries <= 24 )) || { bad "Quest not reachable over adb after 2 minutes"; return 1; }
      sleep 5
    else
      read -r -p "  > Enter to check again, s to skip the headset steps: " a < /dev/tty
      [[ $a =~ ^[sS] ]] && { bad "headset steps skipped"; return 1; }
      last=""
      "$ADB" kill-server >/dev/null 2>&1
      "$ADB" start-server >/dev/null 2>&1
    fi
  done
}

check_quest_app() {
  step "Steam Link app on the Quest"
  local ver wifi
  ver=$(aq dumpsys package "$PKG" | grep -m1 -oP 'versionName=\K\S+')
  if [ -z "$ver" ]; then
    bad "Steam Link is not installed on the headset (Meta Horizon Store > Steam Link)"
  else
    ok "Steam Link $ver installed"
    info "adb cannot read the release channel. For the beta: in the headset open the Library,"
    info "Steam Link > ... (three dots) > Release channel > Beta, then let it update."
    if [ "$MODE" = check ]; then
      warn "confirm the Steam Link release channel yourself (see above)"
    elif ! ask "Is Steam Link on the Quest already on the Beta channel?"; then
      pause "Switch Steam Link to the Beta channel and update it in the headset, then"
    fi
  fi

  wifi=$(aq ip -4 -br addr show wlan0 | awk '{print $3}')
  if [ -n "$wifi" ]; then
    ok "headset Wi-Fi up ($wifi): sign-in, discovery and controllers keep using it"
  else
    bad "headset Wi-Fi is off or disconnected: Steam Link needs it to sign in and find the PC"
  fi
}

# ---------------------------------------------------------------------------------------------
QUEST_IFACE="" HEADSET_IP="" HEADSET_PREFIX="" PC_IP=""
quest_iface() {
  local n
  for n in /sys/class/net/*; do
    [ "$(cat "$(readlink -f "$n/device")/../idVendor" 2>/dev/null)" = "$QUEST_VENDOR" ] &&
      { basename "$n"; return 0; }
  done
  return 1
}

check_usb_network() {
  step "USB networking (NCM)"
  local funcs i addr
  funcs=$(aq svc usb getFunctions)
  if [[ $funcs != *ncm* ]]; then
    if [ "$MODE" = check ]; then
      if [ -z "$funcs" ]; then
        warn "could not read the headset's USB mode right now (busy headset; the service retries)"
      else
        warn "headset USB is in '$funcs' mode now (the service switches it to NCM when Steam Link is open)"
      fi
      return 0
    fi
    info "switching the headset USB to networking (NCM); it reconnects..."
    aq svc usb setFunctions ncm >/dev/null
    sleep 3
    for i in $(seq 1 20); do
      timeout 3 "$ADB" get-state >/dev/null 2>&1 && quest_iface >/dev/null && break
      sleep 1
    done
  fi
  QUEST_IFACE=$(quest_iface) || { bad "the Quest created no USB network interface (charge-only cable?)"; return 1; }
  ok "PC side interface: $QUEST_IFACE"

  for i in $(seq 1 10); do
    addr=$(aq ip -4 -br addr show usb0 | awk '{print $3}')
    [ -n "$addr" ] && break
    sleep 1
  done
  [ -n "$addr" ] || { bad "the headset has no IPv4 address on its USB interface"; return 1; }
  HEADSET_IP=${addr%/*} HEADSET_PREFIX=${addr#*/}

  # PC address: a neighbouring host in the headset's subnet.
  local o1 o2 o3 o4 size net
  IFS=. read -r o1 o2 o3 o4 <<< "$HEADSET_IP"
  (( HEADSET_PREFIX >= 24 && HEADSET_PREFIX <= 30 )) || { bad "unexpected headset subnet /$HEADSET_PREFIX"; return 1; }
  size=$(( 1 << (32 - HEADSET_PREFIX) ))
  net=$(( o4 / size * size ))
  if (( o4 + 1 < net + size - 1 )); then PC_IP="$o1.$o2.$o3.$((o4 + 1))"; else PC_IP="$o1.$o2.$o3.$((o4 - 1))"; fi
  ok "headset USB address $HEADSET_IP/$HEADSET_PREFIX; the PC will use $PC_IP"
}

setup_nm_profile() {
  step "NetworkManager profile ($NM_CON)"
  local exists=0 i
  nmcli -t -f NAME connection show | grep -qx "$NM_CON" && exists=1
  if [ "$MODE" = check ]; then
    if (( exists )); then ok "profile exists"; else bad "profile $NM_CON missing"; fi
    return 0
  fi
  [ -n "$PC_IP" ] || { bad "profile not created: USB network not detected"; return 1; }
  local args=(connection.interface-name "$QUEST_IFACE" connection.autoconnect yes
              ipv4.method manual ipv4.addresses "$PC_IP/$HEADSET_PREFIX" ipv4.never-default yes
              ipv6.method disabled)
  if (( exists )); then
    nmcli connection modify "$NM_CON" "${args[@]}" || { bad "could not update $NM_CON"; return 1; }
  else
    nmcli connection add type ethernet con-name "$NM_CON" "${args[@]}" >/dev/null ||
      { bad "could not create $NM_CON"; return 1; }
  fi
  nmcli connection up "$NM_CON" >/dev/null 2>&1 || { bad "could not bring $NM_CON up"; return 1; }
  for i in $(seq 1 10); do
    ping -c1 -W1 -I "$QUEST_IFACE" "$HEADSET_IP" >/dev/null 2>&1 && { ok "headset answers over the cable ($HEADSET_IP)"; return 0; }
    sleep 1
  done
  bad "the profile is up but the headset does not answer over the cable"
}

# ---------------------------------------------------------------------------------------------
install_root_files() {
  step "Firewall helper (asks for your password once)"
  local rule="$USER ALL=(root) NOPASSWD: $HELPER"
  if cmp -s "$HERE/files/quest-wifi-video-block" "$HELPER" && sudo -n -l "$HELPER" >/dev/null 2>&1; then
    ok "helper and sudoers rule already installed"
    return 0
  fi
  [ "$MODE" = check ] && { bad "firewall helper not installed (or outdated)"; return 0; }
  info "Installs $HELPER, which only adds/removes the two rules for the"
  info "Steam Link video port (UDP 10400), and lets the service run it without a password:"
  info "  $SUDOERS: $rule"
  ask "Install them with sudo?" || { bad "firewall helper not installed"; return 1; }
  local tmp rc
  tmp=$(mktemp)
  echo "$rule" > "$tmp"
  as_root sh -c "install -m 0755 -o root -g root '$HERE/files/quest-wifi-video-block' '$HELPER' &&
              visudo -cqf '$tmp' && install -m 0440 -o root -g root '$tmp' '$SUDOERS'"
  rc=$?
  rm -f "$tmp"
  if (( rc == 0 )) && sudo -n -l "$HELPER" >/dev/null 2>&1; then ok "installed"; else bad "firewall helper installation failed"; fi
}

# SteamVR updates replace vrcompositor-launcher and drop cap_sys_nice: a root path unit grants it
# again after every install/update, so SteamVR never starts asking for a password later on.
install_setcap_watch() {
  step "Keep cap_sys_nice across SteamVR updates"
  [ -n "$STEAMVR_DIR" ] || { warn "SteamVR not found: skipped"; return 0; }
  local launcher="$STEAMVR_DIR/bin/linux64/vrcompositor-launcher"
  local manifest="${STEAMVR_DIR%/common/SteamVR}/appmanifest_$STEAMVR_APPID.acf"
  if cmp -s "$HERE/files/steamvr-setcap" "$SETCAP_HELPER" &&
     grep -qsF "$launcher" "/etc/systemd/system/$SETCAP_UNIT.path" &&
     systemctl is-enabled -q "$SETCAP_UNIT.path" 2>/dev/null; then
    ok "$SETCAP_UNIT.path already watching SteamVR"
    return 0
  fi
  [ "$MODE" = check ] && { bad "$SETCAP_UNIT.path not installed (capability lost on SteamVR updates)"; return 0; }
  ask "Install $SETCAP_UNIT.path to re-grant the capability after SteamVR updates (sudo)?" ||
    { warn "skipped: re-run this script after SteamVR updates"; return 0; }
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/svc" <<EOF
[Unit]
Description=SteamVR: grant cap_sys_nice to vrcompositor-launcher (steamlink-usb-bazzite)

[Service]
Type=oneshot
# Steam writes the files in several steps; give it a moment.
ExecStartPre=/bin/sleep 5
ExecStart=$SETCAP_HELPER "$launcher"
EOF
  cat > "$tmp/path" <<EOF
[Unit]
Description=Watch SteamVR to keep cap_sys_nice after updates (steamlink-usb-bazzite)

[Path]
PathChanged=$launcher
PathChanged=$manifest

[Install]
WantedBy=multi-user.target
EOF
  if as_root sh -c "install -m 0755 -o root -g root '$HERE/files/steamvr-setcap' '$SETCAP_HELPER' &&
                    install -m 0644 '$tmp/svc' /etc/systemd/system/$SETCAP_UNIT.service &&
                    install -m 0644 '$tmp/path' /etc/systemd/system/$SETCAP_UNIT.path &&
                    systemctl daemon-reload && systemctl enable --now $SETCAP_UNIT.path"; then
    ok "installed"
  else
    bad "$SETCAP_UNIT.path installation failed"
  fi
  rm -rf "$tmp"
}

install_service() {
  step "quest-cable service"
  if [ "$MODE" = check ]; then
    if systemctl --user is-enabled -q "$UNIT" 2>/dev/null; then
      ok "service enabled ($(systemctl --user is-active "$UNIT"))"
    else
      bad "service not installed/enabled"
    fi
    return 0
  fi
  [ -n "$ADB" ] || { bad "service not installed: adb is missing"; return 1; }
  mkdir -p "$BIN_DIR" "$UNIT_DIR"
  install -m 0755 "$HERE/files/quest-cable-daemon" "$BIN_DIR/quest-cable-daemon"
  install -m 0644 "$HERE/files/quest-cable.service" "$UNIT_DIR/$UNIT"
  {
    echo "# Written by steamlink-usb-bazzite/install.sh"
    echo "ADB=\"$ADB\""
    echo "HEADSET_IP=\"${HEADSET_IP:-10.86.13.37}\""
    echo "STEAM_DIR=\"$STEAM_DIR\""
    echo "# auto: block the Wi-Fi video only for an old vrlink without \"Uber link\" (yes/no to force)"
    echo "BLOCK_WIFI_VIDEO=\"auto\""
    echo "# yes: screen on and session kept active while the Quest is plugged in and awake"
    echo "KEEP_SCREEN_ON=\"yes\""
  } > "$CONF"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT" >/dev/null 2>&1
  systemctl --user restart "$UNIT"
  sleep 2
  if systemctl --user is-active -q "$UNIT"; then
    ok "service enabled and running (starts with every login, desktop or Gaming Mode)"
  else
    bad "service failed to start: journalctl --user -u $UNIT"
  fi
}

# ---------------------------------------------------------------------------------------------
uninstall() {
  step "Uninstalling"
  local ip
  ip=$(cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/quest-cable.blocked-ip" 2>/dev/null)
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 && ok "service stopped and disabled"
  [ -n "$ip" ] && [ -x "$HELPER" ] && sudo -n "$HELPER" off "$ip"
  rm -f "$UNIT_DIR/$UNIT" "$BIN_DIR/quest-cable-daemon" "$CONF"
  systemctl --user daemon-reload
  ok "user files removed"
  nmcli connection delete "$NM_CON" >/dev/null 2>&1 && ok "NetworkManager profile removed"
  if { [ -e "$HELPER" ] || [ -e "$SETCAP_HELPER" ] || [ -e "$UDEV_RULE" ]; } &&
     ask "Remove $HELPER, $SUDOERS, $SETCAP_UNIT.path and $UDEV_RULE (sudo)?"; then
    as_root sh -c "systemctl disable --now $SETCAP_UNIT.path 2>/dev/null
                   rm -f '$HELPER' '$SUDOERS' '$SETCAP_HELPER' /etc/systemd/system/$SETCAP_UNIT.path \
                         /etc/systemd/system/$SETCAP_UNIT.service '$UDEV_RULE'
                   systemctl daemon-reload; udevadm control --reload" && ok "root files removed"
  fi
  [ -L "$BIN_DIR/adb" ] && info "adb was left in place ($BIN_DIR/adb -> $PT_DIR)."
  local steam_dir lr
  for steam_dir in "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
    lr="$steam_dir/steamapps/common/LegacySteamRuntime"
    [ -L "$lr" ] && { info "LegacySteamRuntime link left in place ($lr): SteamVR needs it."; break; }
  done
  echo
  echo "Done."
}

# ---------------------------------------------------------------------------------------------
echo "${B}Steam Link VR over USB for Bazzite${N} ($MODE)"
[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (it asks for sudo when needed)"
[ "$MODE" = uninstall ] && { uninstall; exit 0; }

check_system
check_steam
check_steamvr
check_adb
check_udev
if check_quest; then
  check_quest_app
  check_usb_network
fi
setup_nm_profile
install_root_files
install_setcap_watch
install_service

step "Summary"
if (( ${#ISSUES[@]} == 0 )); then
  ok "everything ready"
  [ "$MODE" = install ] && cat <<EOF

  Plug the Quest in, open Steam Link in the headset and connect to this PC. A few seconds
  after the stream starts the service moves the video to the cable, and it falls back to
  Wi-Fi by itself if the cable stops answering. Nothing else to run.

  First connection: the headset shows a PIN; type it in the dialog Steam opens on this PC's
  screen (it is only asked once). Close any VR game started from the desktop before
  connecting.

  Logs:    journalctl --user -u $UNIT -f
  Pause:   systemctl --user stop $UNIT   (until the next login)
  Remove:  $0 --uninstall
EOF
  exit 0
fi
for i in "${ISSUES[@]}"; do echo "  ${R}✘${N} $i"; done
echo
echo "  Fix the items above and run the script again."
exit 1
