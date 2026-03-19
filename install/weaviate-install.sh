#!/usr/bin/env bash

# Copyright (c) 2026 ProxLab
# Author: Claude Code (Anthropic)
# License: MIT
# Source: https://github.com/weaviate/weaviate

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ─── Configuration via environment (ProxLab pre-fill) or interactive prompts ───
# When run via ProxLab UI, these are set as WEAVIATE_* env vars.
# When run standalone via community scripts, they fall through to interactive prompts.

WEAVIATE_VERSION="${WEAVIATE_VERSION:-latest}"
WEAVIATE_MODULES="${WEAVIATE_MODULES:-}"
WEAVIATE_AUTH_ENABLED="${WEAVIATE_AUTH_ENABLED:-false}"
WEAVIATE_OLLAMA_HOST="${WEAVIATE_OLLAMA_HOST:-}"
WEAVIATE_TRANSFORMERS_MODEL="${WEAVIATE_TRANSFORMERS_MODEL:-sentence-transformers-paraphrase-multilingual-MiniLM-L12-v2}"
WEAVIATE_TRANSFORMERS_CUDA="${WEAVIATE_TRANSFORMERS_CUDA:-false}"
WEAVIATE_MODEL2VEC_MODEL="${WEAVIATE_MODEL2VEC_MODEL:-minishlab-potion-base-32M}"
WEAVIATE_CLIP_MODEL="${WEAVIATE_CLIP_MODEL:-sentence-transformers-clip-ViT-B-32-multilingual-v1}"
WEAVIATE_CLIP_CUDA="${WEAVIATE_CLIP_CUDA:-false}"
WEAVIATE_RERANKER_MODEL="${WEAVIATE_RERANKER_MODEL:-cross-encoder-ms-marco-MiniLM-L-6-v2}"
WEAVIATE_RERANKER_CUDA="${WEAVIATE_RERANKER_CUDA:-false}"
WEAVIATE_PORT="${WEAVIATE_PORT:-8080}"
WEAVIATE_GRPC_PORT="${WEAVIATE_GRPC_PORT:-50051}"

