#!/bin/bash
# devpol_setup.sh — environment setup for devpol
# Sourced by devpol.sh. Requires: INSTALL_DIR, CHROME_CONF, CHROME_CONF_BAK,
# DEVINSTALL_STAMP, SETUP_STAMP, DM_SERVER_SCRIPT, RAW, and the helper
# functions (die, info, ok, warn) defined in devpol.sh.

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

remount_rootfs_rw() {
  mount -o remount,rw / 2>/dev/null && return 0
  warn "rootfs remount failed — running make_dev_ssd.sh first..."
  ensure_rootfs_writable
}

# ── chrome_dev.conf setup ─────────────────────────────────────────────────────
# Writes --disable-policy-key-verification and boot-safety flags.
# Idempotent: checks before writing, strips stale copies before appending.
# Does NOT restart UI — callers (do_apply, start_dm_server) own that.
#
setup_chrome_conf() {
  # Nothing to do if all our flags are already present.
  local needs_update=0
  grep -q 'disable-policy-key-verification' "$CHROME_CONF" 2>/dev/null || needs_update=1
  [[ $needs_update -eq 0 ]] && return 0

  ensure_rootfs_writable
  remount_rootfs_rw

  if [[ -f "$CHROME_CONF" && ! -f "$CHROME_CONF_BAK" ]]; then
    cp "$CHROME_CONF" "$CHROME_CONF_BAK"
    info "Backed up $CHROME_CONF"
  fi

  # Strip any pre-existing copies of our flags to avoid duplicates, then
  # append a clean block.  We anchor each pattern to the start of the line
  # so we don't accidentally remove flags that merely contain these strings.
  grep -vE '^--(disable-policy-key-verification$|enterprise-enable-initial-enrollment=|enterprise-enable-state-determination=|enterprise-enrollment-skip-robot-auth$)' \
    "$CHROME_CONF" > /tmp/.devpol_conf_tmp 2>/dev/null || true
  cat /tmp/.devpol_conf_tmp > "$CHROME_CONF"
  rm -f /tmp/.devpol_conf_tmp

  cat >> "$CHROME_CONF" << 'CONFEOF'
--disable-policy-key-verification
--enterprise-enable-initial-enrollment=never
--enterprise-enable-state-determination=never
--enterprise-enrollment-skip-robot-auth
CONFEOF

  ok "Updated $CHROME_CONF with policy flags"
  return 1   # non-zero signals caller that a UI restart is needed
}

# ── chrome_dev.conf DM URL management ────────────────────────────────────────
# Uses start+end comment markers so the entire block (and only the block)
# is removed on every update — fixing the stacking bug where the old code
# only removed the comment line and left the flag lines to accumulate.
#
# Enrollment-blocking flags are now written by setup_chrome_conf(), not here,
# so this block only ever contains the --device-management-url line.

DM_CONF_START="# devpol-dmserver-start"
DM_CONF_END="# devpol-dmserver-end"

add_dm_url() {
  local port=$1
  remount_rootfs_rw

  # 1. Remove the new start/end block if present.
  sed -i "/^# devpol-dmserver-start/,/^# devpol-dmserver-end/d" \
    "$CHROME_CONF" 2>/dev/null || true

  # 2. Remove old single-marker comment lines left by previous installs.
  grep -v '^# devpol-dmserver$' "$CHROME_CONF" > /tmp/.devpol_conf_tmp 2>/dev/null || true
  cat /tmp/.devpol_conf_tmp > "$CHROME_CONF"
  rm -f /tmp/.devpol_conf_tmp

  # 3. Remove any orphaned --device-management-url= lines (stacking remnants).
  sed -i '/^--device-management-url=/d' "$CHROME_CONF" 2>/dev/null || true

  # 4. Append a clean, single-entry block.
  cat >> "$CHROME_CONF" << EOF
$DM_CONF_START
--device-management-url=http://127.0.0.1:$port/device_management
$DM_CONF_END
EOF
}

