#!/bin/sh
set -eu
umask 077
cd "$(dirname "$0")/.."

fail() { echo "$*" >&2; exit 1; }
usage() { echo "Usage: $0 [--prepare-only] [--device-id ANDROID_ID]"; }
device=
prepare_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prepare-only) prepare_only=true ;;
    --device-id|-d) [ "$#" -ge 2 ] || fail 'Missing Android device ID.'; device=$2; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

# Prefer this project's recorded SDKs, including when launched from the IDE.
find_tool() {
  if [ -n "$1" ]; then command -v "$1"
  elif [ -x "$2" ]; then echo "$2"
  else command -v "$3"
  fi
}
case "$(uname -m)" in arm64) arch=arm64 ;; *) arch=x64 ;; esac
node_bin=$(find_tool "${ITKAN_NODE:-}" "$HOME/development/node-v24.20.0-darwin-$arch/bin/node" node) || fail 'Node.js was not found. Set ITKAN_NODE to the Node executable.'
sdk_root=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
adb=$(find_tool "${ADB:-}" "$sdk_root/platform-tools/adb" adb) || fail 'Android platform-tools (adb) were not found.'
if [ "$prepare_only" = false ]; then
  flutter=$(find_tool "${ITKAN_FLUTTER:-}" "$HOME/development/flutter-3.47.2/bin/flutter" flutter) || fail 'Flutter was not found. Set ITKAN_FLUTTER to the Flutter executable.'
fi
if [ -z "$device" ]; then
  devices=$("$adb" devices)
  device=$(printf '%s\n' "$devices" | awk '$2 == "device" { count++; device=$1 } END { if (count == 1) print device }')
  [ -n "$device" ] || fail 'Select one connected Android device with --device-id.'
fi
[ "$("$adb" -s "$device" get-state)" = device ] || fail 'The selected Android device is unavailable.'
reverse_target() {
  forwards=$("$adb" -s "$device" reverse --list) || return 1
  printf '%s\n' "$forwards" | awk '$2 == "tcp:8787" { print $3 }'
}
target=$(reverse_target)
[ -z "$target" ] || [ "$target" = tcp:8787 ] || fail 'Device port 8787 already forwards to a different host port.'

python3 - "$node_bin" <<'PY'
import fcntl
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time

root = Path.cwd()
proxy = root / 'tool/local_ai_proxy.mjs'
client_path = root / 'config/ai.emulator.json'
cache = root / '.dart_tool'
cache.mkdir(exist_ok=True)
# Serialize token creation and process startup when two IDE tasks run together.
lock = (cache / 'itkan-ai.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX)

def write_json(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, mode='w', delete=False) as out:
        temp = Path(out.name)
        try:
            json.dump(value, out, indent=2)
            out.write('\n')
            out.flush()
            os.replace(temp, path)
        finally:
            temp.unlink(missing_ok=True)

def request(method, endpoint, **kwargs):
    conn = http.client.HTTPConnection('127.0.0.1', 8787, timeout=1)
    try:
        conn.request(method, endpoint, **kwargs)
        response = conn.getresponse()
        return response.status, response.read(16384)
    finally:
        conn.close()

client = {'AI_BASE_URL': 'http://127.0.0.1:8787/ai', 'AI_API_FORMAT': 'proxy'}
if not (root / 'config/ai.local.json').is_file():
    sys.exit('The host configuration config/ai.local.json is missing.')
try:
    saved = json.loads(client_path.read_text(encoding='utf-8-sig')) if client_path.exists() else dict(client)
except (OSError, ValueError):
    sys.exit('Could not read the local client configuration.')
if not isinstance(saved, dict) or any(saved.get(k) != v for k, v in client.items()):
    sys.exit('The client configuration must use the local proxy at http://127.0.0.1:8787/ai.')
token = saved.get('AI_PROXY_TOKEN')
if token is None or token == '':
    token = saved['AI_PROXY_TOKEN'] = secrets.token_hex(32)
    write_json(client_path, saved)
if not isinstance(token, str) or not re.fullmatch(r'[0-9a-f]{64}', token):
    sys.exit('The local development token has an invalid format.')
client['AI_PROXY_TOKEN'] = token

try:
    try:
        status, body = request('GET', '/health')
    except ConnectionRefusedError:
        process = subprocess.Popen([sys.argv[1], str(proxy)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        for _ in range(30):
            time.sleep(0.1)
            if process.poll() is not None:
                sys.exit('The local AI proxy could not start. Check its host configuration and port 8787.')
            try:
                status, body = request('GET', '/health')
                break
            except ConnectionRefusedError:
                continue
        else:
            process.terminate()
            sys.exit('The local AI proxy did not become ready.')
    health = json.loads(body)
    if status != 200 or health.get('service') != 'my-fridge-local-ai-proxy' or health.get('ready') is not True or health.get('clientAuthentication') != 'local_token':
        sys.exit('Port 8787 is in use by an incompatible service.')
    # Verify the listener belongs to this checkout before sending its local token.
    pids = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-t', '-iTCP:8787', '-sTCP:LISTEN'], text=True).split()
    if len(pids) != 1:
        sys.exit('Could not identify the listener on port 8787.')
    cwd = subprocess.check_output(['/usr/sbin/lsof', '-a', '-p', pids[0], '-d', 'cwd', '-Fn'], text=True).splitlines()
    command = subprocess.check_output(['/bin/ps', '-p', pids[0], '-o', 'command='], text=True).strip()
    if 'n' + str(root) not in cwd or not command.endswith((' ' + str(proxy), ' tool/local_ai_proxy.mjs')):
        sys.exit('Another project is using port 8787.')
    # The server rejects this media type before doing any provider work.
    status, _ = request('POST', '/ai', body=b'', headers={'X-Itkan-Client': token, 'Content-Type': 'text/plain'})
    if status != 415:
        sys.exit('The running proxy did not accept this project’s local client token.')
except (OSError, ValueError, AttributeError, http.client.HTTPException, subprocess.SubprocessError):
    sys.exit('Could not verify the local proxy on port 8787.')
# Pass only these three client fields to Flutter, even if the source file has additional fields.
write_json(cache / 'itkan-ai-client.json', client)
PY

if [ -z "$target" ]; then
  "$adb" -s "$device" reverse --no-rebind tcp:8787 tcp:8787 || [ "$(reverse_target)" = tcp:8787 ] || fail 'Could not forward the device port.'
fi
echo "Local AI proxy and Android port forwarding are ready for $device."
[ "$prepare_only" = true ] || exec "$flutter" run --debug --dart-define-from-file=.dart_tool/itkan-ai-client.json -d "$device"
