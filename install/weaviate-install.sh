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
WEAVIATE_OLLAMA_MODEL="${WEAVIATE_OLLAMA_MODEL:-}"
WEAVIATE_OPENAI_BASE_URL="${WEAVIATE_OPENAI_BASE_URL:-}"
WEAVIATE_OPENAI_MODEL="${WEAVIATE_OPENAI_MODEL:-}"
WEAVIATE_OPENAI_APIKEY="${WEAVIATE_OPENAI_APIKEY:-}"
WEAVIATE_PORT="${WEAVIATE_PORT:-8080}"
WEAVIATE_GRPC_PORT="${WEAVIATE_GRPC_PORT:-50051}"

# ─── Interactive module selection (only if WEAVIATE_MODULES not pre-set) ───
if [[ -z "${WEAVIATE_MODULES:-}" ]]; then
  echo -e "\n${INFO}${YW} Weaviate Module Selection${CL}\n"
  echo -e "  Available vectorizer/generative modules:\n"
  echo -e "  ${BL}Ollama modules${CL} — connect to an Ollama instance for embeddings/generation"
  echo -e "  ${BL}OpenAI-compatible modules${CL} — connect to any OpenAI-compatible API"
  echo -e "    (vLLM, KoboldCpp, LiteLLM, text-generation-inference, etc.)"
  echo -e ""

  SELECTED_MODULES=""

  # --- Ollama modules ---
  read -e -r -p "  Enable text2vec-ollama? (embeddings via Ollama) [Y/n]: " ans
  if [[ ! "$ans" =~ ^[Nn]$ ]]; then
    SELECTED_MODULES="text2vec-ollama"
  fi

  read -e -r -p "  Enable generative-ollama? (generation via Ollama) [Y/n]: " ans
  if [[ ! "$ans" =~ ^[Nn]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}generative-ollama"
  fi

  # --- OpenAI-compatible modules ---
  read -e -r -p "  Enable text2vec-openai? (embeddings via OpenAI-compatible API) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}text2vec-openai"
  fi

  read -e -r -p "  Enable generative-openai? (generation via OpenAI-compatible API) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}generative-openai"
  fi

  # --- Native inference modules (no Docker required) ---
  echo -e "\n  ${BL}Native inference modules${CL} — run locally, models downloaded from HuggingFace"
  echo -e "  (These replace the Docker-based modules with native Python services)\n"

  read -e -r -p "  Enable text2vec-transformers? (local sentence-transformers) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}text2vec-transformers"
  fi

  read -e -r -p "  Enable text2vec-model2vec? (lightweight static embeddings) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}text2vec-model2vec"
  fi

  read -e -r -p "  Enable multi2vec-clip? (multimodal text+image embeddings) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}multi2vec-clip"
  fi

  read -e -r -p "  Enable reranker-transformers? (cross-encoder reranking) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    [[ -n "$SELECTED_MODULES" ]] && SELECTED_MODULES="${SELECTED_MODULES},"
    SELECTED_MODULES="${SELECTED_MODULES}reranker-transformers"
  fi

  WEAVIATE_MODULES="${SELECTED_MODULES:-text2vec-ollama,generative-ollama}"
  echo -e "\n  ${GN}Selected modules:${CL} ${WEAVIATE_MODULES}\n"
fi

# ─── Helper: check if module is in the comma-separated list ───
has_module() { echo ",$WEAVIATE_MODULES," | grep -q ",$1,"; }

# ─── Helper: query endpoint for available models, present selection menu ───
# Usage: selected_model=$(select_model_from_endpoint "http://host:port" "ollama|openai" "embedding model")
# Returns: model name on stdout, or empty string if user chose manual entry
select_model_from_endpoint() {
  # Disable strict error handling inside this function — network queries
  # and parsing can fail in many non-fatal ways
  set +euo pipefail

  local base_url="$1"
  local api_type="$2"   # "ollama" or "openai"
  local purpose="$3"    # display text like "embedding model"
  local models=()
  local json_response=""
  local parsed_models=""

  echo -e "\n  ${INFO}${YW} Querying ${base_url} for available models...${CL}" >&2

  if [[ "$api_type" == "ollama" ]]; then
    json_response=$(curl -sf --connect-timeout 5 "${base_url}/api/tags" 2>/dev/null || true)
    if [[ -n "$json_response" ]]; then
      parsed_models=$(echo "$json_response" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 2>/dev/null || true)
    fi
  elif [[ "$api_type" == "openai" ]]; then
    local models_url="${base_url%/}"
    models_url="${models_url%/v1}/v1/models"
    json_response=$(curl -sf --connect-timeout 5 "$models_url" 2>/dev/null || true)
    if [[ -n "$json_response" ]]; then
      parsed_models=$(echo "$json_response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 2>/dev/null || true)
    fi
  fi

  # Build array from parsed output
  if [[ -n "$parsed_models" ]]; then
    while IFS= read -r model; do
      [[ -n "$model" ]] && models+=("$model")
    done <<< "$parsed_models"
  fi

  # Re-enable strict mode before returning
  set -euo pipefail

  if [[ ${#models[@]} -eq 0 ]]; then
    echo -e "  ${YW}Could not retrieve model list from endpoint${CL}" >&2
    echo ""
    return 0
  fi

  echo -e "\n  ${GN}Found ${#models[@]} model(s) available:${CL}\n" >&2
  local i=1
  for m in "${models[@]}"; do
    echo -e "  ${BL}${i})${CL} ${m}" >&2
    ((i++))
  done
  echo -e "  ${BL}${i})${CL} [Enter manually]" >&2
  echo "" >&2

  while true; do
    read -e -r -p "  Select ${purpose} [1-${i}]: " choice </dev/tty >&2
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= i )); then
      if (( choice == i )); then
        # User wants manual entry
        echo ""
        return 0
      fi
      local selected="${models[$((choice-1))]}"
      echo -e "\n  ${BL}Selected:${CL} ${selected}" >&2
      read -e -r -p "  Is this correct? [Y/n]: " confirm </dev/tty >&2
      if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        echo "$selected"
        return 0
      fi
    else
      echo -e "  ${RD}Invalid selection${CL}" >&2
    fi
  done
}

# ─── Interactive Ollama host (if using ollama modules and not pre-set) ───
if (has_module "text2vec-ollama" || has_module "generative-ollama") && [[ -z "${WEAVIATE_OLLAMA_HOST:-}" ]]; then
  while true; do
    read -e -r -p "  Ollama host URL [http://localhost:11434]: " ans
    WEAVIATE_OLLAMA_HOST="${ans:-http://localhost:11434}"
    echo ""
    echo -e "  ${BL}Ollama URL:${CL} ${WEAVIATE_OLLAMA_HOST}"
    read -e -r -p "  Is this correct? [Y/n]: " confirm
    [[ ! "$confirm" =~ ^[Nn]$ ]] && break
    echo ""
  done

  # Query Ollama for available models and let user select
  if has_module "text2vec-ollama" && [[ -z "${WEAVIATE_OLLAMA_MODEL:-}" ]]; then
    WEAVIATE_OLLAMA_MODEL=$(select_model_from_endpoint "$WEAVIATE_OLLAMA_HOST" "ollama" "embedding model")
    if [[ -z "${WEAVIATE_OLLAMA_MODEL:-}" ]]; then
      # Fallback to manual entry
      while true; do
        read -e -r -p "  Ollama embedding model name: " ans
        WEAVIATE_OLLAMA_MODEL="${ans}"
        if [[ -z "${WEAVIATE_OLLAMA_MODEL:-}" ]]; then
          echo -e "  ${RD}Model name cannot be empty${CL}"
          continue
        fi
        echo -e "  ${BL}Embedding model:${CL} ${WEAVIATE_OLLAMA_MODEL}"
        read -e -r -p "  Is this correct? [Y/n]: " confirm
        [[ ! "$confirm" =~ ^[Nn]$ ]] && break
        echo ""
      done
    fi
  fi
fi

# ─── Interactive OpenAI-compatible endpoint (if using openai modules and not pre-set) ───
if (has_module "text2vec-openai" || has_module "generative-openai") && [[ -z "${WEAVIATE_OPENAI_BASE_URL:-}" ]]; then
  echo -e "\n  ${INFO}${YW} OpenAI-compatible API Configuration${CL}"
  echo -e "  Point this at any OpenAI-compatible endpoint (vLLM, KoboldCpp, LiteLLM, etc.)\n"

  while true; do
    read -e -r -p "  API base URL (e.g. http://10.0.0.232:8000/v1): " ans
    WEAVIATE_OPENAI_BASE_URL="${ans}"
    if [[ -z "${WEAVIATE_OPENAI_BASE_URL:-}" ]]; then
      echo -e "  ${RD}URL cannot be empty${CL}"
      continue
    fi
    echo ""
    echo -e "  ${BL}API base URL:${CL} ${WEAVIATE_OPENAI_BASE_URL}"
    read -e -r -p "  Is this correct? [Y/n]: " confirm
    [[ ! "$confirm" =~ ^[Nn]$ ]] && break
    echo ""
  done

  # Query endpoint for available models and let user select
  if has_module "text2vec-openai" && [[ -z "${WEAVIATE_OPENAI_MODEL:-}" ]]; then
    WEAVIATE_OPENAI_MODEL=$(select_model_from_endpoint "$WEAVIATE_OPENAI_BASE_URL" "openai" "embedding model")
    if [[ -z "${WEAVIATE_OPENAI_MODEL:-}" ]]; then
      # Fallback to manual entry
      while true; do
        read -e -r -p "  Embedding model name (as served by your endpoint): " ans
        WEAVIATE_OPENAI_MODEL="${ans}"
        if [[ -z "${WEAVIATE_OPENAI_MODEL:-}" ]]; then
          echo -e "  ${RD}Model name cannot be empty${CL}"
          continue
        fi
        echo -e "  ${BL}Embedding model:${CL} ${WEAVIATE_OPENAI_MODEL}"
        read -e -r -p "  Is this correct? [Y/n]: " confirm
        [[ ! "$confirm" =~ ^[Nn]$ ]] && break
        echo ""
      done
    fi
  fi
fi

# ─── Native module model selection ───
WEAVIATE_TRANSFORMERS_HF_MODEL="${WEAVIATE_TRANSFORMERS_HF_MODEL:-}"
WEAVIATE_MODEL2VEC_HF_MODEL="${WEAVIATE_MODEL2VEC_HF_MODEL:-}"
WEAVIATE_CLIP_HF_MODEL="${WEAVIATE_CLIP_HF_MODEL:-}"
WEAVIATE_RERANKER_HF_MODEL="${WEAVIATE_RERANKER_HF_MODEL:-}"

if has_module "text2vec-transformers" && [[ -z "${WEAVIATE_TRANSFORMERS_HF_MODEL:-}" ]]; then
  echo -e "\n  ${INFO}${YW} Select text2vec-transformers model:${CL}"
  echo -e "  ${BL}1)${CL} all-MiniLM-L6-v2 (fast, 384d, English)"
  echo -e "  ${BL}2)${CL} paraphrase-multilingual-MiniLM-L12-v2 (384d, multilingual)"
  echo -e "  ${BL}3)${CL} all-mpnet-base-v2 (768d, best quality English)"
  echo -e "  ${BL}4)${CL} bge-base-en-v1.5 (768d, BAAI)"
  echo -e "  ${BL}5)${CL} [Enter HuggingFace model name manually]"
  while true; do
    read -e -r -p "  Select [1-5]: " choice
    case "$choice" in
      1) WEAVIATE_TRANSFORMERS_HF_MODEL="sentence-transformers/all-MiniLM-L6-v2"; break;;
      2) WEAVIATE_TRANSFORMERS_HF_MODEL="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"; break;;
      3) WEAVIATE_TRANSFORMERS_HF_MODEL="sentence-transformers/all-mpnet-base-v2"; break;;
      4) WEAVIATE_TRANSFORMERS_HF_MODEL="BAAI/bge-base-en-v1.5"; break;;
      5) read -e -r -p "  HuggingFace model name: " WEAVIATE_TRANSFORMERS_HF_MODEL; break;;
      *) echo -e "  ${RD}Invalid selection${CL}";;
    esac
  done
  echo -e "  ${GN}Selected:${CL} ${WEAVIATE_TRANSFORMERS_HF_MODEL}\n"
