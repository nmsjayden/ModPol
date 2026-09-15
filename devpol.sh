#!/bin/bash
# devpol.sh — standalone ChromeOS device policy editor (devmode, no Modmium)
# Usage (VT2, logged in as root):
#   bash <(curl -SLk https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/devpol.sh)

# ── paths ─────────────────────────────────────────────────────────────────────
INSTALL_DIR="/usr/local/share/devpol"
JSON_FILE="$INSTALL_DIR/dump.json"
DEVINSTALL_STAMP="/mnt/stateful_partition/.devpol_devinstall"
SETUP_STAMP="/mnt/stateful_partition/.devpol_setup"
DEVSET_DIR="/var/lib/devicesettings"
CHROME_CONF="/etc/chrome_dev.conf"
CHROME_CONF_BAK="/etc/chrome_dev.conf.devpol.bak"
RAW="https://raw.githubusercontent.com/CrOSmium/modmium/stable/mod-files/usr/share/.policy-test-tool"

# ── colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
B='\033[0;34m' P='\033[0;35m' D='\033[2m' N='\033[0m'

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo -e "\n${R}error: $*${N}" >&2; sleep 2; exit 1; }
info() { echo -e "${B}$*${N}"; }
ok()   { echo -e "${G}$*${N}"; }
warn() { echo -e "${Y}$*${N}"; }

allow_input()    { stty echo;  tput cnorm; }
disallow_input() { stty -echo; tput civis; }

restart_ui() {
  initctl restart ui 2>/dev/null || restart ui 2>/dev/null \
    || warn "could not restart UI automatically — reboot manually"
}

# ── preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]                      && die "run this as root"
[[ ! -d "$DEVSET_DIR" ]]               && die "$DEVSET_DIR not found — is this a managed ChromeOS device?"
command -v python3 &>/dev/null || command -v python &>/dev/null \
                                       || die "python not found"
PYTHON=$(command -v python3 || command -v python)

# ── find the latest policy blob ───────────────────────────────────────────────
latest_policy() {
  ls "$DEVSET_DIR"/policy.* 2>/dev/null \
    | grep -E 'policy\.[0-9]+$' \
    | sort -t. -k2 -V \
    | tail -n1
}

# ── rootfs write access ───────────────────────────────────────────────────────
#
# /etc is on the read-only rootfs. To write chrome_dev.conf we need to:
#   1. Remove rootfs verification from both kernel partitions (make_dev_ssd.sh)
#   2. Reboot so the unsigned kernels load
#   3. On next run, remount rw and continue
#
# make_dev_ssd.sh targets the *kernel* partitions (2 and 4), not the rootfs
# partitions (3 and 5). Doing both covers whichever slot ChromeOS boots from.
#
detect_disk() {
  for dev in /dev/mmcblk0 /dev/nvme0n1 /dev/sda /dev/mmcblk1; do
    [[ -b "$dev" ]] && echo "$dev" && return
  done
}

ensure_rootfs_writable() {
  # quick check: can we write to the rootfs right now?
  if touch /.__devpol_rw_test 2>/dev/null; then
    rm -f /.__devpol_rw_test
    return 0
  fi

  # rootfs is still read-only — need to strip verification and reboot
  warn "Rootfs is read-only. Removing rootfs verification so we can patch chrome_dev.conf."
  echo ""

  local disk
  disk=$(detect_disk)
  [[ -z "$disk" ]] && die "could not detect main disk (tried mmcblk0, nvme0n1, sda)"
  info "Detected disk: $disk"

  /usr/share/vboot/bin/make_dev_ssd.sh -i "$disk" --remove_rootfs_verification --partitions 2 \
    || die "make_dev_ssd.sh failed on partition 2"
  /usr/share/vboot/bin/make_dev_ssd.sh -i "$disk" --remove_rootfs_verification --partitions 4 \
    || die "make_dev_ssd.sh failed on partition 4"

  echo ""
  ok "Rootfs verification removed from both kernel partitions."
  warn "A reboot is required. Run this script again after rebooting."
  echo ""
  echo -ne "${D}Reboot now? [Y/n]: ${N}"
  read -r yn
  [[ "$yn" == "n" || "$yn" == "N" ]] && { warn "Reboot manually when ready."; exit 0; }
  reboot
  exit 0
}

