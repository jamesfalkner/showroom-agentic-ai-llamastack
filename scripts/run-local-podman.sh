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
BACKEND_PORT=8001
FRONTEND_PORT=8080

# Get the directory where the script is located
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}Showroom AI Assistant - Local Podman Setup${NC}"
echo "=============================================="
echo ""

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: yq is not installed${NC}"
    echo ""
    echo "yq is required for parsing YAML configuration files."
    echo "Please install it from: https://github.com/mikefarah/yq"
    echo ""
    echo "Installation options:"
    echo "  macOS:   brew install yq"
    echo "  Linux:   Download from https://github.com/mikefarah/yq/releases"
    exit 1
fi

# Read LLM engine configuration from assistant-config.yaml
echo -e "${YELLOW}Reading LLM engine configuration...${NC}"

# Support both old (single engine) and new (multiple engines) format
LLM_ENGINES_RAW=$(yq eval '.llm.engines // []' "$PROJECT_ROOT/config/assistant-config.yaml")
if [ "$LLM_ENGINES_RAW" = "[]" ] || [ -z "$LLM_ENGINES_RAW" ]; then
    # Fallback to old single engine format
    SINGLE_ENGINE=$(yq eval '.llm.engine // "openai"' "$PROJECT_ROOT/config/assistant-config.yaml")
    LLM_ENGINES=("$SINGLE_ENGINE")
    echo -e "${YELLOW}Using single engine format, defaulting to '$SINGLE_ENGINE'${NC}"
else
    # New format: read engines as array (portable method for bash 3.x compatibility)
    LLM_ENGINES=()
    while IFS= read -r engine; do
        LLM_ENGINES+=("$engine")
    done < <(yq eval '.llm.engines[]' "$PROJECT_ROOT/config/assistant-config.yaml")
fi

echo -e "${GREEN}✓ Enabled LLM Engines: ${LLM_ENGINES[*]}${NC}"

# Read per-engine endpoint configuration
OPENAI_ENDPOINT=$(yq eval '.llm.openai.endpoint // ""' "$PROJECT_ROOT/config/assistant-config.yaml")
VLLM_ENDPOINT=$(yq eval '.llm.vllm.endpoint // ""' "$PROJECT_ROOT/config/assistant-config.yaml")
OLLAMA_ENDPOINT=$(yq eval '.llm.ollama.endpoint // ""' "$PROJECT_ROOT/config/assistant-config.yaml")

# Read vLLM-specific configuration
VLLM_MAX_TOKENS=$(yq eval '.llm.vllm.max_tokens // ""' "$PROJECT_ROOT/config/assistant-config.yaml")
VLLM_TLS_VERIFY=$(yq eval '.llm.vllm.tls_verify // ""' "$PROJECT_ROOT/config/assistant-config.yaml")

# Load API keys for all enabled engines
if [ ! -f "$PROJECT_ROOT/.env.yaml" ]; then
    echo -e "${RED}Error: No .env.yaml found${NC}"
    echo ""
    echo "Please create .env.yaml from .env.yaml.example with your API keys"
    exit 1
fi

# Process each enabled engine
for ENGINE in "${LLM_ENGINES[@]}"; do
    case "$ENGINE" in
        "openai")
            if [ -z "$OPENAI_API_KEY" ]; then
                echo -e "${YELLOW}Loading OpenAI API key from .env.yaml...${NC}"
                OPENAI_API_KEY=$(yq eval '.openai_api_key // ""' "$PROJECT_ROOT/.env.yaml")
                if [ -z "$OPENAI_API_KEY" ]; then
                    echo -e "${RED}Error: Could not extract openai_api_key from .env.yaml${NC}"
                    echo "Please set OPENAI_API_KEY environment variable or update .env.yaml"
                    exit 1
                fi
                export OPENAI_API_KEY
                echo -e "${GREEN}✓ OpenAI API key loaded${NC}"
            fi
            ;;
        "vllm")
            if [ -z "$VLLM_API_TOKEN" ]; then
                VLLM_API_TOKEN=$(yq eval '.vllm_api_token // ""' "$PROJECT_ROOT/.env.yaml")
                if [ -n "$VLLM_API_TOKEN" ]; then
                    export VLLM_API_TOKEN
                    echo -e "${GREEN}✓ vLLM API token loaded from .env.yaml${NC}"
                else
                    echo -e "${YELLOW}ℹ vLLM API token not found in .env.yaml (optional for local vLLM)${NC}"
                fi
            fi
            ;;
        "ollama")
            if [ -z "$OLLAMA_API_KEY" ]; then
                OLLAMA_API_KEY=$(yq eval '.ollama_api_key // ""' "$PROJECT_ROOT/.env.yaml")
                if [ -n "$OLLAMA_API_KEY" ]; then
                    export OLLAMA_API_KEY
                    echo -e "${GREEN}✓ Ollama API key loaded from .env.yaml${NC}"
                else
                    echo -e "${YELLOW}ℹ Ollama API key not found in .env.yaml (optional for local Ollama)${NC}"
                fi
            fi
            ;;
        *)
            echo -e "${RED}Error: Unknown LLM engine '$ENGINE'${NC}"
            echo "Supported engines: openai, vllm, ollama"
            exit 1
            ;;
    esac
done
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
npx antora --extension ai-assistant-build --extension rag-export default-site.yml
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