fi

if has_module "text2vec-model2vec" && [[ -z "${WEAVIATE_MODEL2VEC_HF_MODEL:-}" ]]; then
  echo -e "\n  ${INFO}${YW} Select text2vec-model2vec model:${CL}"
  echo -e "  ${BL}1)${CL} potion-base-8M (fast, 256d)"
  echo -e "  ${BL}2)${CL} potion-base-32M (better quality, 256d)"
  echo -e "  ${BL}3)${CL} potion-multilingual-128M (multilingual)"
  echo -e "  ${BL}4)${CL} [Enter HuggingFace model name manually]"
  while true; do
    read -e -r -p "  Select [1-4]: " choice
    case "$choice" in
      1) WEAVIATE_MODEL2VEC_HF_MODEL="minishlab/potion-base-8M"; break;;
      2) WEAVIATE_MODEL2VEC_HF_MODEL="minishlab/potion-base-32M"; break;;
      3) WEAVIATE_MODEL2VEC_HF_MODEL="minishlab/potion-multilingual-128M"; break;;
      4) read -e -r -p "  HuggingFace model name: " WEAVIATE_MODEL2VEC_HF_MODEL; break;;
      *) echo -e "  ${RD}Invalid selection${CL}";;
    esac
  done
  echo -e "  ${GN}Selected:${CL} ${WEAVIATE_MODEL2VEC_HF_MODEL}\n"