# ── chrome_dev.conf setup ─────────────────────────────────────────────────────
#
# devpol.py re-signs the policy blob with a fresh RSA keypair. Chrome will
# silently reject it unless --disable-policy-key-verification is set.
#
setup_chrome_conf() {
  if grep -q 'disable-policy-key-verification' "$CHROME_CONF" 2>/dev/null; then
    return 0  # already set
  fi

  ensure_rootfs_writable

  info "Remounting rootfs as writable..."
  mount -o remount,rw / \
    || die "remount failed even after rootfs verification was removed — try rebooting again"

  if [[ -f "$CHROME_CONF" && ! -f "$CHROME_CONF_BAK" ]]; then
    cp "$CHROME_CONF" "$CHROME_CONF_BAK"
    info "Backed up $CHROME_CONF → $CHROME_CONF_BAK"
  fi

  echo '--disable-policy-key-verification' >> "$CHROME_CONF"
  ok "Added --disable-policy-key-verification to $CHROME_CONF"

  warn "Restarting UI so Chrome picks up the new flag..."
  warn "(screen will flicker — come back with Ctrl+Alt+F2)"
  sleep 2
  restart_ui
  sleep 4
}

# ── install dependencies ──────────────────────────────────────────────────────
install_deps() {
  if [[ ! -f "$DEVINSTALL_STAMP" ]]; then
    info "Running dev_install to bootstrap emerge (takes a minute)..."
    printf 'y\nn\n' | dev_install --reinstall \
      || die "dev_install failed — connect to the internet first"
    touch "$DEVINSTALL_STAMP"
  fi

  ldconfig 2>/dev/null

  info "Emerging required packages..."
  emerge protobuf-python cryptography pyyaml nano \
    || die "emerge failed — check your internet connection"
}

# ── download python files ─────────────────────────────────────────────────────
download_files() {
  info "Downloading policy tool files from modmium stable branch..."
  mkdir -p "$INSTALL_DIR"

  local files=(
    devpol.py
    blob_generator.py
    chrome_device_policy_pb2.py
    device_management_backend_pb2.py
    policy_common_definitions_pb2.py
    manual_device_policy_proto_map.yaml
  )

  for f in "${files[@]}"; do
    curl -fSLk "$RAW/$f" -o "$INSTALL_DIR/$f" \
      || die "failed to download $f — check your internet connection"
    ok "  ✓ $f"
  done
}

# ── first-run setup ───────────────────────────────────────────────────────────
setup() {
  # check files are all present if stamp exists
  if [[ -f "$SETUP_STAMP" ]]; then
    local all_present=1
    for f in devpol.py blob_generator.py chrome_device_policy_pb2.py \
              device_management_backend_pb2.py policy_common_definitions_pb2.py \
              manual_device_policy_proto_map.yaml; do
      [[ ! -f "$INSTALL_DIR/$f" ]] && all_present=0 && break
    done
    if [[ $all_present -eq 1 ]]; then
      setup_chrome_conf
      return
    fi
    warn "Some files missing — re-running setup..."
  fi

  echo ""
  info "=== First-run setup ==="
  setup_chrome_conf
  install_deps
  download_files
  touch "$SETUP_STAMP"
  echo ""
  ok "Setup complete."
  sleep 1
}

# ── dump ──────────────────────────────────────────────────────────────────────
do_dump() {
  local pol
  pol=$(latest_policy)
  [[ -z "$pol" ]] && die "no policy blob found in $DEVSET_DIR"
  info "Reading $pol ..."
  cd "$INSTALL_DIR" || die "cannot cd to $INSTALL_DIR"
  ldconfig 2>/dev/null
  $PYTHON devpol.py --dump --input "$pol" --output "$JSON_FILE" \
    || die "dump failed"
  ok "Dumped to $JSON_FILE"
}

