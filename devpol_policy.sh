#!/bin/bash
# devpol_policy.sh — policy operations for devpol
# Sourced by devpol.sh. Requires all variables and helpers defined in
# devpol.sh, and the setup helpers from devpol_setup.sh.

# ═══════════════════════════════════════════════════════════════════════════════
# DEVICE POLICY
# ═══════════════════════════════════════════════════════════════════════════════

do_dump() {
  local pol; pol=$(latest_policy)
  [[ -z "$pol" ]] && die "no policy blob found in $DEVSET_DIR"
  info "Reading $pol ..."
  cd "$INSTALL_DIR" || die "cannot cd to $INSTALL_DIR"
  ldconfig 2>/dev/null
  $PYTHON devpol.py --dump --input "$pol" --output "$JSON_FILE" || die "dump failed"
  ok "Dumped to $JSON_FILE"
}

do_apply() {
  [[ ! -f "$JSON_FILE" ]] && die "no dump.json — run Dump first"
  info "Validating JSON..."
  $PYTHON -c "import json; json.load(open('$JSON_FILE'))" \
    || die "dump.json has invalid JSON"

  # Write the policy blob first, then patch chrome_dev.conf, then restart once.
  # (Old design patched conf first which triggered a premature UI restart before
  # the blob was written, requiring the user to run Apply a second time.)
  info "Applying policies..."
  cd "$INSTALL_DIR" || die "cannot cd to $INSTALL_DIR"
  ldconfig 2>/dev/null
  $PYTHON devpol.py "$JSON_FILE" || die "apply failed"
  ok "Policy blob written."

  setup_chrome_conf   # idempotent — only writes if flags missing

  warn "Restarting UI to apply policies..."
  warn "(come back with Ctrl+Alt+F2)"
  sleep 2; restart_ui; sleep 4
}

do_revert() {
  local reverted=0
  pushd "$DEVSET_DIR" > /dev/null || die "cannot access $DEVSET_DIR"
  if [[ -f owner.key.bak.enterprise ]]; then
    mv owner.key.bak.enterprise owner.key && reverted=1
    ok "  restored owner.key"
  fi
  local bak; bak=$(ls policy.*.bak.enterprise 2>/dev/null | sort -V | tail -n1)
  if [[ -n "$bak" ]]; then
    mv "$bak" "${bak%.bak.enterprise}" && reverted=1
    ok "  restored ${bak%.bak.enterprise}"
  fi
  popd > /dev/null
  if [[ -f "$CHROME_CONF_BAK" ]]; then
    remount_rootfs_rw
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
  fi
}

do_dev_edit() {
  [[ ! -f "$JSON_FILE" ]] && die "no dump.json — run Dump first"
  local ed; ed=$(command -v nano || command -v vi || command -v vim)
  [[ -z "$ed" ]] && die "no editor found"
  allow_input; "$ed" "$JSON_FILE"; disallow_input
}

do_dev_show() {
  [[ ! -f "$JSON_FILE" ]] && { warn "No dump yet."; sleep 1; return; }
  allow_input
  echo -e "\n${P}── device policies ──────────────────────────────────────${N}\n"
  $PYTHON -c "
import json
d = json.load(open('$JSON_FILE'))
for k, v in sorted(d.get('device', {}).items()):
    print(f'  {k}: {v}')
"
  echo -e "\n${D}Press Enter...${N}"; read -r; disallow_input
}

DEV_QUICK_KEYS=(
  DeviceAllowNewUsers DeviceGuestModeEnabled
  DeviceUnaffiliatedCrostiniAllowed VirtualMachinesAllowed
  UnaffiliatedArcAllowed DeviceBorealisAllowed
  DeviceWiFiAllowed DeviceBlockDevmode
  DevicePowerwashAllowed DeviceUserInitiatedFirmwareUpdatesEnabled
)

