#!/usr/bin/env bash
#
# dev-camera.sh — spin up a fake IP camera for testing LemurCam without hardware.
#
# Streams a continuously-changing test pattern (a ticking-clock test card) plus a
# constantly-sweeping siren tone over RTSP via mediamtx, and runs a tiny virtual
# ONVIF device so the camera also shows up in LemurCam's ONVIF discovery. Use it
# to exercise both the "paste an RTSP URL" flow and the "discover an ONVIF camera"
# flow.
#
# The audio sweeps on purpose: a steady tone is removed within ~1s by the adaptive
# noise suppression / Voice Isolation in many apps (Zoom, Meet, FaceTime, macOS
# mic modes), which makes a perfectly-working mic look dead. A tone that never
# holds still can't be characterized as steady noise, so it survives the gate.
#
# Usage:
#   scripts/dev-camera.sh            # start the fake camera; Ctrl-C to stop
#   scripts/dev-camera.sh --help
#
# Override defaults via environment variables:
#   CAMERA_HOST   address the app connects to (default: this Mac's LAN IP, else 127.0.0.1)
#   RTSP_PORT     RTSP port served by mediamtx           (default: 8554)
#   RTSP_PATH     RTSP stream path                        (default: cam)
#   ONVIF_PORT    HTTP port for the virtual ONVIF device  (default: 8088)
#   VIDEO_SIZE    test pattern resolution                 (default: 1280x720)
#   FPS           test pattern frame rate                 (default: 30)
#   CAMERA_NAME   ONVIF device name                       (default: "LemurCam Test Camera")
#   VIDEO_CODEC   h264 or h265                            (default: h264)

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  # Print the contiguous comment header (skip the shebang, stop at the first
  # line of code), stripping the leading "# ".
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit 0
fi

# --- Configuration -----------------------------------------------------------

RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_PATH="${RTSP_PATH:-cam}"
ONVIF_PORT="${ONVIF_PORT:-8088}"
VIDEO_SIZE="${VIDEO_SIZE:-1280x720}"
FPS="${FPS:-30}"
CAMERA_NAME="${CAMERA_NAME:-LemurCam Test Camera}"
VIDEO_CODEC="${VIDEO_CODEC:-h264}"

# The address the app dials. Default to this Mac's LAN IP so the fake camera
# behaves like a real one on the network; fall back to loopback.
detect_host() {
  local ip
  for iface in en0 en1 en2 en3; do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  done
  echo "127.0.0.1"
}
CAMERA_HOST="${CAMERA_HOST:-$(detect_host)}"

# --- Dependencies ------------------------------------------------------------

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: '$1' not found. $2" >&2
    exit 1
  fi
}
require ffmpeg "Install it with: brew install ffmpeg"
require node "Install Node.js, e.g.: brew install node"
require nc "Expected /usr/bin/nc on macOS"

if ! command -v mediamtx >/dev/null 2>&1; then
  echo "mediamtx not found; installing via Homebrew..."
  require brew "Install mediamtx manually: https://github.com/bluenviron/mediamtx"
  brew install mediamtx
fi

case "$VIDEO_CODEC" in
  h264)
    VCODEC_ARGS=(-c:v libx264 -profile:v baseline -pix_fmt yuv420p -preset veryfast -tune zerolatency)
    ONVIF_ENCODING="H264"
    ;;
  h265)
    VCODEC_ARGS=(-c:v libx265 -tag:v hvc1 -preset ultrafast)
    ONVIF_ENCODING="H265"
    ;;
  *)
    echo "error: VIDEO_CODEC must be 'h264' or 'h265' (got '$VIDEO_CODEC')" >&2
    exit 1
    ;;
esac

# --- Workspace & cleanup -----------------------------------------------------

WORKDIR="$(mktemp -d -t lemurcam-devcam)"
PIDS=()