# ── apply ─────────────────────────────────────────────────────────────────────
do_apply() {
  [[ ! -f "$JSON_FILE" ]] && die "no dump.json — run Dump first"

  info "Validating JSON..."
  $PYTHON -c "import json; json.load(open('$JSON_FILE'))" \
    || die "dump.json has invalid JSON — fix it before applying"

  info "Applying policies and restarting UI..."
  cd "$INSTALL_DIR" || die "cannot cd to $INSTALL_DIR"
  ldconfig 2>/dev/null
  $PYTHON devpol.py "$JSON_FILE" \
    || die "apply failed"
  ok "Done — policies applied."
  warn "(come back to VT2 with Ctrl+Alt+F2 after UI restarts)"
}

# ── revert ────────────────────────────────────────────────────────────────────
do_revert() {
  local reverted=0
  pushd "$DEVSET_DIR" > /dev/null || die "cannot access $DEVSET_DIR"

  if [[ -f owner.key.bak.enterprise ]]; then
    mv owner.key.bak.enterprise owner.key && reverted=1
    ok "  restored owner.key"
  fi

  local bak
  bak=$(ls policy.*.bak.enterprise 2>/dev/null | sort -V | tail -n1)
  if [[ -n "$bak" ]]; then
    mv "$bak" "${bak%.bak.enterprise}" && reverted=1
    ok "  restored ${bak%.bak.enterprise}"
  fi

  popd > /dev/null

  # restore chrome_dev.conf
  if [[ -f "$CHROME_CONF_BAK" ]]; then
    mount -o remount,rw / 2>/dev/null
    cp "$CHROME_CONF_BAK" "$CHROME_CONF"
    rm "$CHROME_CONF_BAK"
    ok "  restored $CHROME_CONF"
  fi

  if [[ $reverted -eq 1 ]]; then
    rm -f "$JSON_FILE"
    ok "Revert complete. Restarting UI..."
    sleep 1; restart_ui
  else
    warn "No backup files found — nothing to revert."
    warn "devpol only creates backups on the first apply."
  fi
}

# ── edit ──────────────────────────────────────────────────────────────────────
do_edit() {
  [[ ! -f "$JSON_FILE" ]] && die "no dump.json — run Dump first"
  local ed
  ed=$(command -v nano || command -v vi || command -v vim)
  [[ -z "$ed" ]] && die "no editor found"
  allow_input
  "$ed" "$JSON_FILE"
  disallow_input
}

# ── show ──────────────────────────────────────────────────────────────────────
do_show() {
  [[ ! -f "$JSON_FILE" ]] && { warn "No dump yet."; sleep 1; return; }
  allow_input
  echo -e "\n${P}── device policies in dump.json ─────────────────────────${N}\n"
  if command -v jq &>/dev/null; then
    jq '.device' "$JSON_FILE"
  else
    $PYTHON -c "
import json
d = json.load(open('$JSON_FILE'))
for k, v in sorted(d.get('device', {}).items()):
    print(f'  {k}: {v}')
"
  fi
  echo -e "\n${D}Press Enter to continue...${N}"
  read -r
  disallow_input
}

# ── quick toggle ──────────────────────────────────────────────────────────────
QUICK_KEYS=(
  DeviceAllowNewUsers
  DeviceGuestModeEnabled
  DeviceUnaffiliatedCrostiniAllowed
  VirtualMachinesAllowed
  UnaffiliatedArcAllowed
  DeviceBorealisAllowed
  DeviceWiFiAllowed
  DeviceBlockDevmode
  DevicePowerwashAllowed
  DeviceUserInitiatedFirmwareUpdatesEnabled
)

