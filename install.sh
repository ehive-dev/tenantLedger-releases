#!/usr/bin/env bash
set -euo pipefail
umask 022

# tenantLedger Installer/Updater (DietPi / arm64)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ehive-dev/tenantLedger-releases/main/install.sh | sudo bash -s -- [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]

PRODUCT_NAME="tenantLedger"
APP_NAME="tenantledger"
UNIT="${APP_NAME}.service"
UNIT_BASE="${APP_NAME}"

REPO="${REPO:-ehive-dev/tenantLedger-releases}"
CHANNEL="stable"
TAG="${TAG:-}"
ARCH_REQ="arm64"
DPKG_PKG="${DPKG_PKG:-$APP_NAME}"
ENV_FILE="/etc/${APP_NAME}/.env"
DEFAULTS_FILE="/opt/${APP_NAME}/.defaults"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

need_tools(){
  command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }
  command -v jq >/dev/null || { apt-get update -y; apt-get install -y jq; }
  command -v ss >/dev/null 2>&1 || true
  command -v systemctl >/dev/null || { err "systemd/systemctl erforderlich."; exit 1; }
  command -v dpkg >/dev/null || { err "dpkg erforderlich."; exit 1; }
  command -v dpkg-deb >/dev/null || { err "dpkg-deb erforderlich."; exit 1; }
}

api(){
  local url="$1"
  if command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1; then
    gh api "${url#https://api.github.com/}"
    return
  fi
  local hdr=(-H "Accept: application/vnd.github+json")
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -fsSL "${hdr[@]}" "$url"
}

trim_one_line(){ tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]\+$//'; }

get_release_json(){
  if [[ -n "$TAG" ]]; then
    api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
  else
    api "https://api.github.com/repos/${REPO}/releases?per_page=25" \
    | jq -c 'if "'"${CHANNEL}"'"=="pre" then ([ .[] | select(.draft == false and .prerelease == true) ] | .[0]) else ([ .[] | select(.draft == false and .prerelease == false) ] | .[0]) end'
  fi
}

pick_deb_from_release(){
  jq -r --arg arch "$ARCH_REQ" --arg app "$APP_NAME" '
    .assets // [] | map(select(.name | test("^" + $app + "_.*_" + $arch + "\\.deb$"))) | .[0].browser_download_url // empty
  '
}

installed_version(){ dpkg-query -W -f='${Version}\n' "$DPKG_PKG" 2>/dev/null || true; }

get_port(){
  local p="${PORT:-3021}"
  if [[ -r "/etc/default/${APP_NAME}" ]]; then
    . "/etc/default/${APP_NAME}" || true
    p="${PORT:-$p}"
  fi
  echo "$p"
}

get_health_path(){
  local hp="${HEALTH_PATH:-/healthz}"
  if [[ -r "/etc/default/${APP_NAME}" ]]; then
    . "/etc/default/${APP_NAME}" || true
    hp="${HEALTH_PATH:-$hp}"
  fi
  echo "$hp"
}

wait_port(){
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 0
  for _ in {1..60}; do
    ss -ltn 2>/dev/null | grep -q ":${port} " && return 0
    sleep 0.5
  done
  return 1
}

wait_health(){
  local url="$1"
  for _ in {1..30}; do
    curl -fsS "$url" >/dev/null && return 0
    sleep 1
  done
  return 1
}

detect_exec(){
  if [[ -x "/usr/local/bin/${APP_NAME}" ]]; then
    echo "/usr/local/bin/${APP_NAME}"
  elif command -v "$APP_NAME" >/dev/null 2>&1; then
    command -v "$APP_NAME"
  elif command -v tenantLedger >/dev/null 2>&1; then
    command -v tenantLedger
  elif [[ -x "/opt/${APP_NAME}/bin/${APP_NAME}" ]]; then
    echo "/opt/${APP_NAME}/bin/${APP_NAME}"
  elif [[ -f "/opt/${APP_NAME}/app.js" ]]; then
    echo "/usr/bin/node /opt/${APP_NAME}/app.js"
  else
    echo "/usr/local/bin/${APP_NAME}"
  fi
}