remove_dm_url() {
  remount_rootfs_rw
  sed -i "/^# devpol-dmserver-start/,/^# devpol-dmserver-end/d" \
    "$CHROME_CONF" 2>/dev/null || true
  grep -v '^# devpol-dmserver$' "$CHROME_CONF" > /tmp/.devpol_conf_tmp 2>/dev/null || true
  cat /tmp/.devpol_conf_tmp > "$CHROME_CONF"
  rm -f /tmp/.devpol_conf_tmp
  sed -i '/^--device-management-url=/d' "$CHROME_CONF" 2>/dev/null || true
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
# Embedded here so devpol.sh stays self-contained. Written to INSTALL_DIR
# on setup and on every script launch (so edits here take effect immediately
# without wiping the setup stamp).
#
# Changes from original:
#  - RSA signing: policy_data is now signed with a locally-generated key and
#    new_public_key is included in every response.  Chrome no longer rejects
#    responses as "Bad Signature" when --disable-policy-key-verification is set.
#  - register_policy_agent added to the register handler (M130+ sends this).
#  - Device policy types are explicitly logged but receive no response entry,
#    so Chrome keeps its cached device policy rather than clearing it.
generate_dm_server() {
  cat > "$DM_SERVER_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""Minimal ChromeOS DM server for local user policy testing.

Serves google/chromeos/user and google/chrome/user policies from
user_policies_<email>.json (or user_policies.json) in the same directory.
Responses are RSA-signed so Chrome accepts them alongside
--disable-policy-key-verification without triggering "Bad Signature".
"""
import http.server, json, logging, os, sys, time, urllib.parse, socketserver

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

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

# ── RSA signing ───────────────────────────────────────────────────────────────
# A key pair is generated once and persisted to disk.  Chrome caches the
# public key after the first successful fetch; changing the key would require
# the user to sign out and back in.
#
# new_public_key_verification_signature is intentionally omitted: Chrome
# verifies it against a Google root key we don't have.  Setting
# --disable-policy-key-verification tells Chrome to skip that check.
# policy_data_signature IS required (separate from the root-key check) and
# is what was causing "Bad Signature" — we now always provide it.

_KEY_FILE = os.path.join(HERE, "dm_signing_key.pem")

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa, padding as asym_padding

    def _load_or_create_signing_key():
        if os.path.exists(_KEY_FILE):
            with open(_KEY_FILE, "rb") as f:
                return serialization.load_pem_private_key(f.read(), password=None)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with open(_KEY_FILE, "wb") as f:
            f.write(key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.TraditionalOpenSSL,
                serialization.NoEncryption()))
        log.info("Generated new DM signing key → %s", _KEY_FILE)
        return key

    _SIGNING_KEY    = _load_or_create_signing_key()
    _PUBLIC_KEY_DER = _SIGNING_KEY.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo)

    def _sign(data: bytes) -> bytes:
        return _SIGNING_KEY.sign(data, asym_padding.PKCS1v15(), hashes.SHA256())

    _SIGNING_OK = True
    log.info("RSA signing ready (key: %s)", _KEY_FILE)

except ImportError:
    # cryptography not yet installed — server still starts, just unsigned.
    # emerge cryptography should have been run during setup; this is a fallback.
    _SIGNING_OK     = False
    _PUBLIC_KEY_DER = b""
    def _sign(data: bytes) -> bytes:
        return b""
    log.warning("cryptography library unavailable — responses will be unsigned")

# ─────────────────────────────────────────────────────────────────────────────

FAKE_TOKEN        = "devpol_fake_token"
USER_POLICY_TYPES = {"google/chromeos/user", "google/chrome/user"}

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
    pd.policy_type   = policy_type
    pd.policy_value  = value_bytes
    pd.request_token = email or FAKE_TOKEN
    pd.username      = email
    pd.timestamp     = int(time.time() * 1000)
    return pd.SerializeToString()

def make_fetch_response(policy_type, email):
    value_bytes     = load_user_proto(email)
    policy_data_raw = make_policy_data(policy_type, value_bytes, email)
    r = dm.PolicyFetchResponse()
    r.policy_data           = policy_data_raw
    r.policy_data_signature = _sign(policy_data_raw)
    if _PUBLIC_KEY_DER:
        r.new_public_key    = _PUBLIC_KEY_DER
    # new_public_key_verification_signature intentionally omitted —
    # Chrome skips the Google root-key check with --disable-policy-key-verification.
    return r

def resolve_email(params, headers):
    """Work out which account is making this request.

    Priority order:
    1. ?username= on the request URL (most reliable — present even without
       prior registration).
    2. DM token in the Authorization header (we store the email as the token
       during registration so we can recover it here).
    3. Empty string → caller falls back to the default policy file.
    """
    username = params.get("username", [""])[0]
    if "@" in username:
        return username
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

        if req_type in ('register_device', 'register_browser', 'register_policy_agent'):
            # Use the account email as the token so we can identify the user
            # on subsequent policy fetches from the Authorization header.
            email = params.get('username', [''])[0]
            token = email if email else FAKE_TOKEN
            log.info("  register: email=%r → token=%r", email, token)
            dm_resp.register_response.device_management_token = token

        elif req_type == 'policy':
            email    = resolve_email(params, self.headers)
            pol_file = policy_file_for(email)
            log.info("  policy fetch: resolved_email=%r  policy_file=%r", email, pol_file)
            req = dm.DeviceManagementRequest()
            try:
                req.ParseFromString(body)
            except Exception:
                pass

            for fetch_req in req.policy_request.requests:
                pt = fetch_req.policy_type
                if pt in USER_POLICY_TYPES:
                    log.info("  serving %r for %r from %r", pt, email, pol_file)
                    try:
                        r = dm_resp.policy_response.responses.add()
                        r.CopyFrom(make_fetch_response(pt, email))
                    except Exception as e:
                        log.error("  Policy build error (%s): %s", email, e)
                        print(f"Policy build error ({email}): {e}", flush=True)
                else:
                    # Device policy types (google/chromeos/device etc.) —
                    # serve the on-disk blob that the school MDM originally
                    # wrote.  With --disable-policy-key-verification Chrome
                    # won't re-verify the blob's signature, so it accepts it
                    # and proceeds to the login screen instead of hanging.
                    import glob as _glob
                    blobs = sorted(
                        (f for f in _glob.glob("/var/lib/devicesettings/policy.*")
                         if f.rsplit(".", 1)[-1].isdigit()),
                        key=lambda f: int(f.rsplit(".", 1)[-1])
                    )
                    if blobs:
                        try:
                            r = dm_resp.policy_response.responses.add()
                            r.ParseFromString(open(blobs[-1], "rb").read())
                            log.info("  served on-disk device policy for %r", pt)
                        except Exception as e:
                            log.warning("  device policy passthrough failed: %s", e)
                    else:
                        log.warning("  no on-disk device policy blob for %r", pt)

        else:
            log.info("  unhandled req_type=%r (empty response)", req_type)

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
      return
    fi
    warn "Some files missing — re-running setup..."
  fi
  echo ""
  info "=== First-run setup ==="
  install_deps
  download_files
  generate_dm_server
  touch "$SETUP_STAMP"
  echo ""
  ok "Setup complete."
  sleep 1
}