do_quick() {
  [[ ! -f "$JSON_FILE" ]] && die "no dump.json — run Dump first"
  allow_input
  clear

  while true; do
    echo -e "${P}── quick toggle ──────────────────────────────────────────────${N}"
    echo -e "${D}number to toggle  |  q to go back${N}\n"
    local i=1
    for k in "${QUICK_KEYS[@]}"; do
      local val
      val=$($PYTHON -c "
import json
d = json.load(open('$JSON_FILE'))
v = d.get('device', {}).get('$k', None)
print('not set' if v is None else str(v).lower())
" 2>/dev/null)
      local colour="$D"
      [[ "$val" == "true"  ]] && colour="$G"
      [[ "$val" == "false" ]] && colour="$R"
      printf "  ${B}%2d)${N}  %-46s ${colour}%s${N}\n" "$i" "$k" "$val"
      ((i++))
    done

    echo ""
    echo -ne "${D}> ${N}"
    read -r choice

    [[ "$choice" == "q" || "$choice" == "Q" ]] && break

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#QUICK_KEYS[@]} )); then
      local key="${QUICK_KEYS[$((choice-1))]}"
      local cur
      cur=$($PYTHON -c "
import json
d = json.load(open('$JSON_FILE'))
v = d.get('device', {}).get('$key', None)
print('none' if v is None else str(v).lower())
" 2>/dev/null)
      local new="true"
      [[ "$cur" == "true" ]] && new="false"
      $PYTHON -c "
import json
with open('$JSON_FILE') as f:
    d = json.load(f)
d.setdefault('device', {})['$key'] = '$new' == 'true'
with open('$JSON_FILE', 'w') as f:
    json.dump(d, f, indent=2)
" && ok "  $key → $new"
      sleep 0.5
    else
      warn "  invalid"
      sleep 0.5
    fi
    clear
  done
  disallow_input
}

# ── TUI ───────────────────────────────────────────────────────────────────────
MENU=(
  "1)  Dump current policy to JSON"
  "2)  Quick toggle  (common on/off policies)"
  "3)  Full editor   (nano on raw JSON)"
  "4)  Show current values"
  "5)  Apply"
  "6)  Revert to original"
  "7)  Exit"
)
SEL=0
N_MENU=${#MENU[@]}

draw_menu() {
  tput cup 0 0
  echo -e "${P}┌───────────────────────────────────────────────┐${N}"
  echo -e "${P}│     devpol — ChromeOS device policy editor    │${N}"
  echo -e "${P}│       arrows / numbers  •  Enter to select    │${N}"
  echo -e "${P}└───────────────────────────────────────────────┘${N}"
  echo ""
  for i in "${!MENU[@]}"; do
    if [[ $i -eq $SEL ]]; then
      echo -e "    \e[7m ${MENU[$i]} \e[0m"
    else
      echo -e "      ${MENU[$i]}"
    fi
  done
  echo ""
  if [[ -f "$JSON_FILE" ]]; then
    echo -e "    ${D}dump: $JSON_FILE${N}"
  else
    echo -e "    ${Y}no dump yet — start with option 1${N}"
  fi
  tput ed
}

run_tui() {
  disallow_input
  clear
  while true; do
    draw_menu
    read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 -t 0.05 seq
      while read -rsn1 -t 0.01 _; do :; done
      case "$seq" in
        '[A') SEL=$(( (SEL - 1 + N_MENU) % N_MENU )) ;;
        '[B') SEL=$(( (SEL + 1) % N_MENU )) ;;
      esac
    elif [[ "$key" =~ ^[1-7]$ ]]; then
      SEL=$(( key - 1 ))
    elif [[ "$key" == "" ]]; then
      case $SEL in
        0) clear; do_dump;  echo -e "\n${D}Press Enter...${N}"; read -r ;;
        1) clear; do_quick ;;
        2) do_edit ;;
        3) do_show ;;
        4) clear; do_apply; echo -e "\n${D}Press Enter...${N}"; read -r ;;
        5) clear
           warn "This restores the original policy files and chrome_dev.conf, then restarts the UI."
           echo -ne "${D}Are you sure? [y/N]: ${N}"
           allow_input; read -r yn; disallow_input
           [[ "$yn" == "y" || "$yn" == "Y" ]] && { clear; do_revert; sleep 2; }
           ;;
        6) allow_input; tput cnorm; echo -e "${G}Goodbye.${N}"; exit 0 ;;
      esac
      clear
    fi
  done
}

# ── entry ─────────────────────────────────────────────────────────────────────
clear
echo -e "${P}devpol — standalone ChromeOS device policy editor${N}"
echo -e "${D}no Modmium required  •  developer mode + root only${N}"
echo ""
setup
run_tui
