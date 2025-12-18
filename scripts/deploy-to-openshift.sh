#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if namespace argument is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: Namespace argument is required${NC}"
    echo "Usage: $0 <namespace>"
    exit 1
fi

NAMESPACE="$1"

# Get the directory where the script is located
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}Deploying Showroom AI Assistant to OpenShift${NC}"
echo "=================================================="
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

# Check if user is logged in to OpenShift
echo -e "${YELLOW}Checking OpenShift login status...${NC}"
if ! oc whoami &> /dev/null; then
    echo -e "${RED}Error: Not logged in to OpenShift${NC}"
    echo "Please run 'oc login' first"
    exit 1
fi
echo -e "${GREEN}✓ Logged in as $(oc whoami)${NC}"
echo ""

# Check if namespace exists
echo -e "${YELLOW}Checking if namespace exists...${NC}"
if ! oc get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: Namespace '$NAMESPACE' does not exist${NC}"
    echo "Please create it first with: oc create namespace $NAMESPACE"
    exit 1
fi
echo -e "${GREEN}✓ Namespace '$NAMESPACE' exists${NC}"
echo ""

echo "Project Root: $PROJECT_ROOT"
echo ""

# 1. Create secret with placeholder value
echo -e "${YELLOW}1. Creating secret with placeholder...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/secret.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ Secret created${NC}"
echo ""

# 2. Read LLM engine configuration and update secret
echo -e "${YELLOW}2. Reading LLM engine configuration...${NC}"

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
echo ""

echo -e "${YELLOW}3. Updating secret with API keys from .env.yaml...${NC}"
if [ ! -f "$PROJECT_ROOT/.env.yaml" ]; then
    echo -e "${RED}Error: .env.yaml not found. Please create it from .env.yaml.example${NC}"
    exit 1
fi