ensure_env_file(){
  install -d -m 0755 "/etc/${APP_NAME}"
  if [[ ! -f "$ENV_FILE" && -f "$DEFAULTS_FILE" ]]; then
    cp -f "$DEFAULTS_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE" || true
    ok "Default-Konfiguration bereitgestellt: ${ENV_FILE}"
  fi
}

need_root
need_tools

ARCH_SYS="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [[ "$ARCH_SYS" != "$ARCH_REQ" ]]; then
  warn "Systemarchitektur '$ARCH_SYS', Release ist für '$ARCH_REQ'."
  exit 1
fi

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then
  info "Installiert: ${DPKG_PKG} ${OLD_VER}"
else
  info "Keine bestehende ${PRODUCT_NAME}-Installation gefunden."
fi

info "Ermittle Release aus ${REPO} (${CHANNEL}${TAG:+, tag=$TAG}) ..."
RELEASE_JSON="$(get_release_json)"
if [[ -z "$RELEASE_JSON" || "$RELEASE_JSON" == "null" ]]; then
  err "Keine passende Release gefunden."
  exit 1
fi

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
[[ -z "$TAG" ]] && TAG="$TAG_NAME"
VER_CLEAN="${TAG#v}"

DEB_URL_RAW="$(printf '%s' "$RELEASE_JSON" | pick_deb_from_release || true)"
DEB_URL="$(printf '%s' "$DEB_URL_RAW" | trim_one_line)"
if [[ -z "$DEB_URL" ]]; then
  err "Kein .deb Asset (${ARCH_REQ}) in Release ${TAG} gefunden."
  exit 1
fi

TMPDIR="$(mktemp -d -t tenantledger-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${APP_NAME}_${VER_CLEAN}_${ARCH_REQ}.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"
dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || { err "Ungültiges .deb"; exit 1; }

systemctl stop "$UNIT" || true

info "Installiere Paket ..."
set +e
dpkg -i "$DEB_FILE"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  warn "dpkg -i scheiterte, versuche apt --fix-broken"
  apt-get update -y
  apt-get -f install -y
  dpkg -i "$DEB_FILE"
fi
ok "Installiert: ${DPKG_PKG} ${VER_CLEAN}"

ensure_env_file

if [[ ! -f /etc/default/${APP_NAME} ]]; then
  install -D -m 0644 /dev/null /etc/default/${APP_NAME}
  {
    echo "PORT=${PORT:-3021}"
    echo "HEALTH_PATH=${HEALTH_PATH:-/healthz}"
  } >>/etc/default/${APP_NAME}
fi

UNIT_PATH="/etc/systemd/system/${UNIT}"
if ! systemctl list-unit-files | awk '{print $1}' | grep -qx "${UNIT}"; then
  EXEC_BIN="$(detect_exec)"
  install -D -m 0644 /dev/null "$UNIT_PATH"
  cat >"$UNIT_PATH" <<UNITFILE
[Unit]
Description=${PRODUCT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/${APP_NAME}
WorkingDirectory=/opt/${APP_NAME}
ExecStart=${EXEC_BIN}
Restart=always
RestartSec=3s
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
KillMode=process
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
UNITFILE
fi

install -d -m 0755 "/etc/systemd/system/${UNIT}.d"
cat >"/etc/systemd/system/${UNIT}.d/10-paths.conf" <<UNITDROP
[Service]
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
UNITDROP

systemctl daemon-reload
systemctl enable --now "$UNIT" || true
systemctl restart "$UNIT" || true

PORT="$(get_port)"
H_PATH="$(get_health_path)"
URL="http://127.0.0.1:${PORT}${H_PATH}"

info "Warte auf Port :${PORT} ..."
if ! wait_port "$PORT"; then
  err "Port ${PORT} lauscht nicht."
  journalctl -u "$UNIT" -n 200 --no-pager -o cat || true
  exit 1
fi

info "Prüfe Health ${URL} ..."
if ! wait_health "$URL"; then
  err "Health-Check fehlgeschlagen."
  journalctl -u "$UNIT" -n 200 --no-pager -o cat || true
  exit 1
fi

NEW_VER="$(installed_version || echo "$VER_CLEAN")"
ok "Fertig: ${PRODUCT_NAME} ${OLD_VER:+${OLD_VER} → }${NEW_VER} (healthy @ ${URL})"
