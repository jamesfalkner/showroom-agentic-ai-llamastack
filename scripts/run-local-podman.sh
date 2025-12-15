#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NETWORK_NAME="showroom-ai-network"
BACKEND_CONTAINER="showroom-backend"
LLAMASTACK_CONTAINER="showroom-llamastack"
MCP_CONTAINER="showroom-mcp-server"
FRONTEND_CONTAINER="showroom-frontend"
BACKEND_IMAGE="showroom-ai-backend:local"
FRONTEND_PORT=8080

# Get the directory where the script is located
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}Showroom AI Assistant - Local Podman Setup${NC}"
echo "=============================================="
echo ""

# Check if OPENAI_API_KEY is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo -e "${YELLOW}OPENAI_API_KEY not set in environment.${NC}"

    # Try to load from .env.yaml
    if [ -f "$PROJECT_ROOT/.env.yaml" ]; then
        echo -e "${YELLOW}Loading API key from .env.yaml...${NC}"
        OPENAI_API_KEY=$(grep "llm_api_key:" "$PROJECT_ROOT/.env.yaml" | cut -d'"' -f2 | tr -d "'")
        if [ -z "$OPENAI_API_KEY" ]; then
            echo -e "${RED}Error: Could not extract llm_api_key from .env.yaml${NC}"
            echo "Please set OPENAI_API_KEY environment variable or update .env.yaml"
            exit 1
        fi
        export OPENAI_API_KEY
        echo -e "${GREEN}✓ API key loaded from .env.yaml${NC}"
    else
        echo -e "${RED}Error: No .env.yaml found and OPENAI_API_KEY not set${NC}"
        echo ""
        echo "Please either:"
        echo "  1. Export OPENAI_API_KEY: export OPENAI_API_KEY='your-key-here'"
        echo "  2. Create .env.yaml from .env.yaml.example with your API key"
        exit 1
    fi
fi
echo ""

# Function to cleanup containers and network
cleanup() {
    echo -e "${YELLOW}Cleaning up containers and network...${NC}"
    podman rm -f $FRONTEND_CONTAINER 2>/dev/null || true
    podman rm -f $BACKEND_CONTAINER 2>/dev/null || true
    podman rm -f $MCP_CONTAINER 2>/dev/null || true
    podman rm -f $LLAMASTACK_CONTAINER 2>/dev/null || true
    podman network rm $NETWORK_NAME 2>/dev/null || true
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

# Handle Ctrl+C
trap cleanup EXIT INT TERM

# Clean up any existing containers
cleanup

# 1. Create podman network
echo -e "${YELLOW}1. Creating podman network...${NC}"
podman network create $NETWORK_NAME
echo -e "${GREEN}✓ Network '$NETWORK_NAME' created${NC}"
echo ""

# 2. Build the Antora site first (needed for RAG content)
echo -e "${YELLOW}2. Building Antora site and RAG content...${NC}"
cd "$PROJECT_ROOT"
if ! command -v npx &> /dev/null; then
    echo -e "${RED}Error: npx not found. Please install Node.js${NC}"
    exit 1
fi
npx antora default-site.yml
echo -e "${GREEN}✓ Antora site built${NC}"
echo -e "${GREEN}✓ RAG content exported${NC}"
echo ""

# 3. Build backend container image
echo -e "${YELLOW}3. Building backend container image...${NC}"
podman build -f "$PROJECT_ROOT/Dockerfile.backend" -t $BACKEND_IMAGE "$PROJECT_ROOT"
echo -e "${GREEN}✓ Backend image built${NC}"
echo ""

# 4. Start LlamaStack container
echo -e "${YELLOW}4. Starting LlamaStack container...${NC}"
podman run -d \
    --name $LLAMASTACK_CONTAINER \
    --network $NETWORK_NAME \
    -e OPENAI_API_KEY="$OPENAI_API_KEY" \
    -v llamastack-data:/.llama:z \
    docker.io/llamastack/distribution-starter:0.3.2
echo -e "${GREEN}✓ LlamaStack container started${NC}"
echo ""

# Wait for LlamaStack to be healthy
echo -e "${YELLOW}Waiting for LlamaStack to be ready (this may take a minute or two)...${NC}"
MAX_WAIT=120
WAIT_COUNT=0
LLAMASTACK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if podman exec $LLAMASTACK_CONTAINER curl -s http://localhost:8321/health > /dev/null 2>&1; then
        LLAMASTACK_READY=true
        break
    fi
    echo -n "."
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))
done
echo ""

if [ "$LLAMASTACK_READY" = true ]; then
    echo -e "${GREEN}✓ LlamaStack is ready!${NC}"
