#!/usr/bin/env bash

# Copyright (c) 2026 ProxLab
# Author: Claude Code (Anthropic)
# License: MIT
# Source: https://github.com/milvus-io/milvus

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ─── Configuration via environment (ProxLab pre-fill) or interactive prompts ───
MILVUS_VERSION="${MILVUS_VERSION:-latest}"
MILVUS_DEPLOY_MODE="${MILVUS_DEPLOY_MODE:-standalone}"
MILVUS_AUTH_ENABLED="${MILVUS_AUTH_ENABLED:-false}"
MILVUS_DATA_DIR="${MILVUS_DATA_DIR:-/var/lib/milvus}"
MILVUS_PORT="${MILVUS_PORT:-19530}"

# ─── Interactive prompts (if not pre-set) ───
if [[ -z "${MILVUS_DEPLOY_MODE:-}" ]] || [[ "${MILVUS_DEPLOY_MODE}" == "standalone" ]]; then
  echo -e "\n${INFO}${YW} Milvus Deployment Mode${CL}\n"
  echo -e "  ${BL}1)${CL} Standalone"
  echo -e "     ${DGN}Full-featured, uses embedded etcd + local storage (RocksDB)${CL}"
  echo -e "     Best for: Production single-node deployments. Recommended for most users."
  echo -e ""
  echo -e "  ${BL}2)${CL} Lite"
  echo -e "     ${DGN}Minimal footprint, embedded everything, fewer features${CL}"
  echo -e "     Best for: Development, testing, or very resource-constrained environments."
  echo -e ""
  read -e -r -p "  Select deployment mode [1-2] (default: 1): " choice
  case "${choice:-1}" in
    2) MILVUS_DEPLOY_MODE="lite";;
    *) MILVUS_DEPLOY_MODE="standalone";;
  esac
  echo -e "  ${GN}Selected:${CL} ${MILVUS_DEPLOY_MODE}\n"
fi

if [[ "${MILVUS_AUTH_ENABLED:-}" != "true" ]]; then
  read -e -r -p "  Enable authentication? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    MILVUS_AUTH_ENABLED="true"
  fi
fi

# ─── Dependencies ───
msg_info "Installing Dependencies"
$STD apt-get install -y curl wget ca-certificates gnupg
msg_ok "Installed Dependencies"

# ─── Resolve Version and Download ───
# Milvus provides .deb packages for some releases. We prefer those since they
# include proper systemd service files, configs, and library paths.
# For releases without .deb, we fall back to the binary tarball or install script.

