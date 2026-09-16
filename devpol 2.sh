#!/bin/bash
# devpol.sh — standalone ChromeOS policy editor (devmode, no Modmium)
# Usage (VT2, logged in as root):
#   bash <(curl -SLk https://raw.githubusercontent.com/nmsjayden/ModPol/refs/heads/main/devpol.sh)

# ── paths ─────────────────────────────────────────────────────────────────────
INSTALL_DIR="/usr/share/.policy-test-tool"
JSON_FILE="$INSTALL_DIR/dump.json"
USER_POL_FILE="$INSTALL_DIR/user_policies.json"
DM_SERVER_SCRIPT="$INSTALL_DIR/dm_server.py"
DM_PID_FILE="/mnt/stateful_partition/.devpol_dm.pid"
DM_PORT_FILE="/mnt/stateful_partition/.devpol_dm.port"
DM_FIXED_PORT=19876          # fixed port — never changes between restarts
DM_LOG_FILE="/tmp/devpol_dm.log"
DEVINSTALL_STAMP="/mnt/stateful_partition/.devpol_devinstall"
SETUP_STAMP="/mnt/stateful_partition/.devpol_setup"
DEVSET_DIR="/var/lib/devicesettings"
CHROME_CONF="/etc/chrome_dev.conf"
CHROME_CONF_BAK="/etc/chrome_dev.conf.devpol.bak"
RAW="https://raw.githubusercontent.com/CrOSmium/modmium/stable/mod-files/usr/share/.policy-test-tool"

# ── colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
B='\033[0;34m' P='\033[0;35m' D='\033[2m' N='\033[0m'

# ── save terminal state BEFORE any stty changes ───────────────────────────────
ORIG_STTY=$(stty -g 2>/dev/null)

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo -e "\n${R}error: $*${N}" >&2; sleep 2; exit 1; }
info() { echo -e "${B}$*${N}"; }
ok()   { echo -e "${G}$*${N}"; }
warn() { echo -e "${Y}$*${N}"; }

allow_input() {
  if [[ -n "$ORIG_STTY" ]]; then
    stty "$ORIG_STTY" 2>/dev/null
  else
    stty sane 2>/dev/null
  fi
  tput cnorm
}
disallow_input() { stty -echo; tput civis; }

restart_ui() {
  initctl restart ui 2>/dev/null || restart ui 2>/dev/null \
    || warn "could not restart UI — reboot manually"
}

# ── preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]        && die "run this as root"
[[ ! -d "$DEVSET_DIR" ]] && die "$DEVSET_DIR not found — is this a managed ChromeOS device?"
command -v python3 &>/dev/null || command -v python &>/dev/null || die "python not found"
PYTHON=$(command -v python3 || command -v python)

# ── source sub-scripts ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=devpol_setup.sh
source "$SCRIPT_DIR/devpol_setup.sh"
# shellcheck source=devpol_policy.sh
source "$SCRIPT_DIR/devpol_policy.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TUI
# ═══════════════════════════════════════════════════════════════════════════════

# ── device policy submenu ─────────────────────────────────────────────────────
DEV_MENU=(
  "1)  Dump current policy to JSON"
  "2)  Quick toggle"
  "3)  Full editor (nano)"
  "4)  Show current values"
  "5)  Apply"
  "6)  Revert to original"
  "7)  Back"
)

run_dev_tui() {
  local sel=0 n=${#DEV_MENU[@]}; clear
  while true; do
    tput cup 0 0
    echo -e "${P}┌───────────────────────────────────────────────┐${N}"
    echo -e "${P}│          Device Policy Editor                 │${N}"
    echo -e "${P}└───────────────────────────────────────────────┘${N}"
    echo ""
    for i in "${!DEV_MENU[@]}"; do
      [[ $i -eq $sel ]] && echo -e "    \e[7m ${DEV_MENU[$i]} \e[0m" \
                        || echo -e "      ${DEV_MENU[$i]}"
    done
    echo ""
    if [[ -f "$JSON_FILE" ]]; then echo -e "    ${D}dump: $JSON_FILE${N}"
    else echo -e "    ${Y}no dump yet — start with option 1${N}"; fi
    tput ed
    read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 -t 0.05 seq; while read -rsn1 -t 0.01 _; do :; done
      case "$seq" in '[A') sel=$(( (sel-1+n)%n ));; '[B') sel=$(( (sel+1)%n ));; esac
    elif [[ "$key" =~ ^[1-7]$ ]]; then sel=$(( key-1 ))
    elif [[ "$key" == "" ]]; then
      case $sel in
        0) clear; do_dump;    allow_input; echo -e "\n${D}Press Enter...${N}"; read -r; disallow_input ;;
        1) clear; do_dev_quick ;;
        2) do_dev_edit ;;
        3) do_dev_show ;;
        4) clear; do_apply;   allow_input; echo -e "\n${D}Press Enter...${N}"; read -r; disallow_input ;;
        5) clear
           warn "Restores original policy files and chrome_dev.conf, then restarts UI."
           echo -ne "${D}Are you sure? [y/N]: ${N}"
           allow_input; read -re yn; disallow_input
           [[ "$yn" == "y" || "$yn" == "Y" ]] && { clear; do_revert; sleep 2; } ;;
        6) return ;;
      esac; clear
    fi
  done
}