fi

if has_module "multi2vec-clip" && [[ -z "${WEAVIATE_CLIP_HF_MODEL:-}" ]]; then
  echo -e "\n  ${INFO}${YW} Select multi2vec-clip model:${CL}"
  echo -e "  ${BL}1)${CL} clip-ViT-B-32 (fast, 512d)"
  echo -e "  ${BL}2)${CL} clip-ViT-B-32-multilingual-v1 (multilingual, 512d)"
  echo -e "  ${BL}3)${CL} clip-ViT-L-14 (higher quality, 768d)"
  echo -e "  ${BL}4)${CL} [Enter HuggingFace model name manually]"
  while true; do
    read -e -r -p "  Select [1-4]: " choice
    case "$choice" in
      1) WEAVIATE_CLIP_HF_MODEL="sentence-transformers/clip-ViT-B-32"; break;;
      2) WEAVIATE_CLIP_HF_MODEL="sentence-transformers/clip-ViT-B-32-multilingual-v1"; break;;
      3) WEAVIATE_CLIP_HF_MODEL="sentence-transformers/clip-ViT-L-14"; break;;
      4) read -e -r -p "  HuggingFace model name: " WEAVIATE_CLIP_HF_MODEL; break;;
      *) echo -e "  ${RD}Invalid selection${CL}";;
    esac
  done
  echo -e "  ${GN}Selected:${CL} ${WEAVIATE_CLIP_HF_MODEL}\n"
