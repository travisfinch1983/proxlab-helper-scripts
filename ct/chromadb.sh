#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/travisfinch1983/proxlab-helper-scripts/main/misc/proxlab.func)
# Copyright (c) 2026 ProxLab
# Author: Claude Code (Anthropic)
# License: MIT
# Source: https://github.com/chroma-core/chroma

APP="ChromaDB"
var_tags="${var_tags:-database;vector;ai}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /opt/chromadb/venv/bin/chroma ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  CURRENT_VERSION=$(cat /opt/chromadb_version.txt 2>/dev/null || echo "unknown")
  LATEST_VERSION=$(curl -fsSL "https://pypi.org/pypi/chromadb/json" 2>/dev/null | grep -oP '"version":\s*"\K[^"]+' | head -1)

  if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
    msg_ok "Already on latest version (${CURRENT_VERSION})"
    exit
  fi

  msg_info "Updating ChromaDB from v${CURRENT_VERSION} to v${LATEST_VERSION}"
  /opt/chromadb/venv/bin/pip install --upgrade chromadb 2>&1
  echo "${LATEST_VERSION}" >/opt/chromadb_version.txt
  systemctl restart chromadb
  msg_ok "Updated ChromaDB to v${LATEST_VERSION}"

  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000/api/v2/heartbeat${CL}"
echo ""
echo -e "${INFO}${YW} Useful files inside the container:${CL}"
echo -e "${TAB}/opt/chromadb/venv/              — Python venv"
echo -e "${TAB}/var/lib/chroma/                 — Data directory"
echo -e "${TAB}/etc/chromadb/config.yaml        — Server configuration"
echo ""
echo -e "${INFO}${YW} API endpoints:${CL}"
echo -e "${TAB}REST: ${BGN}http://${IP}:8000${CL}"
echo -e "${TAB}Docs: ${BGN}http://${IP}:8000/docs${CL} (Swagger UI)"

stty sane 2>/dev/null || true