if [[ "$MILVUS_VERSION" == "latest" ]]; then
  msg_info "Finding Latest Milvus Release with .deb Package"

  # Search recent releases for one that has amd64.deb
  MILVUS_DEB_URL=""
  MILVUS_VERSION=""

  RELEASES_JSON=$(curl -fsSL "https://api.github.com/repos/milvus-io/milvus/releases?per_page=20" 2>/dev/null || echo "[]")

  # Parse without sort (nounset-safe)
  set +euo pipefail
  MILVUS_DEB_URL=$(echo "$RELEASES_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]*amd64\.deb' | head -1)
  set -euo pipefail

  if [[ -n "$MILVUS_DEB_URL" ]]; then
    MILVUS_VERSION=$(echo "$MILVUS_DEB_URL" | grep -oP 'milvus_\K[0-9]+\.[0-9]+\.[0-9]+')
    msg_ok "Found Milvus v${MILVUS_VERSION} (.deb)"
  else
    # No .deb found — get the latest tag and we'll try the install script
    MILVUS_VERSION=$(echo "$RELEASES_JSON" | grep -oP '"tag_name":\s*"v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    msg_warn "No .deb package found, will use install script for v${MILVUS_VERSION}"
  fi

  if [[ -z "$MILVUS_VERSION" ]]; then
    msg_error "Failed to resolve Milvus version"
    exit 1
  fi
fi

# Download and install
if [[ -n "${MILVUS_DEB_URL:-}" ]]; then
  msg_info "Downloading Milvus v${MILVUS_VERSION} (.deb package)"
  wget -q "$MILVUS_DEB_URL" -O /tmp/milvus.deb
  msg_ok "Downloaded Milvus v${MILVUS_VERSION}"

  msg_info "Installing Milvus Package"
  $STD dpkg -i /tmp/milvus.deb || $STD apt-get install -f -y
  rm /tmp/milvus.deb
  msg_ok "Installed Milvus v${MILVUS_VERSION}"
else
  # Fallback: try direct download URL patterns
  msg_info "Downloading Milvus v${MILVUS_VERSION}"
  DEB_URL="https://github.com/milvus-io/milvus/releases/download/v${MILVUS_VERSION}/milvus_${MILVUS_VERSION}-1_amd64.deb"
  if wget -q "$DEB_URL" -O /tmp/milvus.deb 2>/dev/null; then
    $STD dpkg -i /tmp/milvus.deb || $STD apt-get install -f -y
    rm /tmp/milvus.deb
    msg_ok "Installed Milvus v${MILVUS_VERSION} (.deb)"
  else
    # Last resort: official install script
    msg_warn "No .deb available, using official install script"
    curl -sfL https://raw.githubusercontent.com/milvus-io/milvus/master/scripts/install_milvus.sh | bash -s -- --prefix=/usr/local 2>&1 || {
      msg_error "All download methods failed for Milvus v${MILVUS_VERSION}"
      exit 1
    }
    msg_ok "Installed Milvus v${MILVUS_VERSION} (via install script)"
  fi
fi

echo "${MILVUS_VERSION}" >/opt/milvus_version.txt

# ─── Configure Milvus ───
msg_info "Configuring Milvus"
mkdir -p "${MILVUS_DATA_DIR}" /var/log/milvus

# The .deb package installs configs to /etc/milvus/configs/
# If they don't exist (install script method), create them
if [[ ! -d /etc/milvus/configs ]]; then
  mkdir -p /etc/milvus/configs
fi

# Main config — standalone mode uses embedded etcd + local storage
# No external etcd or MinIO needed
cat >/etc/milvus/configs/milvus.yaml <<EOF
# Milvus Standalone Configuration
# Installed by ProxLab Helper Scripts

etcd:
  endpoints:
    - localhost:2379
  use:
    embed: true
  data:
    data.dir: ${MILVUS_DATA_DIR}/etcd
  config:
    path: /etc/milvus/configs/embedEtcd.yaml

metastore:
  type: etcd

common:
  security:
    authorizationEnabled: ${MILVUS_AUTH_ENABLED}
  storageType: local

localStorage:
  path: ${MILVUS_DATA_DIR}/data

proxy:
  port: ${MILVUS_PORT}
  http:
    enabled: true

log:
  level: info
  file:
    rootPath: /var/log/milvus
EOF

# Embedded etcd config — CRITICAL: data-dir must be absolute path
# Without this, etcd uses a relative path that changes with CWD,
# causing leader election panics on restart
cat >/etc/milvus/configs/embedEtcd.yaml <<EOF
listen-client-urls: http://0.0.0.0:2379
advertise-client-urls: http://127.0.0.1:2379
listen-peer-urls: http://0.0.0.0:2380
initial-advertise-peer-urls: http://127.0.0.1:2380
initial-cluster: default=http://127.0.0.1:2380
data-dir: ${MILVUS_DATA_DIR}/etcd
auto-compaction-mode: revision
auto-compaction-retention: "1000"
quota-backend-bytes: 4294967296
snapshot-count: 50000
EOF

msg_ok "Configured Milvus"

# ─── Systemd Service ───
# The .deb may have installed a service file, but we override it to ensure
# proper WorkingDirectory, timeouts, and restart behavior
msg_info "Creating Milvus Service"
mkdir -p /etc/systemd/system/milvus.service.d

# Main service file (if not from .deb)
if [[ ! -f /usr/lib/systemd/system/milvus.service ]] && [[ ! -f /etc/systemd/system/milvus.service ]]; then
  cat >/etc/systemd/system/milvus.service <<EOF
[Unit]
Description=Milvus Standalone Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MILVUSCONF=/etc/milvus/configs/
Environment=DEPLOY_MODE=STANDALONE
ExecStart=/usr/bin/milvus run standalone
WorkingDirectory=${MILVUS_DATA_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
fi

# Hardening drop-in — applies whether service came from .deb or us
# Lessons learned from etcd corruption on LXC 158:
#   - WorkingDirectory MUST be set (embedded etcd uses relative paths)
#   - TimeoutStopSec must be long enough for etcd WAL flush
#   - Do NOT set MemoryMax below what Milvus detects as TotalMem
cat >/etc/systemd/system/milvus.service.d/proxlab.conf <<EOF
[Unit]
StartLimitBurst=5
StartLimitIntervalSec=120

[Service]
# Embedded etcd writes to relative path "default.etcd" — this ensures
# it persists at ${MILVUS_DATA_DIR}/default.etcd
WorkingDirectory=${MILVUS_DATA_DIR}

# Wait between restarts to avoid rapid crash loops
RestartSec=5

# Give etcd 60s to flush WAL on shutdown
# 15s was too short and caused WAL corruption on ZFS storage
TimeoutStopSec=60
KillMode=mixed

# Ensure /run/milvus exists for PID file
RuntimeDirectory=milvus
EOF

systemctl daemon-reload
systemctl enable -q --now milvus
msg_ok "Created Milvus Service"

# ─── Health Check ───
msg_info "Waiting for Milvus to Become Ready (may take 30-60 seconds)"
for i in $(seq 1 30); do
  if curl -sf -X POST "http://localhost:${MILVUS_PORT}/v2/vectordb/collections/list" \
    -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
    msg_ok "Milvus is Running on Port ${MILVUS_PORT}"
    break
  fi
  sleep 3
done

if ! curl -sf -X POST "http://localhost:${MILVUS_PORT}/v2/vectordb/collections/list" \
  -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
  # Check if service is at least running
  if systemctl is-active --quiet milvus 2>/dev/null; then
    msg_warn "Milvus service is running but API not responding yet — it may need more time to initialize"
  else
    msg_error "Milvus failed to start"
    journalctl -u milvus --no-pager -n 20
  fi
fi

motd_ssh
customize
cleanup_lxc