# ─── Interactive module selection (only if WEAVIATE_MODULES not pre-set) ───
if [[ -z "$WEAVIATE_MODULES" ]]; then
  echo -e "\n${INFO}${YW} Weaviate Module Selection${CL}\n"
  echo -e "  Available vectorizer/generative modules:\n"
  echo -e "  ${BL}1)${CL} text2vec-ollama      — Use Ollama for embeddings (recommended)"
  echo -e "  ${BL}2)${CL} generative-ollama    — Use Ollama for generative AI"
  echo -e "  ${BL}3)${CL} text2vec-transformers — Local transformer model (Docker)"
  echo -e "  ${BL}4)${CL} text2vec-model2vec    — Lightweight model2vec (Docker)"
  echo -e "  ${BL}5)${CL} multi2vec-clip        — CLIP multimodal embeddings (Docker)"
  echo -e "  ${BL}6)${CL} reranker-transformers — Cross-encoder reranking (Docker)"
  echo -e ""

  SELECTED_MODULES=""

  read -e -r -p "  Enable text2vec-ollama? [Y/n]: " ans
  if [[ ! "$ans" =~ ^[Nn]$ ]]; then
    SELECTED_MODULES="text2vec-ollama"
  fi

  read -e -r -p "  Enable generative-ollama? [Y/n]: " ans
  if [[ ! "$ans" =~ ^[Nn]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}generative-ollama"
  fi

  read -e -r -p "  Enable text2vec-transformers? (requires Docker) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}text2vec-transformers"
  fi

  read -e -r -p "  Enable text2vec-model2vec? (requires Docker) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}text2vec-model2vec"
  fi

  read -e -r -p "  Enable multi2vec-clip? (requires Docker) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}multi2vec-clip"
  fi

  read -e -r -p "  Enable reranker-transformers? (requires Docker) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}reranker-transformers"
  fi

  WEAVIATE_MODULES="${SELECTED_MODULES:-text2vec-ollama,generative-ollama}"
  echo -e "\n  ${GN}Selected modules:${CL} ${WEAVIATE_MODULES}\n"
fi

# ─── Interactive Ollama host (if using ollama modules and not pre-set) ───
has_module() { echo ",$WEAVIATE_MODULES," | grep -q ",$1,"; }

if (has_module "text2vec-ollama" || has_module "generative-ollama") && [[ -z "$WEAVIATE_OLLAMA_HOST" ]]; then
  read -e -r -p "  Ollama host URL [http://localhost:11434]: " ans
  WEAVIATE_OLLAMA_HOST="${ans:-http://localhost:11434}"
fi

# ─── Interactive auth (if not pre-set) ───
if [[ "$WEAVIATE_AUTH_ENABLED" != "true" ]]; then
  read -e -r -p "  Enable API key authentication? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    WEAVIATE_AUTH_ENABLED="true"
  fi
fi

# ─── Check if Docker-based inference modules are selected ───
NEED_DOCKER=false
for mod in text2vec-transformers text2vec-model2vec multi2vec-clip reranker-transformers; do
  if has_module "$mod"; then
    NEED_DOCKER=true
    break
  fi
done

# ─── Dependencies ───
msg_info "Installing Dependencies"
$STD apt-get install -y curl wget git build-essential ca-certificates gnupg
msg_ok "Installed Dependencies"

# ─── Docker CE (if needed for inference containers) ───
if [[ "$NEED_DOCKER" == "true" ]]; then
  msg_info "Installing Docker CE for Inference Containers"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
  $STD apt-get update
  $STD apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable -q --now docker
  msg_ok "Installed Docker CE"
fi

# ─── Install Go (version matched to Weaviate's requirements) ───
# We'll determine the exact Go version after cloning the source,
# but install a reasonable default first. If go.mod requires newer,
# we'll upgrade before building.
GO_VERSION="1.24.4"
msg_info "Installing Go ${GO_VERSION}"
wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/root/go"
export PATH="$GOPATH/bin:$PATH"
msg_ok "Installed Go ${GO_VERSION}"

# ─── Resolve Version ───
if [[ "$WEAVIATE_VERSION" == "latest" ]]; then
  msg_info "Resolving Latest Weaviate Version"
  WEAVIATE_VERSION=$(curl -fsSL https://api.github.com/repos/weaviate/weaviate/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
  if [[ -z "$WEAVIATE_VERSION" ]]; then
    msg_error "Failed to resolve latest Weaviate version"
    exit 1
  fi
  msg_ok "Resolved Weaviate v${WEAVIATE_VERSION}"
fi

# ─── Clone and Build ───
msg_info "Cloning Weaviate v${WEAVIATE_VERSION}"
cd /opt
$STD git clone --depth 1 --branch "v${WEAVIATE_VERSION}" https://github.com/weaviate/weaviate.git weaviate-src
msg_ok "Cloned Weaviate v${WEAVIATE_VERSION}"

# Check if the cloned source needs a newer Go version
cd /opt/weaviate-src
if [[ -f go.mod ]]; then
  REQUIRED_GO=$(grep -oP '^go \K[0-9]+\.[0-9]+' go.mod | head -1)
  INSTALLED_GO=$(/usr/local/go/bin/go version | grep -oP 'go\K[0-9]+\.[0-9]+')
  if [[ -n "$REQUIRED_GO" && -n "$INSTALLED_GO" ]]; then
    REQ_MAJOR=${REQUIRED_GO%%.*}
    REQ_MINOR=${REQUIRED_GO##*.}
    INST_MAJOR=${INSTALLED_GO%%.*}
    INST_MINOR=${INSTALLED_GO##*.}
    if (( REQ_MAJOR > INST_MAJOR || (REQ_MAJOR == INST_MAJOR && REQ_MINOR > INST_MINOR) )); then
      # Need a newer Go — fetch the latest patch for the required minor
      NEEDED_GO=$(curl -fsSL "https://go.dev/dl/?mode=json" | grep -oP '"version":"go\K'${REQUIRED_GO}'\.[0-9]+' | head -1)
      if [[ -n "$NEEDED_GO" ]]; then
        msg_info "Upgrading Go to ${NEEDED_GO} (Weaviate requires go${REQUIRED_GO}+)"
        rm -rf /usr/local/go
        wget -q "https://go.dev/dl/go${NEEDED_GO}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm /tmp/go.tar.gz
        msg_ok "Upgraded Go to ${NEEDED_GO}"
      fi
    fi
  fi
fi

msg_info "Building Weaviate from Source (this will take several minutes)"
CGO_ENABLED=1 go build -o /usr/local/bin/weaviate ./cmd/weaviate-server 2>&1
echo "${WEAVIATE_VERSION}" >/opt/weaviate_version.txt
cd /opt
rm -rf /opt/weaviate-src

# Clean up Go build cache and module cache to reclaim disk space
# The binary is compiled — we don't need these anymore
msg_info "Cleaning Up Build Artifacts"
go clean -cache -modcache 2>/dev/null || true
rm -rf /root/go /root/.cache/go-build 2>/dev/null || true
msg_ok "Cleaned Up Build Artifacts"

msg_ok "Built Weaviate v${WEAVIATE_VERSION}"

# ─── Create Directories ───
mkdir -p /var/lib/weaviate /etc/weaviate

# ─── Start Inference Containers ───
INFERENCE_PORT=9090

if has_module "text2vec-transformers"; then
  T2V_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  T2V_IMAGE="cr.weaviate.io/semitechnologies/transformers-inference:${WEAVIATE_TRANSFORMERS_MODEL}"
  DOCKER_ARGS="--name weaviate-t2v-transformers -d --restart always -p ${T2V_PORT}:8080"
  [[ "$WEAVIATE_TRANSFORMERS_CUDA" == "true" ]] && DOCKER_ARGS="$DOCKER_ARGS --gpus all -e ENABLE_CUDA=1"
  msg_info "Starting text2vec-transformers on Port ${T2V_PORT}"
  $STD docker pull "$T2V_IMAGE"
  $STD docker run $DOCKER_ARGS "$T2V_IMAGE"
  msg_ok "Started text2vec-transformers on Port ${T2V_PORT}"
fi

if has_module "text2vec-model2vec"; then
  M2V_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  M2V_IMAGE="cr.weaviate.io/semitechnologies/model2vec-inference:${WEAVIATE_MODEL2VEC_MODEL}"
  msg_info "Starting text2vec-model2vec on Port ${M2V_PORT}"
  $STD docker pull "$M2V_IMAGE"
  $STD docker run --name weaviate-model2vec -d --restart always -p ${M2V_PORT}:8080 "$M2V_IMAGE"
  msg_ok "Started text2vec-model2vec on Port ${M2V_PORT}"
fi

if has_module "multi2vec-clip"; then
  CLIP_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  CLIP_IMAGE="cr.weaviate.io/semitechnologies/multi2vec-clip:${WEAVIATE_CLIP_MODEL}"
  DOCKER_ARGS="--name weaviate-clip -d --restart always -p ${CLIP_PORT}:8080"
  [[ "$WEAVIATE_CLIP_CUDA" == "true" ]] && DOCKER_ARGS="$DOCKER_ARGS --gpus all -e ENABLE_CUDA=1"
  msg_info "Starting multi2vec-clip on Port ${CLIP_PORT}"
  $STD docker pull "$CLIP_IMAGE"
  $STD docker run $DOCKER_ARGS "$CLIP_IMAGE"
  msg_ok "Started multi2vec-clip on Port ${CLIP_PORT}"
fi

if has_module "reranker-transformers"; then
  RR_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  RR_IMAGE="cr.weaviate.io/semitechnologies/reranker-transformers:${WEAVIATE_RERANKER_MODEL}"
  DOCKER_ARGS="--name weaviate-reranker -d --restart always -p ${RR_PORT}:8080"
  [[ "$WEAVIATE_RERANKER_CUDA" == "true" ]] && DOCKER_ARGS="$DOCKER_ARGS --gpus all -e ENABLE_CUDA=1"
  msg_info "Starting reranker-transformers on Port ${RR_PORT}"
  $STD docker pull "$RR_IMAGE"
  $STD docker run $DOCKER_ARGS "$RR_IMAGE"
  msg_ok "Started reranker-transformers on Port ${RR_PORT}"
fi

# ─── Generate Config ───
msg_info "Creating Weaviate Configuration"
cat >/etc/weaviate/config.yaml <<EOF
---
persistence:
  data_path: /var/lib/weaviate

query_defaults:
  limit: 25

authentication:
  anonymous_access:
    enabled: $([ "$WEAVIATE_AUTH_ENABLED" = "true" ] && echo "false" || echo "true")
  apikey:
    enabled: ${WEAVIATE_AUTH_ENABLED}
    allowed_keys:
      - "proxlab-default-key"
    users:
      - "admin@proxlab.local"
EOF
msg_ok "Created Weaviate Configuration"

# ─── Environment file for systemd ───
msg_info "Creating Weaviate Environment File"
DEFAULT_VECTORIZER="none"
if has_module "text2vec-ollama"; then
  DEFAULT_VECTORIZER="text2vec-ollama"
elif has_module "text2vec-transformers"; then
  DEFAULT_VECTORIZER="text2vec-transformers"
elif has_module "text2vec-model2vec"; then
  DEFAULT_VECTORIZER="text2vec-model2vec"
fi

cat >/etc/default/weaviate <<EOF
PERSISTENCE_DATA_PATH=/var/lib/weaviate
ENABLE_MODULES=${WEAVIATE_MODULES}
DEFAULT_VECTORIZER_MODULE=${DEFAULT_VECTORIZER}
CLUSTER_HOSTNAME=node1
QUERY_DEFAULTS_LIMIT=25
AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=$([ "$WEAVIATE_AUTH_ENABLED" = "true" ] && echo "false" || echo "true")
AUTHENTICATION_APIKEY_ENABLED=${WEAVIATE_AUTH_ENABLED}
AUTHENTICATION_APIKEY_ALLOWED_KEYS=proxlab-default-key
AUTHENTICATION_APIKEY_USERS=admin@proxlab.local
EOF

# Append module-specific inference API endpoints
[[ -n "${T2V_PORT:-}" ]] && echo "TRANSFORMERS_INFERENCE_API=http://localhost:${T2V_PORT}" >>/etc/default/weaviate
[[ -n "${M2V_PORT:-}" ]] && echo "MODEL2VEC_INFERENCE_API=http://localhost:${M2V_PORT}" >>/etc/default/weaviate
[[ -n "${CLIP_PORT:-}" ]] && echo "CLIP_INFERENCE_API=http://localhost:${CLIP_PORT}" >>/etc/default/weaviate
[[ -n "${RR_PORT:-}" ]] && echo "RERANKER_INFERENCE_API=http://localhost:${RR_PORT}" >>/etc/default/weaviate
if has_module "text2vec-ollama" || has_module "generative-ollama"; then
  echo "OLLAMA_API_ENDPOINT=${WEAVIATE_OLLAMA_HOST}" >>/etc/default/weaviate
fi
msg_ok "Created Weaviate Environment File"

# ─── Systemd Service ───
msg_info "Creating Weaviate Service"
AFTER_LINE="After=network-online.target"
WANTS_LINE="Wants=network-online.target"
if [[ "$NEED_DOCKER" == "true" ]]; then
  AFTER_LINE="After=network-online.target docker.service"
  WANTS_LINE="Wants=network-online.target docker.service"
fi

cat >/etc/systemd/system/weaviate.service <<EOF
[Unit]
Description=Weaviate Vector Database
${AFTER_LINE}
${WANTS_LINE}

[Service]
Type=simple
User=root
EnvironmentFile=/etc/default/weaviate
ExecStart=/usr/local/bin/weaviate --host 0.0.0.0 --port ${WEAVIATE_PORT} --scheme http
WorkingDirectory=/var/lib/weaviate
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now weaviate
msg_ok "Created Weaviate Service"

# ─── Health Check ───
msg_info "Waiting for Weaviate to Become Ready"
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${WEAVIATE_PORT}/v1/meta" >/dev/null 2>&1; then
    ACTUAL_VERSION=$(curl -sf "http://localhost:${WEAVIATE_PORT}/v1/meta" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    msg_ok "Weaviate is Running on Port ${WEAVIATE_PORT} (v${ACTUAL_VERSION:-$WEAVIATE_VERSION})"
    break
  fi
  sleep 2
done

if ! curl -sf "http://localhost:${WEAVIATE_PORT}/v1/meta" >/dev/null 2>&1; then
  msg_error "Weaviate failed to start within 60 seconds"
  journalctl -u weaviate --no-pager -n 20
fi

motd_ssh
customize
cleanup_lxc