# ── local account (user) policy submenu ──────────────────────────────────────
LOCAL_MENU=(
  "1)  Import from chrome://policy export"
  "2)  Quick toggle"
  "3)  Full editor (nano)"
  "4)  Show current policies"
  "5)  Start / restart DM server + apply"
  "6)  Stop DM server"
  "7)  Back"
)

run_local_tui() {
  # Always start with account selection so the user picks which account
  # they are editing before any action is taken.
  select_account || return
  clear

  local sel=0 n=${#LOCAL_MENU[@]}
  while true; do
    local upf; upf=$(account_pol_file)
    tput cup 0 0
    echo -e "${P}┌───────────────────────────────────────────────┐${N}"
    echo -e "${P}│        Local Account Policy Editor            │${N}"
    echo -e "${P}│  Runs a DM server Chrome fetches from         │${N}"
    echo -e "${P}└───────────────────────────────────────────────┘${N}"
    echo ""
    for i in "${!LOCAL_MENU[@]}"; do
      [[ $i -eq $sel ]] && echo -e "    \e[7m ${LOCAL_MENU[$i]} \e[0m" \
                        || echo -e "      ${LOCAL_MENU[$i]}"
    done
    echo ""
    if dm_server_running; then
      echo -e "    ${G}● DM server running  port=$(dm_server_port)${N}"
    else
      echo -e "    ${D}○ DM server not running${N}"
    fi
    echo -e "    ${B}Account: ${CURRENT_ACCOUNT:-default}${N}"
    if [[ -f "$upf" ]]; then
      local count; count=$($PYTHON -c "import json;d=json.load(open('$upf'));print(len(d))" 2>/dev/null || echo "?")
      echo -e "    ${D}$upf  ($count policies set)${N}"
    else
      echo -e "    ${D}no policy file yet${N}"
    fi
    tput ed
    read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 -t 0.05 seq; while read -rsn1 -t 0.01 _; do :; done
      case "$seq" in '[A') sel=$(( (sel-1+n)%n ));; '[B') sel=$(( (sel+1)%n ));; esac
    elif [[ "$key" =~ ^[1-7]$ ]]; then sel=$(( key-1 ))
    elif [[ "$key" == "" ]]; then
      case $sel in
        0) do_local_import ;;
        1) clear; do_local_quick ;;
        2) do_local_edit ;;
        3) do_local_show ;;
        4) clear
           local upf2; upf2=$(account_pol_file)
           info "Validating $upf2 ..."
           $PYTHON -c "import json; json.load(open('$upf2'))" 2>/dev/null \
             || { warn "Invalid JSON — fix it first."; allow_input; echo -e "${D}Press Enter...${N}"; read -r; disallow_input; clear; continue; }
           start_dm_server
           allow_input; echo -e "\n${D}Press Enter...${N}"; read -r; disallow_input ;;
        5) clear
           warn "This stops the DM server and removes the DM URL from chrome_dev.conf."
           echo -ne "${D}Are you sure? [y/N]: ${N}"
           allow_input; read -re yn; disallow_input
           [[ "$yn" == "y" || "$yn" == "Y" ]] && { clear; stop_dm_server; sleep 2; } ;;
        6) return ;;
      esac; clear
    fi
  done
}

# ── top-level menu ────────────────────────────────────────────────────────────
TOP_MENU=(
  "1)  Device policy editor"
  "2)  Local account (user) policy editor"
  "3)  Exit"
)

run_tui() {
  disallow_input
  local sel=0 n=${#TOP_MENU[@]}; clear
  while true; do
    tput cup 0 0
    echo -e "${P}┌───────────────────────────────────────────────┐${N}"
    echo -e "${P}│       devpol — ChromeOS policy editor         │${N}"
    echo -e "${P}│     arrows / numbers  •  Enter to select      │${N}"
    echo -e "${P}└───────────────────────────────────────────────┘${N}"
    echo ""
    for i in "${!TOP_MENU[@]}"; do
      [[ $i -eq $sel ]] && echo -e "    \e[7m ${TOP_MENU[$i]} \e[0m" \
                        || echo -e "      ${TOP_MENU[$i]}"
    done
    tput ed
    read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 -t 0.05 seq; while read -rsn1 -t 0.01 _; do :; done
      case "$seq" in '[A') sel=$(( (sel-1+n)%n ));; '[B') sel=$(( (sel+1)%n ));; esac
    elif [[ "$key" =~ ^[1-3]$ ]]; then sel=$(( key-1 ))
    elif [[ "$key" == "" ]]; then
      case $sel in
        0) run_dev_tui;   clear ;;
        1) run_local_tui; clear ;;
        2) allow_input; tput cnorm; echo -e "${G}Goodbye.${N}"; exit 0 ;;
      esac
    fi
  done
}

# ── entry ─────────────────────────────────────────────────────────────────────
clear
echo -e "${P}devpol — standalone ChromeOS policy editor${N}"
echo -e "${D}no Modmium required  •  developer mode + root only${N}"
echo ""
setup
# Always regenerate dm_server.py so any edits to this script take effect
# immediately without needing to wipe the setup stamp.
generate_dm_server
run_tui
