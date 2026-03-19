#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/travisfinch1983/proxlab-helper-scripts/main/misc/proxlab.func)
# Copyright (c) 2026 ProxLab
# Author: Claude Code (Anthropic)
# License: MIT
# Source: https://github.com/weaviate/weaviate

APP="Weaviate"
var_tags="${var_tags:-database;vector;ai}"
var_cpu="${var_cpu:-2}"
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
  if [[ ! -f /usr/local/bin/weaviate ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  CURRENT_VERSION=$(weaviate --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || cat /opt/weaviate_version.txt 2>/dev/null || echo "unknown")
  LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/weaviate/weaviate/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')

  if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
    msg_ok "Already on latest version (${CURRENT_VERSION})"
    exit
  fi

  msg_info "Updating Weaviate from v${CURRENT_VERSION} to v${LATEST_VERSION}"

  msg_info "Installing Go build tools"
  GO_VERSION="1.23.6"
  if [[ ! -f /usr/local/go/bin/go ]] || ! /usr/local/go/bin/go version | grep -q "${GO_VERSION}"; then
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
  fi
  export PATH="/usr/local/go/bin:/root/go/bin:$PATH"
  export GOPATH="/root/go"
  msg_ok "Go ready"

  msg_info "Building Weaviate v${LATEST_VERSION} from source"
  rm -rf /opt/weaviate-src
  cd /opt
  git clone --depth 1 --branch "v${LATEST_VERSION}" https://github.com/weaviate/weaviate.git weaviate-src
  cd weaviate-src
  CGO_ENABLED=1 go build -o /usr/local/bin/weaviate ./cmd/weaviate-server
  echo "${LATEST_VERSION}" >/opt/weaviate_version.txt
  cd /opt
  rm -rf /opt/weaviate-src
  msg_ok "Built Weaviate v${LATEST_VERSION}"

  msg_info "Restarting Weaviate"
  systemctl restart weaviate
  msg_ok "Weaviate restarted"

  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080/v1/meta${CL}"
echo ""
echo -e "${INFO}${YW} An example collection (example_collection) has been created${CL}"
echo -e "${TAB}with your selected vectorizer and model pre-configured."
echo ""
echo -e "${INFO}${YW} Useful files inside the container:${CL}"
echo -e "${TAB}/etc/default/weaviate${TAB3}— Environment config (modules, endpoints)"
echo -e "${TAB}/etc/weaviate/config.yaml${TAB3}— Weaviate server config"
echo -e "${TAB}/etc/weaviate/models.conf${TAB3}— Selected models reference"
echo -e "${TAB}/etc/weaviate/create-collection-example.sh — Template for new collections"

# Reset terminal to normal mode (whiptail leaves it in raw mode)
stty sane 2>/dev/null || true