fi

if has_module "reranker-transformers" && [[ -z "${WEAVIATE_RERANKER_HF_MODEL:-}" ]]; then
  echo -e "\n  ${INFO}${YW} Select reranker model:${CL}"
  echo -e "  ${BL}1)${CL} ms-marco-MiniLM-L-6-v2 (fast, good quality)"
  echo -e "  ${BL}2)${CL} ms-marco-TinyBERT-L-2-v2 (fastest, smaller)"
  echo -e "  ${BL}3)${CL} ms-marco-MiniLM-L-12-v2 (best quality, slower)"
  echo -e "  ${BL}4)${CL} [Enter HuggingFace model name manually]"
  while true; do
    read -e -r -p "  Select [1-4]: " choice
    case "$choice" in
      1) WEAVIATE_RERANKER_HF_MODEL="cross-encoder/ms-marco-MiniLM-L-6-v2"; break;;
      2) WEAVIATE_RERANKER_HF_MODEL="cross-encoder/ms-marco-TinyBERT-L-2-v2"; break;;
      3) WEAVIATE_RERANKER_HF_MODEL="cross-encoder/ms-marco-MiniLM-L-12-v2"; break;;
      4) read -e -r -p "  HuggingFace model name: " WEAVIATE_RERANKER_HF_MODEL; break;;
      *) echo -e "  ${RD}Invalid selection${CL}";;
    esac
  done
  echo -e "  ${GN}Selected:${CL} ${WEAVIATE_RERANKER_HF_MODEL}\n"
