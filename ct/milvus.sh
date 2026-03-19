#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/travisfinch1983/proxlab-helper-scripts/main/misc/proxlab.func)
# Copyright (c) 2026 ProxLab
# Author: Claude Code (Anthropic)
# License: MIT
# Source: https://github.com/milvus-io/milvus

APP="Milvus"
var_tags="${var_tags:-database;vector;ai}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
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
  if [[ ! -f /usr/bin/milvus ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  CURRENT_VERSION=$(cat /opt/milvus_version.txt 2>/dev/null || milvus version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
  msg_info "Current version: ${CURRENT_VERSION}"

  # Find the latest release that has a .deb package
  LATEST_DEB_URL=$(curl -fsSL "https://api.github.com/repos/milvus-io/milvus/releases" 2>/dev/null | \
    grep -oP '"browser_download_url":\s*"\K[^"]*amd64\.deb' | head -1)

  if [[ -z "$LATEST_DEB_URL" ]]; then
    msg_ok "No newer .deb release found"
    exit
  fi

  LATEST_VERSION=$(echo "$LATEST_DEB_URL" | grep -oP 'milvus_\K[0-9]+\.[0-9]+\.[0-9]+')
  if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
    msg_ok "Already on latest version (${CURRENT_VERSION})"
    exit
  fi

  msg_info "Updating Milvus from v${CURRENT_VERSION} to v${LATEST_VERSION}"
  systemctl stop milvus 2>/dev/null || true
  wget -q "$LATEST_DEB_URL" -O /tmp/milvus.deb
  dpkg -i /tmp/milvus.deb
  rm /tmp/milvus.deb
  echo "${LATEST_VERSION}" >/opt/milvus_version.txt
  systemctl start milvus
  msg_ok "Updated Milvus to v${LATEST_VERSION}"

  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:19530${CL}"
echo ""
echo -e "${INFO}${YW} Useful files inside the container:${CL}"
echo -e "${TAB}/etc/milvus/configs/milvus.yaml    — Main configuration"
echo -e "${TAB}/etc/milvus/configs/embedEtcd.yaml  — Embedded etcd config"
echo -e "${TAB}/var/lib/milvus/                    — Data directory"
echo ""
echo -e "${INFO}${YW} API endpoints:${CL}"
echo -e "${TAB}gRPC: ${BGN}${IP}:19530${CL}"
echo -e "${TAB}REST: ${BGN}http://${IP}:19530/v2/vectordb/collections/list${CL}"

# Reset terminal
stty sane 2>/dev/null || true