# Build environment variables for all enabled engines
LLAMASTACK_ENV_VARS=""

for ENGINE in "${LLM_ENGINES[@]}"; do
    case "$ENGINE" in
        "openai")
            if [ -n "$OPENAI_API_KEY" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e OPENAI_API_KEY=\"$OPENAI_API_KEY\""
            fi
            if [ -n "$OPENAI_ENDPOINT" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e OPENAI_BASE_URL=\"$OPENAI_ENDPOINT\""
                echo -e "${GREEN}✓ Setting OPENAI_BASE_URL to $OPENAI_ENDPOINT${NC}"
            fi
            ;;
        "vllm")
            if [ -n "$VLLM_API_TOKEN" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e VLLM_API_TOKEN=\"$VLLM_API_TOKEN\""
            fi
            if [ -n "$VLLM_ENDPOINT" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e VLLM_URL=\"$VLLM_ENDPOINT\""
                echo -e "${GREEN}✓ Setting VLLM_URL to $VLLM_ENDPOINT${NC}"
            fi
            if [ -n "$VLLM_MAX_TOKENS" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e VLLM_MAX_TOKENS=\"$VLLM_MAX_TOKENS\""
                echo -e "${GREEN}✓ Setting VLLM_MAX_TOKENS to $VLLM_MAX_TOKENS${NC}"
            fi
            if [ -n "$VLLM_TLS_VERIFY" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e VLLM_TLS_VERIFY=\"$VLLM_TLS_VERIFY\""
                echo -e "${GREEN}✓ Setting VLLM_TLS_VERIFY to $VLLM_TLS_VERIFY${NC}"
            fi
            ;;
        "ollama")
            if [ -n "$OLLAMA_API_KEY" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e OLLAMA_API_KEY=\"$OLLAMA_API_KEY\""
            fi
            if [ -n "$OLLAMA_ENDPOINT" ]; then
                LLAMASTACK_ENV_VARS="$LLAMASTACK_ENV_VARS -e OLLAMA_URL=\"$OLLAMA_ENDPOINT\""
                echo -e "${GREEN}✓ Setting OLLAMA_URL to $OLLAMA_ENDPOINT${NC}"
            fi
            ;;
    esac
done

echo "Podman variables: $LLAMASTACK_ENV_VARS"

eval "podman run -d \
    --name $LLAMASTACK_CONTAINER \
    --network $NETWORK_NAME \
    $LLAMASTACK_ENV_VARS \
    -v llamastack-data:/.llama:z \
    docker.io/llamastack/distribution-starter:0.3.5"
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

# Build backend environment variables
# Note: MCP_SERVER_URL uses container name for Podman networking (containers can't access localhost)
# In OpenShift, localhost works because sidecars share the same Pod network namespace
BACKEND_ENV_VARS="-e PORT=8080 -e LLAMA_STACK_URL=\"http://$LLAMASTACK_CONTAINER:8321\" \
-e MCP_SERVER_URL=\"http://$MCP_CONTAINER:3000/mcp\" \
-e ASSISTANT_CONFIG_PATH=\"/app/config/assistant-config.yaml\" \
-e CONTENT_DIR=\"/app/rag-content\" \
-e PDF_DIR=\"/app/content/modules/ROOT/assets/techdocs\""

# Add engine-specific environment variables for all enabled engines (same as LlamaStack for consistency)
for ENGINE in "${LLM_ENGINES[@]}"; do
    case "$ENGINE" in
        "openai")
            if [ -n "$OPENAI_API_KEY" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e OPENAI_API_KEY=\"$OPENAI_API_KEY\""
            fi
            if [ -n "$OPENAI_ENDPOINT" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e OPENAI_BASE_URL=\"$OPENAI_ENDPOINT\""
            fi
            ;;
        "vllm")
            if [ -n "$VLLM_API_TOKEN" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e VLLM_API_TOKEN=\"$VLLM_API_TOKEN\""
            fi
            if [ -n "$VLLM_ENDPOINT" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e VLLM_URL=\"$VLLM_ENDPOINT\""
            fi
            if [ -n "$VLLM_MAX_TOKENS" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e VLLM_MAX_TOKENS=\"$VLLM_MAX_TOKENS\""
            fi
            if [ -n "$VLLM_TLS_VERIFY" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e VLLM_TLS_VERIFY=\"$VLLM_TLS_VERIFY\""
            fi
            ;;
        "ollama")
            if [ -n "$OLLAMA_API_KEY" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e OLLAMA_API_KEY=\"$OLLAMA_API_KEY\""
            fi
            if [ -n "$OLLAMA_ENDPOINT" ]; then
                BACKEND_ENV_VARS="$BACKEND_ENV_VARS -e OLLAMA_URL=\"$OLLAMA_ENDPOINT\""
            fi
            ;;
    esac
done

eval "podman run -d \
    --name $BACKEND_CONTAINER \
    --network $NETWORK_NAME \
    -p $BACKEND_PORT:8080 \
    $BACKEND_ENV_VARS \
    $BACKEND_IMAGE"
echo -e "${GREEN}✓ Backend started on http://localhost:$BACKEND_PORT${NC}"
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
if curl -s http://localhost:$BACKEND_PORT/api/health > /dev/null 2>&1; then
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
echo "  Backend API:       http://localhost:$BACKEND_PORT"
echo "  Health Check:      http://localhost:$BACKEND_PORT/api/health"
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
