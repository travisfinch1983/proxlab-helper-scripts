#!/usr/bin/env bash

# Copyright (c) 2026 ProxLab
# Author: Claude Code (Anthropic)
# License: MIT
# Source: https://github.com/chroma-core/chroma

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ─── Configuration via environment (ProxLab pre-fill) or interactive prompts ───
CHROMA_VERSION="${CHROMA_VERSION:-latest}"
CHROMA_PORT="${CHROMA_PORT:-8000}"
CHROMA_DATA_DIR="${CHROMA_DATA_DIR:-/var/lib/chroma}"
CHROMA_AUTH_ENABLED="${CHROMA_AUTH_ENABLED:-false}"
CHROMA_AUTH_TOKEN="${CHROMA_AUTH_TOKEN:-}"
CHROMA_CORS_ORIGINS="${CHROMA_CORS_ORIGINS:-*}"

# ─── Interactive prompts ───
if [[ "${CHROMA_AUTH_ENABLED:-}" != "true" ]]; then
  read -e -r -p "  Enable token authentication? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    CHROMA_AUTH_ENABLED="true"
    if [[ -z "${CHROMA_AUTH_TOKEN:-}" ]]; then
      # Generate a random token
      CHROMA_AUTH_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
      echo -e "  ${GN}Generated auth token:${CL} ${CHROMA_AUTH_TOKEN}"
      echo -e "  ${YW}Save this token — you'll need it to connect to ChromaDB${CL}"
    fi
  fi
fi

# ─── Dependencies ───
msg_info "Installing Dependencies"
$STD apt-get install -y python3 python3-venv python3-pip curl
msg_ok "Installed Dependencies"

# ─── Install ChromaDB ───
msg_info "Creating ChromaDB Virtual Environment"
mkdir -p /opt/chromadb
python3 -m venv /opt/chromadb/venv
msg_ok "Created Virtual Environment"

if [[ "$CHROMA_VERSION" == "latest" ]]; then
  msg_info "Installing ChromaDB (latest)"
  $STD /opt/chromadb/venv/bin/pip install --no-cache-dir chromadb
else
  msg_info "Installing ChromaDB v${CHROMA_VERSION}"
  $STD /opt/chromadb/venv/bin/pip install --no-cache-dir "chromadb==${CHROMA_VERSION}"
fi

# Get installed version
CHROMA_VERSION=$(/opt/chromadb/venv/bin/pip show chromadb 2>/dev/null | grep -oP 'Version: \K.*')
echo "${CHROMA_VERSION}" >/opt/chromadb_version.txt
msg_ok "Installed ChromaDB v${CHROMA_VERSION}"

# ─── Create Data Directory ───
mkdir -p "${CHROMA_DATA_DIR}"

# ─── Configuration File ───
msg_info "Creating ChromaDB Configuration"
mkdir -p /etc/chromadb

cat >/etc/chromadb/config.yaml <<EOF
# ChromaDB Server Configuration
# Installed by ProxLab Helper Scripts

persist_directory: ${CHROMA_DATA_DIR}
anonymized_telemetry: false

server:
  host: 0.0.0.0
  port: ${CHROMA_PORT}
  cors_allow_origins: ["${CHROMA_CORS_ORIGINS}"]
EOF

msg_ok "Created ChromaDB Configuration"

# ─── Systemd Service ───
msg_info "Creating ChromaDB Service"

# Build the ExecStart command
EXEC_CMD="/opt/chromadb/venv/bin/chroma run --host 0.0.0.0 --port ${CHROMA_PORT} --path ${CHROMA_DATA_DIR}"

# Build environment lines for auth
AUTH_ENV=""
if [[ "$CHROMA_AUTH_ENABLED" == "true" ]]; then
  AUTH_ENV="Environment=CHROMA_SERVER_AUTHN_PROVIDER=chromadb.auth.token_authn.TokenAuthenticationServerProvider
Environment=CHROMA_SERVER_AUTHN_CREDENTIALS=${CHROMA_AUTH_TOKEN}
Environment=CHROMA_AUTH_TOKEN_TRANSPORT_HEADER=Authorization"
fi

cat >/etc/systemd/system/chromadb.service <<EOF
[Unit]
Description=ChromaDB Vector Database
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${EXEC_CMD}
WorkingDirectory=${CHROMA_DATA_DIR}
${AUTH_ENV}
Environment=ANONYMIZED_TELEMETRY=False
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q --now chromadb
msg_ok "Created ChromaDB Service"

# ─── Save credentials if auth enabled ───
if [[ "$CHROMA_AUTH_ENABLED" == "true" ]]; then
  cat >/etc/chromadb/auth.conf <<EOF
# ChromaDB Authentication
# Use this token in the Authorization header:
#   Authorization: Bearer ${CHROMA_AUTH_TOKEN}
#
# Python client example:
#   import chromadb
#   client = chromadb.HttpClient(
#       host="localhost", port=${CHROMA_PORT},
#       headers={"Authorization": "Bearer ${CHROMA_AUTH_TOKEN}"}
#   )
CHROMA_AUTH_TOKEN=${CHROMA_AUTH_TOKEN}
EOF
  chmod 600 /etc/chromadb/auth.conf
fi

# ─── Health Check ───
msg_info "Waiting for ChromaDB to Become Ready"
for i in $(seq 1 20); do
  if curl -sf "http://localhost:${CHROMA_PORT}/api/v2/heartbeat" >/dev/null 2>&1; then
    msg_ok "ChromaDB is Running on Port ${CHROMA_PORT} (v${CHROMA_VERSION})"
    break
  fi
  sleep 2
done

if ! curl -sf "http://localhost:${CHROMA_PORT}/api/v2/heartbeat" >/dev/null 2>&1; then
  # Try v1 heartbeat (older versions)
  if curl -sf "http://localhost:${CHROMA_PORT}/api/v1/heartbeat" >/dev/null 2>&1; then
    msg_ok "ChromaDB is Running on Port ${CHROMA_PORT} (v${CHROMA_VERSION})"
  else
    msg_error "ChromaDB failed to start within 40 seconds"
    journalctl -u chromadb --no-pager -n 20
  fi
fi

motd_ssh
customize
cleanup_lxc