cleanup() {
  trap - EXIT INT TERM
  echo
  echo "Stopping fake camera..."
  for pid in "${PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  sleep 0.3
  for pid in "${PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill -9 "$pid" 2>/dev/null || true; fi
  done
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

wait_for_port() {
  local port="$1" tries="${2:-50}"
  while [ "$tries" -gt 0 ]; do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

# --- mediamtx (RTSP server) --------------------------------------------------

MTX_CONFIG="$WORKDIR/mediamtx.yml"
cat > "$MTX_CONFIG" <<EOF
logLevel: info
api: false
metrics: false
pprof: false
playback: false
rtmp: false
hls: false
webrtc: false
srt: false
rtsp: true
rtspTransports: [tcp, udp]
rtspAddress: :${RTSP_PORT}
paths:
  ${RTSP_PATH}:
    source: publisher
EOF

echo "Starting mediamtx (RTSP on :${RTSP_PORT})..."
mediamtx "$MTX_CONFIG" > "$WORKDIR/mediamtx.log" 2>&1 &
PIDS+=($!)

if ! wait_for_port "$RTSP_PORT"; then
  echo "error: mediamtx did not start. Log:" >&2
  cat "$WORKDIR/mediamtx.log" >&2
  exit 1
fi

# --- ffmpeg (test pattern publisher) -----------------------------------------

PUBLISH_URL="rtsp://127.0.0.1:${RTSP_PORT}/${RTSP_PATH}"

# A two-voice FM "siren": each voice is a carrier whose pitch is swept by a slow
# modulator (instantaneous freq = carrier + deviation·cos, so it stays bounded —
# no runaway/aliasing). The two voices use different carriers and sweep rates so
# the sound never quite repeats, defeating adaptive noise cancellation. Peak
# amplitude 0.65 leaves headroom (no clipping). No ':' / ',' / '|' in the expr so
# lavfi option parsing leaves it intact.
AUDIO_EXPR="0.4*sin(2*PI*660*t+240*sin(2*PI*1.7*t))+0.25*sin(2*PI*990*t+160*sin(2*PI*1.1*t))"

echo "Starting ffmpeg test pattern (${VIDEO_SIZE} @${FPS}fps, ${VIDEO_CODEC})..."
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=${VIDEO_SIZE}:rate=${FPS}" \
  -f lavfi -i "aevalsrc=${AUDIO_EXPR}:sample_rate=48000" \
  "${VCODEC_ARGS[@]}" -g "${FPS}" -keyint_min "${FPS}" \
  -c:a aac -b:a 128k -ar 48000 -ac 2 \
  -f rtsp -rtsp_transport tcp "$PUBLISH_URL" > "$WORKDIR/ffmpeg.log" 2>&1 &
PIDS+=($!)

stream_ready() {
  local tries="${1:-40}"
  while [ "$tries" -gt 0 ]; do
    if ffprobe -v error -rtsp_transport tcp -i "$PUBLISH_URL" \
        -select_streams v:0 -show_streams >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.25
  done
  return 1
}

echo "Waiting for the video stream to come up..."
if ! stream_ready; then
  echo "error: the test stream did not start. ffmpeg log:" >&2
  tail -n 20 "$WORKDIR/ffmpeg.log" >&2
  exit 1
fi

# --- Virtual ONVIF device ----------------------------------------------------
# A dependency-free Node responder: answers WS-Discovery probes and the handful
# of SOAP operations LemurCam calls (GetDeviceInformation, GetProfiles,
# GetStreamUri), pointing the stream URI at the mediamtx RTSP stream above.

ONVIF_JS="$WORKDIR/onvif-server.js"
cat > "$ONVIF_JS" <<'ONVIF_EOF'
'use strict';
const dgram = require('dgram');
const http = require('http');
const crypto = require('crypto');

const HOST = process.env.CAMERA_HOST || '127.0.0.1';
const ONVIF_PORT = parseInt(process.env.ONVIF_PORT || '8088', 10);
const RTSP_PORT = parseInt(process.env.RTSP_PORT || '8554', 10);
const RTSP_PATH = process.env.RTSP_PATH || 'cam';
const NAME = process.env.CAMERA_NAME || 'LemurCam Test Camera';
const ENCODING = process.env.ONVIF_ENCODING || 'H264';
const [WIDTH, HEIGHT] = (process.env.VIDEO_SIZE || '1280x720').split('x');

const UUID = 'urn:uuid:' + crypto.randomUUID();
const DEVICE_SERVICE = `http://${HOST}:${ONVIF_PORT}/onvif/device_service`;
const MEDIA_SERVICE = `http://${HOST}:${ONVIF_PORT}/onvif/media`;
const STREAM_URI = `rtsp://${HOST}:${RTSP_PORT}/${RTSP_PATH}`;
const PROFILE_TOKEN = 'profile_1';

const SCOPES = [
  `onvif://www.onvif.org/name/${encodeURIComponent(NAME)}`,
  `onvif://www.onvif.org/hardware/LemurCamDev`,
  `onvif://www.onvif.org/model/FakeCam`,
  `onvif://www.onvif.org/type/NetworkVideoTransmitter`,
  `onvif://www.onvif.org/Profile/Streaming`,
].join(' ');

// --- WS-Discovery (multicast 239.255.255.250:3702) ---------------------------

const MCAST_ADDR = '239.255.255.250';
const WSD_PORT = 3702;

function probeMatch(relatesTo) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <s:Header>
    <a:MessageID>urn:uuid:${crypto.randomUUID()}</a:MessageID>
    <a:RelatesTo>${relatesTo}</a:RelatesTo>
    <a:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:To>
    <a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>
  </s:Header>
  <s:Body>
    <d:ProbeMatches>
      <d:ProbeMatch>
        <wsa:EndpointReference><wsa:Address>${UUID}</wsa:Address></wsa:EndpointReference>
        <d:Types>dn:NetworkVideoTransmitter</d:Types>
        <d:Scopes>${SCOPES}</d:Scopes>
        <d:XAddrs>${DEVICE_SERVICE}</d:XAddrs>
        <d:MetadataVersion>1</d:MetadataVersion>
      </d:ProbeMatch>
    </d:ProbeMatches>
  </s:Body>
</s:Envelope>`;
}

const disco = dgram.createSocket({ type: 'udp4', reuseAddr: true });
disco.on('error', (e) => console.error('[wsd] error:', e.message));
disco.on('message', (msg, rinfo) => {
  const text = msg.toString('utf8');
  if (text.indexOf('Probe') === -1 || text.indexOf('ProbeMatches') !== -1) return;
  const m = text.match(/MessageID[^>]*>\s*([^<\s]+)/);
  const reply = Buffer.from(probeMatch(m ? m[1] : ''), 'utf8');
  disco.send(reply, rinfo.port, rinfo.address, (err) => {
    if (err) console.error('[wsd] reply error:', err.message);
    else console.log(`[wsd] ProbeMatch -> ${rinfo.address}:${rinfo.port}`);
  });
});
disco.bind(WSD_PORT, () => {
  // Join on the default interface and (if known) the LAN interface, so the
  // app's multicast probe reaches us regardless of the route it took.
  try { disco.addMembership(MCAST_ADDR); } catch (e) { /* already joined */ }
  if (HOST && HOST !== '127.0.0.1') {
    try { disco.addMembership(MCAST_ADDR, HOST); } catch (e) { /* ignore */ }
  }
  try { disco.setMulticastLoopback(true); } catch (e) { /* ignore */ }
  console.log(`[wsd] listening on udp/${WSD_PORT} for ProbeMatch`);
});

// --- ONVIF SOAP service ------------------------------------------------------
// Responses mirror the unprefixed, default-namespaced element shapes the app's
// XML parser matches (see Tests/ONVIFClientTests.swift).

function envelope(body) {
  return `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">` +
    `<s:Header/><s:Body>${body}</s:Body></s:Envelope>`;
}

function detectOp(body) {
  const ops = ['GetDeviceInformation', 'GetSystemDateAndTime', 'GetCapabilities',
    'GetServices', 'GetProfiles', 'GetStreamUri', 'GetSnapshotUri', 'GetScopes'];
  for (const op of ops) {
    if (new RegExp(`<([A-Za-z0-9]+:)?${op}[ />]`).test(body)) return op;
  }
  return 'Unknown';
}

function responseFor(op) {
  const DEV = 'http://www.onvif.org/ver10/device/wsdl';
  const MEDIA = 'http://www.onvif.org/ver10/media/wsdl';
  switch (op) {
    case 'GetDeviceInformation':
      return envelope(`<GetDeviceInformationResponse xmlns="${DEV}">` +
        `<Manufacturer>LemurCam</Manufacturer><Model>FakeCam</Model>` +
        `<FirmwareVersion>1.0</FirmwareVersion><SerialNumber>DEV-0001</SerialNumber>` +
        `<HardwareId>LemurCamDev</HardwareId></GetDeviceInformationResponse>`);
    case 'GetProfiles':
      return envelope(`<GetProfilesResponse xmlns="${MEDIA}">` +
        `<Profiles token="${PROFILE_TOKEN}"><Name>Main Stream</Name>` +
        `<VideoEncoderConfiguration><Resolution><Width>${WIDTH}</Width>` +
        `<Height>${HEIGHT}</Height></Resolution><Encoding>${ENCODING}</Encoding>` +
        `</VideoEncoderConfiguration></Profiles></GetProfilesResponse>`);
    case 'GetStreamUri':
      return envelope(`<GetStreamUriResponse xmlns="${MEDIA}"><MediaUri>` +
        `<Uri>${STREAM_URI}</Uri></MediaUri></GetStreamUriResponse>`);
    case 'GetCapabilities':
      return envelope(`<GetCapabilitiesResponse xmlns="${DEV}"><Capabilities>` +
        `<Device><XAddr>${DEVICE_SERVICE}</XAddr></Device>` +
        `<Media><XAddr>${MEDIA_SERVICE}</XAddr></Media></Capabilities>` +
        `</GetCapabilitiesResponse>`);
    case 'GetServices':
      return envelope(`<GetServicesResponse xmlns="${DEV}">` +
        `<Service><Namespace>${DEV}</Namespace><XAddr>${DEVICE_SERVICE}</XAddr></Service>` +
        `<Service><Namespace>${MEDIA}</Namespace><XAddr>${MEDIA_SERVICE}</XAddr></Service>` +
        `</GetServicesResponse>`);
    case 'GetSystemDateAndTime': {
      const d = new Date();
      return envelope(`<GetSystemDateAndTimeResponse xmlns="${DEV}"><SystemDateAndTime>` +
        `<DateTimeType>Manual</DateTimeType><UTCDateTime>` +
        `<Time><Hour>${d.getUTCHours()}</Hour><Minute>${d.getUTCMinutes()}</Minute>` +
        `<Second>${d.getUTCSeconds()}</Second></Time>` +
        `<Date><Year>${d.getUTCFullYear()}</Year><Month>${d.getUTCMonth() + 1}</Month>` +
        `<Day>${d.getUTCDate()}</Day></Date></UTCDateTime></SystemDateAndTime>` +
        `</GetSystemDateAndTimeResponse>`);
    }
    default:
      return envelope('');
  }
}

http.createServer((req, res) => {
  if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
  let body = '';
  req.on('data', (c) => {
    body += c;
    if (body.length > 1e6) req.destroy();
  });
  req.on('end', () => {
    const op = detectOp(body);
    console.log(`[onvif] ${req.url} -> ${op}`);
    res.writeHead(200, { 'Content-Type': 'application/soap+xml; charset=utf-8' });
    res.end(responseFor(op));
  });
}).listen(ONVIF_PORT, '0.0.0.0', () => {
  console.log(`[onvif] device service at ${DEVICE_SERVICE}`);
});
ONVIF_EOF

echo "Starting virtual ONVIF device (HTTP on :${ONVIF_PORT})..."
CAMERA_HOST="$CAMERA_HOST" ONVIF_PORT="$ONVIF_PORT" RTSP_PORT="$RTSP_PORT" \
  RTSP_PATH="$RTSP_PATH" CAMERA_NAME="$CAMERA_NAME" VIDEO_SIZE="$VIDEO_SIZE" \
  ONVIF_ENCODING="$ONVIF_ENCODING" \
  node "$ONVIF_JS" > "$WORKDIR/onvif.log" 2>&1 &
PIDS+=($!)
wait_for_port "$ONVIF_PORT" || true

# --- Ready -------------------------------------------------------------------

cat <<EOF

============================================================
  Fake camera is running.  Press Ctrl-C to stop.
------------------------------------------------------------
  Video : ${VIDEO_SIZE} @${FPS}fps ${ONVIF_ENCODING}, ticking-clock test card
  Audio : sweeping two-voice siren (AAC) — never steady, so noise
          cancellation can't gate it out

  RTSP — LemurCam › add a camera › RTSP URL:
      ${PUBLISH_URL/127.0.0.1/$CAMERA_HOST}

  ONVIF — LemurCam › add a camera › Discover:
      Name   : ${CAMERA_NAME}
      Device : http://${CAMERA_HOST}:${ONVIF_PORT}/onvif/device_service
      (no username/password required)

  Verify the LemurCam Microphone (raw capture bypasses app noise cancellation):
      ffmpeg -f avfoundation -i ":LemurCam Microphone" -t 5 /tmp/mic.wav && afplay /tmp/mic.wav
      • full 5s of sweeping tone  -> the mic pipeline works end-to-end
      • flattens after ~1s here too -> a real pipeline bug (not noise cancellation)

  Logs   : ${WORKDIR}
  Note   : macOS may prompt to allow incoming connections — click Allow.
============================================================
EOF

wait