do_dev_quick() {
  [[ ! -f "$JSON_FILE" ]] && die "no dump.json — run Dump first"
  allow_input; clear
  while true; do
    echo -e "${P}── device quick toggle ───────────────────────────────────────${N}"
    echo -e "${D}number to toggle  |  q to go back${N}\n"
    local i=1
    for k in "${DEV_QUICK_KEYS[@]}"; do
      local val
      val=$($PYTHON -c "
import json; d=json.load(open('$JSON_FILE'))
v=d.get('device',{}).get('$k',None)
print('not set' if v is None else str(v).lower())
" 2>/dev/null)
      local colour="$D"
      [[ "$val" == "true"  ]] && colour="$G"
      [[ "$val" == "false" ]] && colour="$R"
      printf "  ${B}%2d)${N}  %-46s ${colour}%s${N}\n" "$i" "$k" "$val"
      ((i++))
    done
    echo ""; echo -ne "${D}> ${N}"; read -re choice
    [[ "$choice" == "q" || "$choice" == "Q" ]] && break
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DEV_QUICK_KEYS[@]} )); then
      local key="${DEV_QUICK_KEYS[$((choice-1))]}"
      local cur
      cur=$($PYTHON -c "
import json; d=json.load(open('$JSON_FILE'))
print(str(d.get('device',{}).get('$key',None)).lower())
" 2>/dev/null)
      local new="true"; [[ "$cur" == "true" ]] && new="false"
      $PYTHON -c "
import json
with open('$JSON_FILE') as f: d=json.load(f)
d.setdefault('device',{})['$key']='$new'=='true'
with open('$JSON_FILE','w') as f: json.dump(d,f,indent=2)
" && ok "  $key → $new"
      sleep 0.5
    else
      warn "  invalid"; sleep 0.5
    fi
    clear
  done
  disallow_input
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOCAL ACCOUNT (USER) POLICY — Python DM server approach
#
# Chrome (v129+) no longer reads /etc/opt/chrome/policies/managed/.
# Instead, we run a minimal Python HTTP server that speaks just enough of
# the DM protocol for Chrome to fetch user policies from it. We redirect
# Chrome to it via --device-management-url in chrome_dev.conf.
#
# The server stays running in the background (PID in DM_PID_FILE) while
# the user is active. Chrome re-fetches every ~3h or on sign-in.
# ═══════════════════════════════════════════════════════════════════════════════

dm_server_running() {
  [[ -f "$DM_PID_FILE" ]] || return 1
  local pid; pid=$(cat "$DM_PID_FILE" 2>/dev/null)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

dm_server_port() {
  cat "$DM_PORT_FILE" 2>/dev/null || echo "?"
}

start_dm_server() {
  # Kill any existing instance
  if dm_server_running; then
    kill "$(cat "$DM_PID_FILE")" 2>/dev/null
    sleep 1
  fi
  rm -f "$DM_PID_FILE" "$DM_PORT_FILE"

  [[ ! -f "$USER_POL_FILE" ]] && echo '{}' > "$USER_POL_FILE"

  info "Starting DM server on fixed port $DM_FIXED_PORT..."
  cd "$INSTALL_DIR" || die "cannot cd to $INSTALL_DIR"
  ldconfig 2>/dev/null

  # nohup + disown: detach from the VT2 session so the daemon survives
  # restart_ui (which cycles VT2 and would otherwise send SIGHUP).
  local tmpout="/tmp/.devpol_dm_out_$$"
  nohup $PYTHON dm_server.py "$DM_FIXED_PORT" >"$tmpout" 2>&1 &
  local srv_pid=$!
  disown "$srv_pid"
  echo "$srv_pid" > "$DM_PID_FILE"

  # Poll for READY:<port> line (up to 10 s, check every 200 ms).
  local ready="" i=0
  while (( i < 50 )); do
    sleep 0.2
    kill -0 "$srv_pid" 2>/dev/null || break
    ready=$(grep -m1 '^READY:' "$tmpout" 2>/dev/null)
    [[ -n "$ready" ]] && break
    ((i++))
  done

  if [[ "$ready" != READY:* ]]; then
    warn "DM server did not start. Output:"
    while IFS= read -r line; do warn "  $line"; done < "$tmpout"
    rm -f "$tmpout" "$DM_PID_FILE"; return 1
  fi
  rm -f "$tmpout"

  echo "$DM_FIXED_PORT" > "$DM_PORT_FILE"
  ok "DM server running on port $DM_FIXED_PORT (PID $srv_pid)"

  # Ensure --disable-policy-key-verification, --policy-fetch-timeout=1, and
  # enrollment-blocking flags are all present before touching the DM URL.
  setup_chrome_conf

  # Snapshot whether the DM block already existed BEFORE we rewrite it.
  # If it was already there Chrome already knows our server address (same
  # fixed port) — a UI restart is not needed.
  local dm_was_set=0
  grep -q "^$DM_CONF_START" "$CHROME_CONF" 2>/dev/null && dm_was_set=1

  add_dm_url "$DM_FIXED_PORT"
  ok "chrome_dev.conf updated with --device-management-url"

  if [[ $dm_was_set -eq 0 ]]; then
    warn "Restarting UI so Chrome picks up the new DM server..."
    warn "(come back with Ctrl+Alt+F2)"
    sleep 2; restart_ui; sleep 4
  else
    ok "DM server restarted — Chrome already points here, no UI restart needed."
    ok "Reload policies in chrome://policy (or sign out and back in)."
  fi
}

stop_dm_server() {
  if dm_server_running; then
    kill "$(cat "$DM_PID_FILE")" 2>/dev/null
    ok "DM server stopped."
  else
    warn "DM server is not running."
  fi
  rm -f "$DM_PID_FILE" "$DM_PORT_FILE"
  remove_dm_url
  ok "Removed DM URL from chrome_dev.conf."
  warn "Restarting UI..."
  sleep 1; restart_ui
}

# ── per-account policy file helpers ──────────────────────────────────────────
CURRENT_ACCOUNT=""

account_pol_file() {
  local email="${1:-$CURRENT_ACCOUNT}"
  if [[ -n "$email" ]]; then
    echo "$INSTALL_DIR/user_policies_${email}.json"
  else
    echo "$USER_POL_FILE"
  fi
}

list_accounts() {
  for f in "$INSTALL_DIR"/user_policies_*.json; do
    [[ -f "$f" ]] || continue
    local name="${f##*/user_policies_}"
    name="${name%.json}"
    echo "$name"
  done
}

select_account() {
  allow_input
  while true; do
    clear
    echo -e "${P}── Select account ────────────────────────────────────────────${N}"
    echo -e "${D}number to select  |  d<N> to delete  |  n to add  |  q to cancel${N}\n"

    local accounts=()
    while IFS= read -r a; do accounts+=("$a"); done < <(list_accounts)

    local i=1
    for a in "${accounts[@]}"; do
      echo -e "  ${B}$i)${N}  $a"
      ((i++))
    done
    [[ ${#accounts[@]} -gt 0 ]] && echo ""
    echo -e "  ${B}n)${N}  Add new account email"
    echo -e "  ${B}q)${N}  Cancel"
    echo ""
    echo -ne "${D}> ${N}"
    read -re choice

    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
      disallow_input; return 1

    elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
      echo -ne "${D}Email: ${N}"
      read -re email
      [[ -z "$email" ]] && continue
      CURRENT_ACCOUNT="$email"
      local f; f=$(account_pol_file "$email")
      [[ ! -f "$f" ]] && echo '{}' > "$f"
      disallow_input; return 0

    elif [[ "$choice" =~ ^[dD]([0-9]+)$ ]]; then
      local idx="${BASH_REMATCH[1]}"
      if (( idx >= 1 && idx <= ${#accounts[@]} )); then
        local target="${accounts[$((idx-1))]}"
        echo -ne "${Y}Delete all policies for $target? [y/N]: ${N}"
        read -re yn
        if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
          rm -f "$(account_pol_file "$target")"
          ok "  Deleted $target"
          sleep 0.8
        fi
      else
        warn "  Invalid number"; sleep 0.5
      fi

    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#accounts[@]} )); then
      CURRENT_ACCOUNT="${accounts[$((choice-1))]}"
      disallow_input; return 0

    else
      warn "  Invalid choice"; sleep 0.5
    fi
  done
}

local_pol_init() {
  local f; f=$(account_pol_file)
  [[ ! -f "$f" ]] && echo '{}' > "$f"
}

do_local_edit() {
  local_pol_init
  local f; f=$(account_pol_file)
  local ed; ed=$(command -v nano || command -v vi || command -v vim)
  [[ -z "$ed" ]] && die "no editor found"
  allow_input; "$ed" "$f"; disallow_input
}

do_local_show() {
  local f; f=$(account_pol_file)
  if [[ ! -f "$f" ]]; then
    warn "No policy file yet."; sleep 1; return
  fi
  allow_input
  echo -e "\n${P}── user policies: ${CURRENT_ACCOUNT:-default} ─────────────────────${N}\n"
  $PYTHON -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
if not d:
    print('  (empty)')
for k, v in sorted(d.items()):
    print(f'  {k}: {v}')
" "$f"
  echo -e "\n${D}Press Enter...${N}"; read -r; disallow_input
}

# ── import from chrome://policy export ───────────────────────────────────────
EXPORT_FILENAME="policy_export.json"
EXPORT_SEARCH=(
  "/home/chronos/user/Downloads"
  "/home/chronos/user/MyFiles/Downloads"
  "/home/chronos/user/MyFiles"
  "/home/chronos/user"
)

find_policy_export() {
  for dir in "${EXPORT_SEARCH[@]}"; do
    [[ -f "$dir/$EXPORT_FILENAME" ]] && echo "$dir/$EXPORT_FILENAME" && return
  done
}

do_local_import() {
  local upf; upf=$(account_pol_file)
  allow_input
  clear
  echo -e "${P}── Import for: ${CURRENT_ACCOUNT:-default} ───────────────────────────────${N}\n"

  local export_file
  export_file=$(find_policy_export)

  if [[ -z "$export_file" ]]; then
    warn "No export file found (looking for '$EXPORT_FILENAME' in Downloads)."
    echo ""
    info "How to export:"
    echo "  1. Open the browser and go to chrome://policy"
    echo "  2. Click the 'Export to JSON' button at the top"
    echo "  3. Save the file as:  policy_export.json"
    echo "  4. Save it to your Downloads folder"
    echo "  5. Come back to VT2 (Ctrl+Alt+F2) and try again"
    echo ""
    echo -e "${D}Press Enter...${N}"
    read -r; disallow_input; return
  fi

  info "Found: $export_file"
  echo ""

  local result
  result=$($PYTHON - "$export_file" "$upf" << 'PYEOF'
import json, sys

export_path, out_path = sys.argv[1], sys.argv[2]

with open(export_path) as f:
    export = json.load(f)

user_policies = {}

# Format 1: newer Chrome — top-level keys are policy names
# { "PolicyName": { "value": ..., "scope": "User", ... }, ... }
# Sometimes wrapped under "chromePolicies"
def extract_from_flat(d):
    out = {}
    for name, info in d.items():
        if not isinstance(info, dict):
            continue
        scope = info.get('scope', '')
        if scope in ('User', 'user') and 'value' in info:
            out[name] = info['value']
    return out

if 'chromePolicies' in export:
    user_policies = extract_from_flat(export['chromePolicies'])

elif 'policyValues' in export:
    # Format 2: older Chrome — nested under policyValues.chrome.policies
    chrome = export['policyValues'].get('chrome', {})
    user_policies = extract_from_flat(chrome.get('policies', {}))

else:
    # Format 3: flat dict at top level (some versions)
    user_policies = extract_from_flat(export)

if not user_policies:
    # Last resort: grab everything with a value field regardless of scope
    def extract_all(d):
        out = {}
        for name, info in d.items():
            if isinstance(info, dict) and 'value' in info:
                out[name] = info['value']
        return out
    if 'chromePolicies' in export:
        user_policies = extract_all(export['chromePolicies'])
    elif 'policyValues' in export:
        chrome = export['policyValues'].get('chrome', {})
        user_policies = extract_all(chrome.get('policies', {}))
    else:
        user_policies = extract_all(export)
    if user_policies:
        print(f"WARNING: no user-scoped policies found; imported all {len(user_policies)} policies")

with open(out_path, 'w') as f:
    json.dump(user_policies, f, indent=2)

print(f"OK:{len(user_policies)}")
PYEOF
)

  if [[ "$result" == OK:* ]]; then
    local count="${result#OK:}"
    ok "Imported $count policies → $upf"
    [[ "$count" -eq 0 ]] && warn "File is empty — the export may have had no user policies."
  elif [[ "$result" == WARNING:* ]]; then
    warn "$result"
    warn "Review the file before applying."
  else
    warn "Import failed. The export file may be in an unexpected format."
    warn "Try editing user_policies.json manually instead."
  fi

  echo ""
  echo -e "${D}Press Enter...${N}"
  read -r; disallow_input
}

# ── user policy quick-toggle table ───────────────────────────────────────────
# Format: "KEY|TYPE|OFF_VAL|ON_VAL|LABEL"
LOCAL_QUICK=(
  "PrintingEnabled|bool|false|true|Printing allowed"
  "IncognitoModeAvailability|int|1|0|Incognito mode available"
  "BookmarkBarEnabled|bool|false|true|Bookmark bar enabled"
  "SavingBrowserHistoryDisabled|bool|false|true|History saving disabled"
  "PasswordManagerEnabled|bool|false|true|Password manager enabled"
  "SearchSuggestEnabled|bool|false|true|Search suggestions enabled"
  "TranslateEnabled|bool|false|true|Translation enabled"
  "SafeBrowsingEnabled|bool|false|true|Safe Browsing enabled"
  "AutofillAddressEnabled|bool|false|true|Autofill (addresses) enabled"
  "AutofillCreditCardEnabled|bool|false|true|Autofill (cards) enabled"
  "DeveloperToolsAvailability|int|2|0|DevTools available"
  "BrowserSignin|int|0|1|Browser sign-in allowed"
)

do_local_quick() {
  local_pol_init
  local upf; upf=$(account_pol_file)
  allow_input; clear
  while true; do
    echo -e "${P}── user policy quick toggle: ${CURRENT_ACCOUNT:-default} ─────────────${N}"
    echo -e "${D}number to toggle  |  q to go back${N}\n"
    local i=1
    for entry in "${LOCAL_QUICK[@]}"; do
      IFS='|' read -r key type off_val on_val label <<< "$entry"
      local raw
      raw=$($PYTHON -c "
import json; d=json.load(open('$upf'))
v=d.get('$key',None)
print('__unset__' if v is None else str(v))
" 2>/dev/null)
      local display colour
      if   [[ "$raw" == "__unset__" ]]; then display="not set"; colour="$D"
      elif [[ "$raw" == "$on_val" || "$raw" == "True"  ]]; then display="ON";  colour="$G"
      elif [[ "$raw" == "$off_val"|| "$raw" == "False" ]]; then display="OFF"; colour="$R"
      else display="$raw"; colour="$Y"
      fi
      printf "  ${B}%2d)${N}  %-40s ${colour}%s${N}\n" "$i" "$label" "$display"
      ((i++))
    done
    echo ""; echo -ne "${D}> ${N}"; read -re choice
    [[ "$choice" == "q" || "$choice" == "Q" ]] && break
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#LOCAL_QUICK[@]} )); then
      IFS='|' read -r key type off_val on_val label <<< "${LOCAL_QUICK[$((choice-1))]}"
      local cur
      cur=$($PYTHON -c "
import json; d=json.load(open('$upf'))
print('__unset__' if d.get('$key') is None else str(d['$key']))
" 2>/dev/null)
      if [[ "$type" == "bool" ]]; then
        local new="true"
        [[ "$cur" == "True" ]] && new="false"
        $PYTHON -c "
import json
with open('$upf') as f: d=json.load(f)
d['$key']='$new'=='true'
with open('$upf','w') as f: json.dump(d,f,indent=2)
" && ok "  $label → $new"
      else
        local new="$on_val"
        [[ "$cur" == "$on_val" ]] && new="$off_val"
        $PYTHON -c "
import json
with open('$upf') as f: d=json.load(f)
d['$key']=$new
with open('$upf','w') as f: json.dump(d,f,indent=2)
" && ok "  $label → $new"
      fi
      sleep 0.5
    else
      warn "  invalid"; sleep 0.5
    fi
    clear
  done
  disallow_input
}