fi

# ─── Interactive auth (if not pre-set) ───
if [[ "$WEAVIATE_AUTH_ENABLED" != "true" ]]; then
  read -e -r -p "  Enable API key authentication? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    WEAVIATE_AUTH_ENABLED="true"
  fi
fi

# ─── Check if any native inference modules are selected ───
NEED_NATIVE_INFERENCE=false
for mod in text2vec-transformers text2vec-model2vec multi2vec-clip reranker-transformers; do
  if has_module "$mod"; then
    NEED_NATIVE_INFERENCE=true
    break
  fi
done

# ─── Dependencies ───
msg_info "Installing Dependencies"
$STD apt-get install -y curl wget git build-essential ca-certificates gnupg
msg_ok "Installed Dependencies"

# ─── Install Go (version matched to Weaviate's requirements) ───
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
msg_info "Cleaning Up Build Artifacts"
go clean -cache -modcache 2>/dev/null || true
rm -rf /root/go /root/.cache/go-build 2>/dev/null || true
msg_ok "Cleaned Up Build Artifacts"

msg_ok "Built Weaviate v${WEAVIATE_VERSION}"

# ─── Create Directories ───
mkdir -p /var/lib/weaviate /etc/weaviate

# ─── Install Native Inference Services ───
# Each service gets its own Python venv and systemd unit.
# They are drop-in compatible with Weaviate's Docker inference containers.
PROXLAB_SCRIPTS_URL="${PROXLAB_SCRIPTS_URL:-https://raw.githubusercontent.com/travisfinch1983/proxlab-helper-scripts/main}"
INFERENCE_PORT=9090

if [[ "$NEED_NATIVE_INFERENCE" == "true" ]]; then
  msg_info "Installing Python for Native Inference Services"
  $STD apt-get install -y python3 python3-venv python3-pip
  msg_ok "Installed Python"
fi

if has_module "text2vec-transformers"; then
  T2V_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  msg_info "Setting Up text2vec-transformers Service (port ${T2V_PORT})"
  mkdir -p /opt/weaviate-inference/transformers/models
  curl -fsSL "${PROXLAB_SCRIPTS_URL}/inference/t2v-transformers.py" -o /opt/weaviate-inference/transformers/server.py
  python3 -m venv /opt/weaviate-inference/transformers/venv
  $STD /opt/weaviate-inference/transformers/venv/bin/pip install --no-cache-dir \
    torch --index-url https://download.pytorch.org/whl/cpu
  $STD /opt/weaviate-inference/transformers/venv/bin/pip install --no-cache-dir \
    sentence-transformers fastapi uvicorn

  # Pre-download the model
  msg_info "Downloading Model: ${WEAVIATE_TRANSFORMERS_HF_MODEL}"
  /opt/weaviate-inference/transformers/venv/bin/python3 -c "
from sentence_transformers import SentenceTransformer
m = SentenceTransformer('${WEAVIATE_TRANSFORMERS_HF_MODEL}')
m.save('/opt/weaviate-inference/transformers/models/model')
print(f'Downloaded — dim={m.get_sentence_embedding_dimension()}')
"
  msg_ok "Downloaded Model: ${WEAVIATE_TRANSFORMERS_HF_MODEL}"

  cat >/etc/systemd/system/weaviate-t2v-transformers.service <<EOF
[Unit]
Description=Weaviate text2vec-transformers Inference (ProxLab native)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MODEL_NAME=${WEAVIATE_TRANSFORMERS_HF_MODEL}
Environment=MODEL_PATH=/opt/weaviate-inference/transformers/models/model
Environment=PORT=${T2V_PORT}
ExecStart=/opt/weaviate-inference/transformers/venv/bin/python3 /opt/weaviate-inference/transformers/server.py
WorkingDirectory=/opt/weaviate-inference/transformers
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable -q --now weaviate-t2v-transformers
  msg_ok "Started text2vec-transformers on Port ${T2V_PORT}"
fi