else
    echo -e "${RED}✗ LlamaStack failed to become ready after ${MAX_WAIT}s${NC}"
    echo -e "${YELLOW}Check logs with: podman logs $LLAMASTACK_CONTAINER${NC}"
    exit 1
fi
echo ""

# 5. Start MCP Kubernetes Server container
echo -e "${YELLOW}5. Starting MCP Kubernetes Server...${NC}"

# Check if kubeconfig exists
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo -e "${RED}Error: Kubeconfig not found at $KUBECONFIG_PATH${NC}"
    echo "Please ensure you're logged in with 'oc login' or 'kubectl'"
    exit 1
fi

# Mount the entire .kube directory to preserve context
podman run -d \
    --name $MCP_CONTAINER \
    --network $NETWORK_NAME \
    -v "$HOME/.kube:/root/.kube:ro,z" \
    -e KUBECONFIG=/root/.kube/config \
    -e HOME=/tmp \
    -e NPM_CONFIG_CACHE=/tmp/.npm \
    docker.io/node:20 \
    sh -c "npx -y kubernetes-mcp-server@latest --port 3000"
echo -e "${GREEN}✓ MCP Server started with kubeconfig${NC}"
echo ""

# 6. Start Backend container
echo -e "${YELLOW}6. Starting Backend API container...${NC}"
podman run -d \
    --name $BACKEND_CONTAINER \
    --network $NETWORK_NAME \
    -p 8000:8080 \
    -e PORT=8080 \
    -e OPENAI_API_KEY="$OPENAI_API_KEY" \
    -e LLAMA_STACK_URL="http://$LLAMASTACK_CONTAINER:8321" \
    -e ASSISTANT_CONFIG_PATH="/app/config/assistant-config.yaml" \
    -e CONTENT_DIR="/app/rag-content" \
    -e PDF_DIR="/app/content/modules/ROOT/assets/techdocs" \
    $BACKEND_IMAGE
echo -e "${GREEN}✓ Backend started on http://localhost:8000${NC}"
echo ""

# 7. Start Frontend HTTP server
echo -e "${YELLOW}7. Starting Frontend HTTP server...${NC}"
podman run -d \
    --name $FRONTEND_CONTAINER \
    --network $NETWORK_NAME \
    -p $FRONTEND_PORT:80 \
    -v "$PROJECT_ROOT/www:/usr/share/nginx/html:ro,z" \
    docker.io/nginx:alpine
echo -e "${GREEN}✓ Frontend started on http://localhost:$FRONTEND_PORT${NC}"
echo ""

# Wait a moment for remaining services to start
echo -e "${YELLOW}Waiting for remaining services to start...${NC}"
sleep 5

# Check service health
echo ""
echo -e "${BLUE}Checking service health...${NC}"

# Check LlamaStack
if podman exec $LLAMASTACK_CONTAINER curl -s http://localhost:8321/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ LlamaStack is healthy${NC}"
else
    echo -e "${YELLOW}⚠ LlamaStack health check failed${NC}"
fi

# Check MCP Server
if podman exec $MCP_CONTAINER true 2>/dev/null; then
    echo -e "${GREEN}✓ MCP Server is running${NC}"
else
    echo -e "${RED}✗ MCP Server failed to start${NC}"
fi

# Check Backend
if curl -s http://localhost:8000/api/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Backend API is healthy${NC}"
else
    echo -e "${YELLOW}⚠ Backend API not ready yet (may take a few moments)${NC}"
fi

# Check Frontend
if curl -s http://localhost:$FRONTEND_PORT > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Frontend is accessible${NC}"
else
    echo -e "${RED}✗ Frontend failed to start${NC}"
fi

echo ""
echo "=============================================="
echo -e "${GREEN}All services started!${NC}"
echo ""
echo -e "${BLUE}Access the application:${NC}"
echo "  Showroom Frontend: http://localhost:$FRONTEND_PORT"
echo "  Backend API:       http://localhost:8000"
echo "  Health Check:      http://localhost:8000/api/health"
echo ""
echo -e "${BLUE}View logs:${NC}"
echo "  Backend:     podman logs -f $BACKEND_CONTAINER"
echo "  LlamaStack:  podman logs -f $LLAMASTACK_CONTAINER"
echo "  MCP Server:  podman logs -f $MCP_CONTAINER"
echo "  Frontend:    podman logs -f $FRONTEND_CONTAINER"
echo ""
echo -e "${BLUE}Stop all services:${NC}"
echo "  Press Ctrl+C or run: ./scripts/stop-local-podman.sh"
echo ""
echo -e "${YELLOW}Note: Services will automatically cleanup on Ctrl+C${NC}"
echo ""

# Keep script running and show logs
echo -e "${YELLOW}Showing backend logs (Ctrl+C to stop all services):${NC}"
echo ""
podman logs -f $BACKEND_CONTAINER
