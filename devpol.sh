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

# Fully restore the terminal to the state it was in at script start,
# then show the cursor.  This gives backspace / line-editing back for
# every `read` prompt, regardless of what the TUI loop did to stty.
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

remount_rootfs_rw() {
  mount -o remount,rw / 2>/dev/null && return 0
  warn "rootfs remount failed — running make_dev_ssd.sh first..."
  ensure_rootfs_writable
}

# ── preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]     && die "run this as root"
[[ ! -d "$DEVSET_DIR" ]] && die "$DEVSET_DIR not found — is this a managed ChromeOS device?"
command -v python3 &>/dev/null || command -v python &>/dev/null || die "python not found"
PYTHON=$(command -v python3 || command -v python)

# ── find the latest policy blob ───────────────────────────────────────────────
latest_policy() {
  ls "$DEVSET_DIR"/policy.* 2>/dev/null \
    | grep -E 'policy\.[0-9]+$' \
    | sort -t. -k2 -V \
    | tail -n1
}

# ── rootfs write access ───────────────────────────────────────────────────────
detect_disk() {
  for dev in /dev/mmcblk0 /dev/nvme0n1 /dev/sda /dev/mmcblk1; do
    [[ -b "$dev" ]] && echo "$dev" && return
  done
}

ensure_rootfs_writable() {
  if touch /.__devpol_rw_test 2>/dev/null; then
    rm -f /.__devpol_rw_test; return 0
  fi
  warn "Rootfs is read-only. Removing rootfs verification..."
  echo ""
  local disk; disk=$(detect_disk)
  [[ -z "$disk" ]] && die "could not detect main disk"
  info "Detected disk: $disk"
  /usr/share/vboot/bin/make_dev_ssd.sh -i "$disk" --remove_rootfs_verification --partitions 2 \
    || die "make_dev_ssd.sh failed on partition 2"
  /usr/share/vboot/bin/make_dev_ssd.sh -i "$disk" --remove_rootfs_verification --partitions 4 \
    || die "make_dev_ssd.sh failed on partition 4"
  echo ""
  ok "Rootfs verification removed."
  warn "Reboot required. Run the script again after rebooting."
  echo ""
  echo -ne "${D}Reboot now? [Y/n]: ${N}"
  allow_input
  read -re yn
  [[ "$yn" == "n" || "$yn" == "N" ]] && { warn "Reboot manually when ready."; exit 0; }
  reboot; exit 0
}

# ── chrome_dev.conf setup ─────────────────────────────────────────────────────
setup_chrome_conf() {
  grep -q 'disable-policy-key-verification' "$CHROME_CONF" 2>/dev/null && return 0
  ensure_rootfs_writable
  remount_rootfs_rw
  if [[ -f "$CHROME_CONF" && ! -f "$CHROME_CONF_BAK" ]]; then
    cp "$CHROME_CONF" "$CHROME_CONF_BAK"
    info "Backed up $CHROME_CONF"
  fi
  echo '--disable-policy-key-verification' >> "$CHROME_CONF"
  ok "Added --disable-policy-key-verification to $CHROME_CONF"
  warn "Restarting UI to pick up new flag..."
  warn "(come back with Ctrl+Alt+F2)"
  sleep 2; restart_ui; sleep 4
}

# ── chrome_dev.conf DM URL management ────────────────────────────────────────
# Adds/removes the lines needed to redirect Chrome's policy fetching
# to our local DM server. We splice around any existing lines rather
# than replacing the whole file so --disable-policy-key-verification stays.

DM_CONF_MARKER="# devpol-dmserver"

add_dm_url() {
  local port=$1
  remount_rootfs_rw
  # Remove any existing DM server block first
  grep -v "$DM_CONF_MARKER" "$CHROME_CONF" > /tmp/.devpol_conf_tmp 2>/dev/null || true
  cat /tmp/.devpol_conf_tmp > "$CHROME_CONF"
  cat >> "$CHROME_CONF" << EOF
$DM_CONF_MARKER
--device-management-url=http://127.0.0.1:$port/device_management
--enterprise-enable-initial-enrollment=never
--enterprise-enable-state-determination=never
--enterprise-enrollment-skip-robot-auth
--policy-fetch-timeout=1
EOF
  rm -f /tmp/.devpol_conf_tmp
}

