# Backend Management Scripts

These scripts manage the containerized services for the Showroom AI Assistant backend.

## Prerequisites

- **Podman** installed and running
- **Python 3.12+** with dependencies installed (`pip install -r backend/requirements.txt`)
- **`.env.yaml`** file configured with your OpenAI API key
- **Kubernetes/OpenShift** cluster access (kubeconfig at `~/.kube/config`)

## Scripts

### `start-backend.sh`
Starts all backend services in the correct order:
1. Creates podman network (`llama-network`)
2. Starts LlamaStack container (port 8321)
3. Starts MCP Kubernetes server container (port 3000)
4. Starts FastAPI application backend (port 8000)

```bash
./scripts/start-backend.sh
```

**Services Started:**
- LlamaStack: `http://localhost:8321`
- MCP Server: `http://localhost:3000`
- API Backend: `http://localhost:8000`

### `stop-backend.sh`
Stops and removes all backend services:
- Kills FastAPI backend process
- Removes MCP server container
- Removes LlamaStack container
- Preserves the podman network for faster restarts

```bash
./scripts/stop-backend.sh
```

### `restart-backend.sh`
Convenience script that stops and then starts all services.

```bash
./scripts/restart-backend.sh
```

### `status-backend.sh`
Displays the current status of all services:
- Container status (running/stopped)
- Backend process status
- Service health checks
- Recent backend logs

```bash
./scripts/status-backend.sh
```

## Service Architecture

```
┌─────────────────────────────────────────────────┐
│           FastAPI Backend (port 8000)           │
│  - Chat API                                     │
│  - Coordinates RAG & MCP                        │
│  - Streams responses via SSE                    │
└────────────┬────────────────────────┬───────────┘
             │                        │
             ▼                        ▼
┌────────────────────────┐  ┌──────────────────────┐
│  LlamaStack (8321)     │  │  MCP Server (3000)   │
│  - Agents API          │  │  - Kubernetes tools  │
│  - Vector stores       │  │  - 23 K8s functions  │
│  - Tool orchestration  │  │  - Cluster access    │
└────────────────────────┘  └──────────────────────┘
             │
             ▼
      ┌─────────────┐
      │  OpenAI API │
      │  - GPT-4o   │
      │  - Embed-3  │
      └─────────────┘
```

## Logging

### View Logs
```bash
# Backend logs
tail -f /tmp/backend.log

# LlamaStack container logs
podman logs -f llamastack

# MCP server container logs
podman logs -f mcp-server
```

### Log Locations
- **Backend**: `/tmp/backend.log`
- **Containers**: View via `podman logs`

## Troubleshooting

### Services won't start
```bash
# Check if ports are already in use
lsof -i :8000
lsof -i :8321
lsof -i :3000

# Kill any stray processes
pkill -f "python.*app.py"
podman rm -f llamastack mcp-server
```

### Backend fails to connect to LlamaStack
```bash
# Check if LlamaStack is responding
curl http://localhost:8321/v1/models

# Check container logs
podman logs llamastack | tail -50
```

### MCP tools not working
```bash
# Verify MCP server is running
podman logs mcp-server

# Check Kubernetes access
kubectl cluster-info

# Ensure kubeconfig is accessible
ls -la ~/.kube/config
```

### Backend crashes during startup
```bash
# Check logs for errors
tail -100 /tmp/backend.log

# Common issues:
# - Missing .env.yaml
# - Invalid API key
# - LlamaStack not ready (wait 30s after starting containers)
```

## Development Workflow

1. **Initial setup:**
   ```bash
   ./scripts/start-backend.sh
   ```

2. **Code changes to backend:**
   ```bash
   # Just restart the FastAPI backend
   pkill -f "python.*app.py"
   cd backend && ASSISTANT_CONFIG_PATH=../config/assistant-config.yaml python app.py
   ```

3. **Full restart (container changes):**
   ```bash
   ./scripts/restart-backend.sh
   ```

4. **Check status:**
   ```bash
   ./scripts/status-backend.sh
   ```

## Environment Variables

The scripts read configuration from:
- **`.env.yaml`**: Contains `llm_api_key` for OpenAI
- **`config/assistant-config.yaml`**: AI behavior configuration
- **`~/.kube/config`**: Kubernetes cluster access

## Network Configuration

The scripts create a podman network (`llama-network`) that allows containers to communicate:
- LlamaStack can reach MCP server at `http://mcp-server:3000`
- Containers can communicate without exposing all ports to host
- Network persists between restarts for faster startup

## Testing the Integration

```bash
# Start services
./scripts/start-backend.sh

# Test basic chat (without MCP)
curl -X POST 'http://localhost:8000/api/chat/stream' \
  -H 'Content-Type: application/json' \
  -d '{
    "message": "What is OpenShift?",
    "conversation_history": [],
    "agent_type": "lab_content",
    "include_mcp": false
  }'

# Test with MCP tools (Kubernetes integration)
curl -X POST 'http://localhost:8000/api/chat/stream' \
  -H 'Content-Type: application/json' \
  -d '{
    "message": "List all namespaces on the cluster",
    "conversation_history": [],
    "agent_type": "openshift_debugging",
    "include_mcp": true
  }'
```

## Cleanup

To completely remove everything:
```bash
# Stop services
./scripts/stop-backend.sh

# Remove network
podman network rm llama-network

# Remove logs
rm /tmp/backend.log
```
