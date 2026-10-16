#!/usr/bin/env bash
# Steam Link VR over USB on Bazzite (Meta Quest).
#
# Checks every prerequisite, fixes what it can (always asking first) and installs the
# quest-cable user service, which moves the Steam Link video to the USB cable whenever it is
# available while the headset's Wi-Fi stays on.
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

# Root commands: sudo in a terminal, the graphical polkit prompt otherwise (e.g. started from a
# desktop shortcut).
as_root() { if [ -t 0 ]; then sudo "$@"; else pkexec "$@"; fi; }

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
    if steam_running; then
      info "closing Steam..."
      steam -shutdown >/dev/null 2>&1 &
      local i
      for i in $(seq 1 45); do steam_running || break; sleep 2; done
    fi
    if steam_running; then
      bad "Steam did not close; switch to the beta in the settings instead"
    else
      echo "$want" > "$STEAM_DIR/package/beta"
      ok "beta set ($want). Open Steam and let it update before using VR."
    fi
    return
  fi
  [ -n "$(cat "$STEAM_DIR/package/beta" 2>/dev/null)" ] || bad "Steam client is not on the beta"
}

# ---------------------------------------------------------------------------------------------
STEAMVR_DIR=""
check_steamvr() {
  step "SteamVR"
  local lib manifest=""
  while read -r lib; do
    if [ -f "$lib/steamapps/appmanifest_$STEAMVR_APPID.acf" ]; then
      manifest="$lib/steamapps/appmanifest_$STEAMVR_APPID.acf"
      STEAMVR_DIR="$lib/steamapps/common/SteamVR"
      break
    fi
  done < <( { echo "$STEAM_DIR"; grep -oP '"path"\s*"\K[^"]+' "$STEAM_DIR/steamapps/libraryfolders.vdf" 2>/dev/null; } | awk '!seen[$0]++')
  if [ -z "$manifest" ]; then
    bad "SteamVR is not installed"
    ask "Open the SteamVR install page in Steam?" && (steam "steam://install/$STEAMVR_APPID" >/dev/null 2>&1 &)
    info "Install SteamVR, start it once, then run this script again."
    return
  fi
  ok "SteamVR installed ($STEAMVR_DIR)"

  local key
  key=$(awk '/"UserConfig"/{u=1} u && /"BetaKey"/{gsub(/"/,"",$2); print $2; exit}' "$manifest")
  if [ "$key" = beta ]; then
    ok "SteamVR on the beta branch"
  else
    warn "SteamVR is on '${key:-default}', the tested setup uses the beta branch"
    info "Library > SteamVR > Properties > Betas > \"beta - SteamVR Beta Update\""
  fi

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
    if command -v brew >/dev/null && ask "Install it with Homebrew (brew install android-platform-tools)?"; then
      brew install android-platform-tools
    elif ask "Download Google's platform-tools into $PT_DIR?"; then
      install_adb_google || warn "download failed"
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
          info "Install the Android udev rules (rpm-ostree install android-udev-rules) and reboot." ;;
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
      warn "headset USB is in '$funcs' mode now (the service switches it to NCM when Steam Link is open)"
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
  if [ -e "$HELPER" ] && ask "Remove $HELPER and $SUDOERS (sudo)?"; then
    as_root rm -f "$HELPER" "$SUDOERS" && ok "root files removed"
  fi
  [ -L "$BIN_DIR/adb" ] && info "adb was left in place ($BIN_DIR/adb -> $PT_DIR)."
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
if check_quest; then
  check_quest_app
  check_usb_network
fi
setup_nm_profile
install_root_files
install_service

step "Summary"
if (( ${#ISSUES[@]} == 0 )); then
  ok "everything ready"
  [ "$MODE" = install ] && cat <<EOF

  Plug the Quest in, open Steam Link in the headset and connect to this PC. A few seconds
  after the stream starts the service moves the video to the cable, and it falls back to
  Wi-Fi by itself if the cable stops answering. Nothing else to run.

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