remove_dm_url() {
  remount_rootfs_rw
  grep -v "$DM_CONF_MARKER" "$CHROME_CONF" > /tmp/.devpol_conf_tmp 2>/dev/null || true
  cat /tmp/.devpol_conf_tmp > "$CHROME_CONF"
  rm -f /tmp/.devpol_conf_tmp
}

# ── install dependencies ──────────────────────────────────────────────────────
install_deps() {
  if [[ ! -f "$DEVINSTALL_STAMP" ]]; then
    info "Running dev_install to bootstrap emerge (takes a minute)..."
    printf 'y\nn\n' | dev_install --reinstall \
      || die "dev_install failed — connect to internet first"
    touch "$DEVINSTALL_STAMP"
  fi
  ldconfig 2>/dev/null
  info "Emerging required packages..."
  emerge protobuf-python cryptography pyyaml nano \
    || die "emerge failed — check internet connection"
}

# ── download python files ─────────────────────────────────────────────────────
download_files() {
  info "Downloading policy tool files from modmium..."
  mkdir -p "$INSTALL_DIR"
  local files=(
    devpol.py blob_generator.py chrome_device_policy_pb2.py
    chrome_settings_pb2.py device_management_backend_pb2.py
    policy_common_definitions_pb2.py manual_device_policy_proto_map.yaml
  )
  for f in "${files[@]}"; do
    curl -fSLk "$RAW/$f" -o "$INSTALL_DIR/$f" \
      || die "failed to download $f"
    ok "  ✓ $f"
  done
}

