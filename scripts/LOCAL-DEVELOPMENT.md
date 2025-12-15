# Local Development with Podman

This guide shows you how to run the Showroom AI Assistant locally using Podman containers.

## Prerequisites

- [Podman](https://podman.io/) installed
- [Node.js](https://nodejs.org/) installed (for Antora build)
- An OpenAI API key (or compatible LLM API key)
- Access to a Kubernetes/OpenShift cluster (logged in via `oc login` or `kubectl`)

## Quick Start

1. **Login to your Kubernetes/OpenShift cluster**
   ```bash
   oc login https://your-cluster-url
   # or
   kubectl config use-context your-context
   ```

2. **Set up your API key**

   Option A: Export as environment variable
   ```bash
   export OPENAI_API_KEY="your-api-key-here"
   ```

   Option B: Create `.env.yaml` from template
   ```bash
   cp .env.yaml.example .env.yaml
   # Edit .env.yaml and add your API key
   ```

3. **Start all services**
   ```bash
   ./scripts/run-local-podman.sh
   ```

   This script will:
   - Create a podman network for container communication
   - Build the Antora site and RAG-optimized content
   - Build the backend container image
   - Start LlamaStack container
   - Start Backend API container
   - Start Frontend HTTP server

3. **Access the application**
   - **Showroom Frontend**: http://localhost:8080
   - **Backend API**: http://localhost:8000
   - **Health Check**: http://localhost:8000/api/health

## Managing Services

### View Logs

```bash
# Backend logs
podman logs -f showroom-backend

# LlamaStack logs
podman logs -f showroom-llamastack

# MCP Server logs
podman logs -f showroom-mcp-server

# Frontend logs
podman logs -f showroom-frontend
```

### Stop All Services

```bash
# Option 1: Press Ctrl+C in the terminal running the script
# Option 2: Run the stop script
./scripts/stop-local-podman.sh
```

### Restart After Code Changes

**Backend changes:**
```bash
./scripts/stop-local-podman.sh
./scripts/run-local-podman.sh
```

**Frontend/Content changes:**
```bash
# Rebuild the Antora site
npx antora default-site.yml

# Restart just the frontend container
podman rm -f showroom-frontend
podman run -d \
    --name showroom-frontend \
    --network showroom-ai-network \
    -p 8080:80 \
    -v "$PWD/www:/usr/share/nginx/html:ro,z" \
    docker.io/nginx:alpine
```

## Architecture

The local setup runs four containers:

1. **LlamaStack** (`showroom-llamastack`)
   - Multi-agent orchestration system
   - Port: 8321 (internal)
   - Image: `llamastack/distribution-starter:0.3.2`
   - Startup: Waits for health check before starting other services

2. **MCP Kubernetes Server** (`showroom-mcp-server`)
   - Kubernetes tools via Model Context Protocol
   - Port: 3000 (internal)
   - Image: `node:20`
   - Mounts: `~/.kube` (read-only) for cluster access

3. **Backend API** (`showroom-backend`)
   - FastAPI service with RAG and MCP
   - Port: 8000 (exposed to host)
   - Built from: `Dockerfile.backend`

4. **Frontend** (`showroom-frontend`)
   - Static Antora-generated site
   - Port: 8080 (exposed to host)
   - Image: `nginx:alpine`

All containers communicate via the `showroom-ai-network` podman network.

## Troubleshooting

### LlamaStack taking too long to start

The LlamaStack container can take 1-2 minutes to initialize on first run. The script will wait up to 2 minutes and show progress dots. This is normal.

### Backend not starting

Check logs:
```bash
podman logs showroom-backend
```

Common issues:
- API key not set correctly
- LlamaStack not ready (the script should wait for it automatically)
- RAG content not built (run `npx antora default-site.yml`)

### Frontend shows empty agent list

This is expected when the backend is still initializing. Wait a few moments and refresh the page.

### MCP Server can't connect to Kubernetes

Make sure you're logged in to your cluster:
```bash
oc whoami  # Should show your username
# or
kubectl cluster-info  # Should show cluster info
```

If not logged in:
```bash
oc login https://your-cluster-url
```

The script mounts `~/.kube/config` into the MCP container automatically.

### Port already in use

Change the frontend port:
```bash
# Edit run-local-podman.sh and change FRONTEND_PORT=8080 to another port
# Or export before running:
export FRONTEND_PORT=9090
./scripts/run-local-podman.sh
```

### Permission denied on volumes

On SELinux systems, the `:z` flag is used for volume mounts. If you're not on SELinux:
```bash
# Edit run-local-podman.sh and remove `:z` from volume mounts
# Change: -v "$PWD/www:/usr/share/nginx/html:ro,z"
# To:     -v "$PWD/www:/usr/share/nginx/html:ro"
```

## Development Tips

- The backend hot-reloads are not enabled. Restart the backend container after code changes.
- Frontend is static HTML. Just rebuild with Antora and restart the nginx container.
- LlamaStack data persists in a named volume `llamastack-data`
- To start fresh, remove the volume: `podman volume rm llamastack-data`

## Cleanup

To completely remove all resources:

```bash
./scripts/stop-local-podman.sh
podman volume rm llamastack-data
podman rmi showroom-ai-backend:local
```
