# ProxLab Helper Scripts

**One-click installer scripts for vector databases and AI services on Proxmox LXC containers.**

> **Disclaimer:** This project is **not affiliated with, endorsed by, or associated with** the [Proxmox Community Scripts](https://github.com/community-scripts/ProxmoxVE) project (community-scripts / tteck helper scripts). We are an independent project that builds on top of their excellent shared function libraries (`build.func`, `install.func`, `tools.func`, etc.) to provide additional installer scripts for services not yet available in their catalog.

## How It Works

These scripts follow the same two-phase architecture used by the Proxmox community scripts:

1. **`ct/<app>.sh`** — Runs on the Proxmox host. Handles container creation, resource allocation, and orchestration.
2. **`install/<app>-install.sh`** — Runs inside the newly created container. Installs and configures the application.

### The Shim (`misc/proxlab.func`)

Our `ct/` scripts source a small shim called `proxlab.func` instead of directly sourcing the community's `build.func`. Here's what it does:

1. **Sources the real `build.func`** from the community-scripts repo — all shared functions (container creation, networking, error handling, OS setup, etc.) come directly from the upstream project, unmodified.
2. **Redirects the install script URL** — When `build.func` tries to download the app-specific install script, the shim intercepts that request and redirects it to this repo instead of the community repo. This is the **only** modification made.

This means:
- All container creation logic, error handling, and OS setup comes from the trusted community-scripts project
- Only the app-specific install script (the part that installs Weaviate, Milvus, etc.) comes from this repo
- If the community project updates their shared functions, our scripts automatically benefit

### Why not just contribute upstream?

We plan to eventually. These scripts are being developed and tested here first. Once they're stable and battle-tested, we'll submit them as PRs to the community-scripts project. In the meantime, this repo lets us iterate quickly without waiting for upstream review cycles.

## Available Scripts

| Application | Type | Description |
|-------------|------|-------------|
| [Weaviate](ct/weaviate.sh) | Vector DB | Open-source vector database with built-in vectorizer modules |
| [Milvus](ct/milvus.sh) | Vector DB | Cloud-native distributed vector database for scalable similarity search |
| [ChromaDB](ct/chromadb.sh) | Vector DB | AI-native embedding database, simple Python-based setup |
| Qdrant | Vector DB | *Already available in [community-scripts](https://github.com/community-scripts/ProxmoxVE)* |

## Usage

### Quick Install (from Proxmox host shell)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/travisfinch1983/proxlab-helper-scripts/main/ct/weaviate.sh)"
```

This will:
1. Prompt you for container settings (CPU, RAM, disk, network, etc.)
2. Create a new LXC container on your Proxmox node
3. Install and configure the selected application
4. Display the access URL when complete

### Pre-filled Options

When run via [ProxLab-UI](https://github.com/travisfinch1983/proxlab), the install scripts accept environment variables to pre-fill interactive prompts. For example:

```bash
export WEAVIATE_VERSION="latest"
export WEAVIATE_MODULES="text2vec-ollama,generative-ollama"
export WEAVIATE_OLLAMA_HOST="http://10.0.0.163:11434"
```

If these variables are not set, the scripts fall back to interactive prompts — just like the community helper scripts.

## Project Structure

```
proxlab-helper-scripts/
  misc/
    proxlab.func          # Shim that hooks into community build.func
  ct/
    weaviate.sh           # Host-side: container creation + orchestration
  install/
    weaviate-install.sh   # Container-side: app installation + config
```

## Requirements

- Proxmox VE 8.x or later
- Internet access (scripts download dependencies during install)
- Sufficient resources for the selected application

## License

MIT

## Credits

- [Proxmox Community Scripts](https://github.com/community-scripts/ProxmoxVE) — for the excellent shared function libraries that make this possible
- [Weaviate](https://weaviate.io/) — open-source vector database