# Extract and patch API keys for all enabled engines
for ENGINE in "${LLM_ENGINES[@]}"; do
    case "$ENGINE" in
        "openai")
            OPENAI_API_KEY=$(yq eval '.openai_api_key // ""' "$PROJECT_ROOT/.env.yaml")
            if [ -z "$OPENAI_API_KEY" ]; then
                echo -e "${RED}Error: Could not extract openai_api_key from .env.yaml${NC}"
                exit 1
            fi
            oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                -p "{\"stringData\":{\"OPENAI_API_KEY\":\"$OPENAI_API_KEY\"}}"
            echo -e "${GREEN}✓ OpenAI API key updated${NC}"

            if [ -n "$OPENAI_ENDPOINT" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"OPENAI_BASE_URL\":\"$OPENAI_ENDPOINT\"}}"
                echo -e "${GREEN}✓ OpenAI Base URL set to $OPENAI_ENDPOINT${NC}"
            fi
            ;;
        "vllm")
            VLLM_API_TOKEN=$(yq eval '.vllm_api_token // ""' "$PROJECT_ROOT/.env.yaml")
            if [ -n "$VLLM_API_TOKEN" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"VLLM_API_TOKEN\":\"$VLLM_API_TOKEN\"}}"
                echo -e "${GREEN}✓ vLLM API token updated${NC}"
            else
                echo -e "${YELLOW}ℹ vLLM API token not found in .env.yaml (optional for local vLLM)${NC}"
            fi

            if [ -n "$VLLM_ENDPOINT" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"VLLM_URL\":\"$VLLM_ENDPOINT\"}}"
                echo -e "${GREEN}✓ vLLM URL set to $VLLM_ENDPOINT${NC}"
            fi

            if [ -n "$VLLM_MAX_TOKENS" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"VLLM_MAX_TOKENS\":\"$VLLM_MAX_TOKENS\"}}"
                echo -e "${GREEN}✓ vLLM Max Tokens set to $VLLM_MAX_TOKENS${NC}"
            fi

            if [ -n "$VLLM_TLS_VERIFY" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"VLLM_TLS_VERIFY\":\"$VLLM_TLS_VERIFY\"}}"
                echo -e "${GREEN}✓ vLLM TLS Verify set to $VLLM_TLS_VERIFY${NC}"
            fi
            ;;
        "ollama")
            OLLAMA_API_KEY=$(yq eval '.ollama_api_key // ""' "$PROJECT_ROOT/.env.yaml")
            if [ -n "$OLLAMA_API_KEY" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"OLLAMA_API_KEY\":\"$OLLAMA_API_KEY\"}}"
                echo -e "${GREEN}✓ Ollama API key updated${NC}"
            else
                echo -e "${YELLOW}ℹ Ollama API key not found in .env.yaml (optional for local Ollama)${NC}"
            fi

            if [ -n "$OLLAMA_ENDPOINT" ]; then
                oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
                    -p "{\"stringData\":{\"OLLAMA_URL\":\"$OLLAMA_ENDPOINT\"}}"
                echo -e "${GREEN}✓ Ollama URL set to $OLLAMA_ENDPOINT${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Error: Unknown LLM engine '$ENGINE'${NC}"
            echo "Supported engines: openai, vllm, ollama"
            exit 1
            ;;
    esac
done

TAVILY_API_KEY=$(yq eval '.tavily_api_key // ""' "$PROJECT_ROOT/.env.yaml")
if [ -z "$TAVILY_API_KEY" ]; then
    echo -e "${RED}Error: Could not extract tavily_api_key from .env.yaml${NC}"
    exit 1
fi

oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
    -p "{\"stringData\":{\"TAVILY_SEARCH_API_KEY\":\"$TAVILY_API_KEY\"}}"
echo -e "${GREEN}✓ Tavily API key updated${NC}"
echo ""

# 4. Create ConfigMap from assistant-config.yaml
echo -e "${YELLOW}4. Creating ConfigMap from assistant-config.yaml...${NC}"
oc create configmap showroom-ai-assistant-config \
    --from-file=assistant-config.yaml="$PROJECT_ROOT/config/assistant-config.yaml" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f -
echo -e "${GREEN}✓ ConfigMap created${NC}"
echo ""

# 5. Create PVC
echo -e "${YELLOW}5. Creating PersistentVolumeClaim...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/pvc.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ PVC created${NC}"
echo ""

# 6. Create RBAC (substituting namespace placeholder)
echo -e "${YELLOW}6. Creating RBAC resources...${NC}"
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$PROJECT_ROOT/k8s/rbac.yaml" | oc apply -n "$NAMESPACE" -f -
echo -e "${GREEN}✓ RBAC created${NC}"
echo ""

# 7. Create Service
echo -e "${YELLOW}7. Creating Service...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/service.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ Service created${NC}"
echo ""

# 8. Create Route
echo -e "${YELLOW}8. Creating Route...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/route.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ Route created${NC}"
echo ""

# 9. Create BuildConfig and ImageStream
echo -e "${YELLOW}9. Creating BuildConfig and ImageStream...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/buildconfig.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ BuildConfig and ImageStream created${NC}"
echo ""

# 10. Create Deployment (substituting namespace placeholder)
echo -e "${YELLOW}10. Creating Deployment...${NC}"
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$PROJECT_ROOT/k8s/deployment.yaml" | oc apply -n "$NAMESPACE" -f -
echo -e "${GREEN}✓ Deployment created${NC}"
echo ""

# 11. Build RAG-optimized content
echo -e "${YELLOW}11. Building RAG-optimized content with Antora...${NC}"
cd "$PROJECT_ROOT"

# Check if npx is available
if ! command -v npx &> /dev/null; then
    echo -e "${RED}Error: npx not found. Please install Node.js${NC}"
    exit 1
fi

# Build the site to generate rag-content
npx antora --extension ai-assistant-build --extension rag-export default-site.yml
echo -e "${GREEN}✓ RAG content built${NC}"
echo ""

# 12. Start build
echo -e "${YELLOW}12. Starting container build...${NC}"
tmpdir="$(mktemp -d)"
cp -r backend content config rag-content "$tmpdir"/
cp Dockerfile.backend "$tmpdir"/
oc start-build showroom-ai-assistant-backend --from-dir="$tmpdir" --follow -n "$NAMESPACE"
rm -rf "$tmpdir"
echo -e "${GREEN}✓ Build complete${NC}"
echo ""

# Get the route URL
echo "=================================================="
echo -e "${GREEN}Deployment complete!${NC}"
echo ""
ROUTE_URL=$(oc get route showroom-ai-assistant -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "Route URL: https://$ROUTE_URL"
echo ""
echo "To check status:"
echo "  oc get pods -n $NAMESPACE"
echo "  oc logs -f deployment/showroom-ai-assistant -n $NAMESPACE -c backend"
echo ""
echo "To check health:"
echo "  curl https://$ROUTE_URL/api/health"
echo ""