if has_module "text2vec-model2vec"; then
  M2V_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  msg_info "Setting Up text2vec-model2vec Service (port ${M2V_PORT})"
  mkdir -p /opt/weaviate-inference/model2vec/models
  curl -fsSL "${PROXLAB_SCRIPTS_URL}/inference/t2v-model2vec.py" -o /opt/weaviate-inference/model2vec/server.py
  python3 -m venv /opt/weaviate-inference/model2vec/venv
  $STD /opt/weaviate-inference/model2vec/venv/bin/pip install --no-cache-dir \
    model2vec fastapi uvicorn

  msg_info "Downloading Model: ${WEAVIATE_MODEL2VEC_HF_MODEL}"
  /opt/weaviate-inference/model2vec/venv/bin/python3 -c "
from model2vec import StaticModel
m = StaticModel.from_pretrained('${WEAVIATE_MODEL2VEC_HF_MODEL}')
m.save_pretrained('/opt/weaviate-inference/model2vec/models/model')
print('Downloaded')
"
  msg_ok "Downloaded Model: ${WEAVIATE_MODEL2VEC_HF_MODEL}"

  cat >/etc/systemd/system/weaviate-t2v-model2vec.service <<EOF
[Unit]
Description=Weaviate text2vec-model2vec Inference (ProxLab native)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MODEL_NAME=${WEAVIATE_MODEL2VEC_HF_MODEL}
Environment=MODEL_PATH=/opt/weaviate-inference/model2vec/models/model
Environment=PORT=${M2V_PORT}
ExecStart=/opt/weaviate-inference/model2vec/venv/bin/python3 /opt/weaviate-inference/model2vec/server.py
WorkingDirectory=/opt/weaviate-inference/model2vec
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable -q --now weaviate-t2v-model2vec
  msg_ok "Started text2vec-model2vec on Port ${M2V_PORT}"
fi

if has_module "multi2vec-clip"; then
  CLIP_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  msg_info "Setting Up multi2vec-clip Service (port ${CLIP_PORT})"
  mkdir -p /opt/weaviate-inference/clip/models
  curl -fsSL "${PROXLAB_SCRIPTS_URL}/inference/multi2vec-clip.py" -o /opt/weaviate-inference/clip/server.py
  python3 -m venv /opt/weaviate-inference/clip/venv
  $STD /opt/weaviate-inference/clip/venv/bin/pip install --no-cache-dir \
    torch --index-url https://download.pytorch.org/whl/cpu
  $STD /opt/weaviate-inference/clip/venv/bin/pip install --no-cache-dir \
    sentence-transformers fastapi uvicorn Pillow

  msg_info "Downloading Model: ${WEAVIATE_CLIP_HF_MODEL}"
  /opt/weaviate-inference/clip/venv/bin/python3 -c "
from sentence_transformers import SentenceTransformer
m = SentenceTransformer('${WEAVIATE_CLIP_HF_MODEL}')
m.save('/opt/weaviate-inference/clip/models/model')
print(f'Downloaded — dim={m.get_sentence_embedding_dimension()}')
"
  msg_ok "Downloaded Model: ${WEAVIATE_CLIP_HF_MODEL}"

  cat >/etc/systemd/system/weaviate-multi2vec-clip.service <<EOF
[Unit]
Description=Weaviate multi2vec-clip Inference (ProxLab native)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MODEL_NAME=${WEAVIATE_CLIP_HF_MODEL}
Environment=MODEL_PATH=/opt/weaviate-inference/clip/models/model
Environment=PORT=${CLIP_PORT}
ExecStart=/opt/weaviate-inference/clip/venv/bin/python3 /opt/weaviate-inference/clip/server.py
WorkingDirectory=/opt/weaviate-inference/clip
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable -q --now weaviate-multi2vec-clip
  msg_ok "Started multi2vec-clip on Port ${CLIP_PORT}"
fi

if has_module "reranker-transformers"; then
  RR_PORT=$INFERENCE_PORT
  INFERENCE_PORT=$((INFERENCE_PORT + 1))
  msg_info "Setting Up reranker-transformers Service (port ${RR_PORT})"
  mkdir -p /opt/weaviate-inference/reranker/models
  curl -fsSL "${PROXLAB_SCRIPTS_URL}/inference/reranker-transformers.py" -o /opt/weaviate-inference/reranker/server.py
  python3 -m venv /opt/weaviate-inference/reranker/venv
  $STD /opt/weaviate-inference/reranker/venv/bin/pip install --no-cache-dir \
    torch --index-url https://download.pytorch.org/whl/cpu
  $STD /opt/weaviate-inference/reranker/venv/bin/pip install --no-cache-dir \
    sentence-transformers fastapi uvicorn

  msg_info "Downloading Model: ${WEAVIATE_RERANKER_HF_MODEL}"
  /opt/weaviate-inference/reranker/venv/bin/python3 -c "