# ── generate dm_server.py ─────────────────────────────────────────────────────
# Embedded here so devpol.sh stays a single file. Written to INSTALL_DIR
# on setup, then run as a background process when user policies are active.
generate_dm_server() {
  cat > "$DM_SERVER_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""Minimal ChromeOS DM server for local user policy testing.
Serves google/chromeos/user and google/chrome/user policies from
user_policies.json in the same directory. Designed to work alongside
--disable-policy-key-verification so signatures are not required.
"""
import http.server, json, logging, os, sys, time, urllib.parse, socketserver

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Log every request to a file so problems are diagnosable without
# cluttering VT2. Check with: cat /tmp/devpol_dm.log
LOG_FILE = "/tmp/devpol_dm.log"
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("devpol")

try:
    import device_management_backend_pb2 as dm
    import chrome_settings_pb2
    import policy_common_definitions_pb2
    from blob_generator import apply_user_policies
except ImportError as e:
    log.error("Import error: %s", e)
    print(f"Import error: {e}", flush=True)
    sys.exit(1)

FAKE_TOKEN   = "devpol_fake_token"
POLICY_TYPES = {"google/chromeos/user", "google/chrome/user"}

def policy_file_for(email):
    """Return the policy file path for an email, falling back to the default."""
    if email:
        specific = os.path.join(HERE, f"user_policies_{email}.json")
        if os.path.exists(specific):
            return specific
    default = os.path.join(HERE, "user_policies.json")
    return default if os.path.exists(default) else None

def load_user_proto(email):
    """Load and serialize policies for the given account email."""
    path = policy_file_for(email)
    if not path:
        return chrome_settings_pb2.ChromeSettingsProto().SerializeToString()
    with open(path) as f:
        policies = json.load(f)
    settings = chrome_settings_pb2.ChromeSettingsProto()
    apply_user_policies(policies, settings)
    return settings.SerializeToString()

def make_policy_data(policy_type, value_bytes, email):
    pd = dm.PolicyData()
    pd.policy_type    = policy_type
    pd.policy_value   = value_bytes
    pd.request_token  = email or FAKE_TOKEN
    pd.username       = email
    pd.timestamp      = int(time.time() * 1000)
    return pd.SerializeToString()

def make_fetch_response(policy_type, email):
    value_bytes     = load_user_proto(email)
    policy_data_raw = make_policy_data(policy_type, value_bytes, email)
    r = dm.PolicyFetchResponse()
    r.policy_data   = policy_data_raw
    # Signature intentionally omitted — Chrome has --disable-policy-key-verification
    return r

def resolve_email(params, headers):
    """Work out which account is making this request.

    Priority order:
    1. ?username= on the request URL — Chrome includes this on policy fetches
       even when it skips registration, making it the most reliable signal.
    2. The DM token in the Authorization header — only present if Chrome did
       register with us first and we stored the email as the token.
    3. Empty string → caller falls back to the default policy file.
    """
    # 1. URL query param (present on sign-in fetches even without registration)
    username = params.get("username", [""])[0]
    if "@" in username:
        return username

    # 2. DM token we issued during registration
    auth = headers.get("Authorization", "")
    if "token=" in auth:
        token = auth.split("token=", 1)[-1].strip()
        if "@" in token:
            return token

    return ""

class DMHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if '/test/ping' in self.path:
            self._reply(200, b'OK', 'text/plain')
        else:
            self._reply(404, b'', 'text/plain')

    def do_POST(self):
        params   = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        req_type = params.get('request', [''])[0]
        length   = int(self.headers.get('Content-Length', 0))
        body     = self.rfile.read(length)
        dm_resp  = dm.DeviceManagementResponse()

        auth_hdr = self.headers.get("Authorization", "")
        log.info("POST req_type=%r  auth=%r  path=%s", req_type, auth_hdr, self.path)

        if req_type in ('register_device', 'register_browser'):
            # Use the account email as the token so we can identify the user
            # on subsequent policy fetches from the Authorization header.
            email = params.get('username', [''])[0]
            token = email if email else FAKE_TOKEN
            log.info("  register: email=%r → token=%r", email, token)
            dm_resp.register_response.device_management_token = token

        elif req_type == 'policy':
            email = resolve_email(params, self.headers)
            pol_file = policy_file_for(email)
            log.info("  policy fetch: resolved_email=%r  policy_file=%r", email, pol_file)
            req = dm.DeviceManagementRequest()
            try:
                req.ParseFromString(body)
            except Exception:
                pass
            for fetch_req in req.policy_request.requests:
                log.info("  policy_type requested: %r  (handled=%s)",
                         fetch_req.policy_type, fetch_req.policy_type in POLICY_TYPES)
                if fetch_req.policy_type in POLICY_TYPES:
                    try:
                        r = dm_resp.policy_response.responses.add()
                        r.CopyFrom(make_fetch_response(fetch_req.policy_type, email))
                        log.info("  served %s for %r from %r",
                                 fetch_req.policy_type, email, pol_file)
                    except Exception as e:
                        log.error("  Policy build error (%s): %s", email, e)
                        print(f"Policy build error ({email}): {e}", flush=True)
        else:
            log.info("  unhandled req_type=%r (empty response)", req_type)
        # All other request types get an empty response (status_upload, etc.)

        data = dm_resp.SerializeToString()
        self._reply(200, data, 'application/x-protobuf')

    def _reply(self, code, data, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        log.info("HTTP: " + fmt, *args)

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    # Allow reuse so a quick restart doesn't hit "address in use"
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(('127.0.0.1', port), DMHandler) as srv:
        actual_port = srv.server_address[1]
        print(f"READY:{actual_port}", flush=True)
        srv.serve_forever()
PYEOF
  chmod +x "$DM_SERVER_SCRIPT"
  ok "  ✓ dm_server.py"
}

# ── first-run setup ───────────────────────────────────────────────────────────
setup() {
  if [[ -f "$SETUP_STAMP" ]]; then
    local all_present=1
    for f in devpol.py blob_generator.py chrome_device_policy_pb2.py \
              chrome_settings_pb2.py device_management_backend_pb2.py \
              policy_common_definitions_pb2.py manual_device_policy_proto_map.yaml \
              dm_server.py; do
      [[ ! -f "$INSTALL_DIR/$f" ]] && all_present=0 && break
    done
    if [[ $all_present -eq 1 ]]; then
      return  # nothing to do — skip straight to TUI
    fi
    warn "Some files missing — re-running setup..."
  fi
  echo ""
  info "=== First-run setup ==="
  # chrome_dev.conf is intentionally NOT touched here — only patched
  # in do_apply() so Chrome stays usable until the user actually applies.
  install_deps
  download_files
  generate_dm_server
  touch "$SETUP_STAMP"
  echo ""
  ok "Setup complete."
  sleep 1
}

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
  # Patch chrome_dev.conf here — only when the user explicitly applies.
  # If the flag isn't present yet, Chrome restarts; the user returns to VT2
  # and runs Apply again — the grep check at the top of setup_chrome_conf
  # short-circuits immediately on the second run.
  setup_chrome_conf
  info "Applying policies..."
  cd "$INSTALL_DIR" || die "cannot cd to $INSTALL_DIR"
  ldconfig 2>/dev/null
  $PYTHON devpol.py "$JSON_FILE" || die "apply failed"
  ok "Done — policies applied."
  warn "(come back with Ctrl+Alt+F2 after UI restarts)"
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

  # Start server; capture stdout+stderr to a temp file so we can both
  # read the READY:<port> line and show errors if it fails.
  # NOTE: do NOT use a FIFO here — reading from a FIFO in a subshell (&)
  # means the variable is set in the subshell and never visible to the
  # parent, so ready would always be empty.
  # nohup + disown: detach from the VT2 session so the daemon survives
  # restart_ui (which cycles VT2 and would otherwise send SIGHUP).
  local tmpout="/tmp/.devpol_dm_out_$$"
  nohup $PYTHON dm_server.py "$DM_FIXED_PORT" >"$tmpout" 2>&1 &
  local srv_pid=$!
  disown "$srv_pid"
  echo "$srv_pid" > "$DM_PID_FILE"

  # Poll for READY:<port> line (up to 10 s, check every 200 ms).
  # Exit early if the server process already died.
  local ready="" i=0
  while (( i < 50 )); do
    sleep 0.2
    kill -0 "$srv_pid" 2>/dev/null || break   # server exited already
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

  # Port is always DM_FIXED_PORT — record it so dm_server_port() still works.
  echo "$DM_FIXED_PORT" > "$DM_PORT_FILE"
  ok "DM server running on port $DM_FIXED_PORT (PID $srv_pid)"

  # Snapshot whether the DM block already existed BEFORE we rewrite it.
  # If it was already there, Chrome already knows about our server (same
  # fixed port) and a UI restart is not needed — skipping it avoids
  # cycling VT2 again.
  local dm_was_set=0
  grep -q "$DM_CONF_MARKER" "$CHROME_CONF" 2>/dev/null && dm_was_set=1

  # Redirect Chrome to it
  add_dm_url "$DM_FIXED_PORT"
  ok "chrome_dev.conf updated with --device-management-url"

  if [[ $dm_was_set -eq 0 ]]; then
    warn "Restarting UI so Chrome picks up the new DM server..."
    warn "(come back with Ctrl+Alt+F2)"
    sleep 2; restart_ui; sleep 4
  else
    ok "DM server restarted on port $DM_FIXED_PORT — Chrome already points here, no UI restart needed."
    ok "Reload policies in chrome://policy (or sign out and back in) to fetch fresh policies."
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
# Policy files are named user_policies_<email>.json for per-account policies,
# or user_policies.json as a default for all accounts.
# CURRENT_ACCOUNT holds the selected email for the current TUI session.

CURRENT_ACCOUNT=""

account_pol_file() {
  # Return the policy file path for a given email (arg 1), or CURRENT_ACCOUNT
  local email="${1:-$CURRENT_ACCOUNT}"
  if [[ -n "$email" ]]; then
    echo "$INSTALL_DIR/user_policies_${email}.json"
  else
    echo "$USER_POL_FILE"
  fi
}

list_accounts() {
  # Print each email that has a per-account policy file
  for f in "$INSTALL_DIR"/user_policies_*.json; do
    [[ -f "$f" ]] || continue
    local name="${f##*/user_policies_}"
    name="${name%.json}"
    echo "$name"
  done
}

select_account() {
  # Interactive account picker. Sets CURRENT_ACCOUNT and returns 0,
  # or returns 1 if the user cancels.
  # Loops so the list refreshes after adds/deletes without exiting.
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
# User goes to chrome://policy → Export to JSON → saves as policy_export.json
# to Downloads. We find it, extract user-scoped policies, write user_policies.json.

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
    ok "Imported $count policies → $USER_POL_FILE"
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

# Quick-toggle table. Format: "KEY|TYPE|OFF_VAL|ON_VAL|LABEL"
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
    # Show current account and its policy count
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
# Always regenerate dm_server.py so any changes in this script take effect
# immediately, without needing to wipe the setup stamp.
generate_dm_server
run_tui