from sentence_transformers import CrossEncoder
m = CrossEncoder('${WEAVIATE_RERANKER_HF_MODEL}')
m.save_pretrained('/opt/weaviate-inference/reranker/models/model')
print('Downloaded')
"
  msg_ok "Downloaded Model: ${WEAVIATE_RERANKER_HF_MODEL}"

  cat >/etc/systemd/system/weaviate-reranker.service <<EOF
[Unit]
Description=Weaviate reranker-transformers Inference (ProxLab native)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MODEL_NAME=${WEAVIATE_RERANKER_HF_MODEL}
Environment=MODEL_PATH=/opt/weaviate-inference/reranker/models/model
Environment=PORT=${RR_PORT}
ExecStart=/opt/weaviate-inference/reranker/venv/bin/python3 /opt/weaviate-inference/reranker/server.py
WorkingDirectory=/opt/weaviate-inference/reranker
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable -q --now weaviate-reranker
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

# Determine default vectorizer
DEFAULT_VECTORIZER="none"
if has_module "text2vec-openai"; then
  DEFAULT_VECTORIZER="text2vec-openai"
elif has_module "text2vec-ollama"; then
  DEFAULT_VECTORIZER="text2vec-ollama"
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

# Append module-specific configuration
if has_module "text2vec-ollama" || has_module "generative-ollama"; then
  echo "OLLAMA_API_ENDPOINT=${WEAVIATE_OLLAMA_HOST}" >>/etc/default/weaviate
fi
if has_module "text2vec-openai" || has_module "generative-openai"; then
  echo "OPENAI_BASE_URL=${WEAVIATE_OPENAI_BASE_URL}" >>/etc/default/weaviate
  echo "OPENAI_APIKEY=${WEAVIATE_OPENAI_APIKEY:-proxlab-no-auth}" >>/etc/default/weaviate
fi
# Native inference service endpoints
[[ -n "${T2V_PORT:-}" ]] && echo "TRANSFORMERS_INFERENCE_API=http://localhost:${T2V_PORT}" >>/etc/default/weaviate
[[ -n "${M2V_PORT:-}" ]] && echo "MODEL2VEC_INFERENCE_API=http://localhost:${M2V_PORT}" >>/etc/default/weaviate
[[ -n "${CLIP_PORT:-}" ]] && echo "CLIP_INFERENCE_API=http://localhost:${CLIP_PORT}" >>/etc/default/weaviate
[[ -n "${RR_PORT:-}" ]] && echo "RERANKER_INFERENCE_API=http://localhost:${RR_PORT}" >>/etc/default/weaviate

# Save selected models to a reference file
# NOTE: Weaviate sets the model per-collection via the API, not globally.
# This file is for user reference — the model names are used when creating
# collections, not at service startup.
cat >/etc/weaviate/models.conf <<MODCONF
# Weaviate Model Configuration Reference
# These models were selected during installation.
# Use them when creating collections via the Weaviate API.
# This file is for reference only — it is NOT read by Weaviate at runtime.
OLLAMA_EMBEDDING_MODEL=${WEAVIATE_OLLAMA_MODEL:-not configured}
OPENAI_EMBEDDING_MODEL=${WEAVIATE_OPENAI_MODEL:-not configured}
OLLAMA_HOST=${WEAVIATE_OLLAMA_HOST:-not configured}
OPENAI_BASE_URL=${WEAVIATE_OPENAI_BASE_URL:-not configured}
TRANSFORMERS_MODEL=${WEAVIATE_TRANSFORMERS_HF_MODEL:-not configured}
MODEL2VEC_MODEL=${WEAVIATE_MODEL2VEC_HF_MODEL:-not configured}
CLIP_MODEL=${WEAVIATE_CLIP_HF_MODEL:-not configured}
RERANKER_MODEL=${WEAVIATE_RERANKER_HF_MODEL:-not configured}
MODCONF

msg_ok "Created Weaviate Environment File"

# ─── Systemd Service ───
msg_info "Creating Weaviate Service"
cat >/etc/systemd/system/weaviate.service <<EOF
[Unit]
Description=Weaviate Vector Database
After=network-online.target
Wants=network-online.target

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

# ─── Create Example Collection ───
if curl -sf "http://localhost:${WEAVIATE_PORT}/v1/meta" >/dev/null 2>&1; then
  msg_info "Creating Example Collection"

  # Determine vectorizer and module config for the example collection
  EXAMPLE_VECTORIZER="none"
  EXAMPLE_MODULE_CONFIG=""

  if has_module "text2vec-openai"; then
    EXAMPLE_VECTORIZER="text2vec-openai"
    EXAMPLE_MODULE_CONFIG="\"text2vec-openai\": {
        \"model\": \"${WEAVIATE_OPENAI_MODEL:-default}\",
        \"baseURL\": \"${WEAVIATE_OPENAI_BASE_URL:-}\",
        \"vectorizeClassName\": false
      }"
  elif has_module "text2vec-ollama"; then
    EXAMPLE_VECTORIZER="text2vec-ollama"
    EXAMPLE_MODULE_CONFIG="\"text2vec-ollama\": {
        \"model\": \"${WEAVIATE_OLLAMA_MODEL:-default}\",
        \"apiEndpoint\": \"${WEAVIATE_OLLAMA_HOST:-http://localhost:11434}\",
        \"vectorizeClassName\": false
      }"
  fi

  if [[ "$EXAMPLE_VECTORIZER" != "none" ]]; then
    curl -sf -X POST "http://localhost:${WEAVIATE_PORT}/v1/schema" \
      -H "Content-Type: application/json" \
      -d "{
        \"class\": \"Example_collection\",
        \"vectorizer\": \"${EXAMPLE_VECTORIZER}\",
        \"moduleConfig\": { ${EXAMPLE_MODULE_CONFIG} },
        \"properties\": [
          {
            \"name\": \"content\",
            \"dataType\": [\"text\"],
            \"moduleConfig\": {
              \"${EXAMPLE_VECTORIZER}\": {
                \"skip\": false,
                \"vectorizePropertyName\": false
              }
            }
          },
          {
            \"name\": \"source\",
            \"dataType\": [\"text\"],
            \"moduleConfig\": {
              \"${EXAMPLE_VECTORIZER}\": {
                \"skip\": true
              }
            }
          }
        ]
      }" >/dev/null 2>&1 && msg_ok "Created Example Collection (example_collection)" || msg_warn "Could not create example collection"
  else
    msg_info "Skipping example collection (no vectorizer module enabled)"
  fi

  # Save a reference script for creating additional collections
  cat >/etc/weaviate/create-collection-example.sh <<'REFSCRIPT'
#!/bin/bash
# Example: Create a new Weaviate collection
# Adjust the vectorizer, model, and endpoint to match your setup.
# See /etc/weaviate/models.conf for the models selected during install.
#
# IMPORTANT: Set vectorizeClassName to false when using OpenAI-compatible
# endpoints — some models produce degenerate embeddings when the class
# name is prepended to the input text.

WEAVIATE_URL="http://localhost:8080"

curl -X POST "${WEAVIATE_URL}/v1/schema" \
  -H "Content-Type: application/json" \
  -d '{
    "class": "MyCollection",
    "vectorizer": "text2vec-openai",
    "moduleConfig": {
      "text2vec-openai": {
        "model": "your-model-name",
        "baseURL": "http://your-endpoint:port/v1",
        "vectorizeClassName": false
      }
    },
    "properties": [
      {
        "name": "content",
        "dataType": ["text"],
        "moduleConfig": {
          "text2vec-openai": {
            "skip": false,
            "vectorizePropertyName": false
          }
        }
      },
      {
        "name": "metadata",
        "dataType": ["text"],
        "moduleConfig": {
          "text2vec-openai": {
            "skip": true
          }
        }
      }
    ]
  }'
REFSCRIPT
  chmod +x /etc/weaviate/create-collection-example.sh
fi

motd_ssh
customize
cleanup_lxc
