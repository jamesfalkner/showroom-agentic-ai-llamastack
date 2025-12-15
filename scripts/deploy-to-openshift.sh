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

# 2. Update secret with value from .env.yaml
echo -e "${YELLOW}2. Updating secret with API key from .env.yaml...${NC}"
if [ ! -f "$PROJECT_ROOT/.env.yaml" ]; then
    echo -e "${RED}Error: .env.yaml not found. Please create it from .env.yaml.example${NC}"
    exit 1
fi

OPENAI_API_KEY=$(grep "llm_api_key:" "$PROJECT_ROOT/.env.yaml" | cut -d'"' -f2)
if [ -z "$OPENAI_API_KEY" ]; then
    echo -e "${RED}Error: Could not extract llm_api_key from .env.yaml${NC}"
    exit 1
fi

oc patch secret showroom-ai-assistant-secrets -n "$NAMESPACE" \
    -p "{\"stringData\":{\"OPENAI_API_KEY\":\"$OPENAI_API_KEY\"}}"
echo -e "${GREEN}✓ Secret updated with API key${NC}"
echo ""

# 3. Create ConfigMap from assistant-config.yaml
echo -e "${YELLOW}3. Creating ConfigMap from assistant-config.yaml...${NC}"
oc create configmap showroom-ai-assistant-config \
    --from-file=assistant-config.yaml="$PROJECT_ROOT/config/assistant-config.yaml" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f -
echo -e "${GREEN}✓ ConfigMap created${NC}"
echo ""

# 4. Create PVC
echo -e "${YELLOW}4. Creating PersistentVolumeClaim...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/pvc.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ PVC created${NC}"
echo ""

# 5. Create RBAC (substituting namespace placeholder)
echo -e "${YELLOW}5. Creating RBAC resources...${NC}"
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$PROJECT_ROOT/k8s/rbac.yaml" | oc apply -n "$NAMESPACE" -f -
echo -e "${GREEN}✓ RBAC created${NC}"
echo ""

# 6. Create Service
echo -e "${YELLOW}6. Creating Service...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/service.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ Service created${NC}"
echo ""

# 7. Create Route
echo -e "${YELLOW}7. Creating Route...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/route.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ Route created${NC}"
echo ""

# 8. Create BuildConfig and ImageStream
echo -e "${YELLOW}8. Creating BuildConfig and ImageStream...${NC}"
oc apply -f "$PROJECT_ROOT/k8s/buildconfig.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✓ BuildConfig and ImageStream created${NC}"
echo ""

# 9. Create Deployment (substituting namespace placeholder)
echo -e "${YELLOW}9. Creating Deployment...${NC}"
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$PROJECT_ROOT/k8s/deployment.yaml" | oc apply -n "$NAMESPACE" -f -
echo -e "${GREEN}✓ Deployment created${NC}"
echo ""

# 10. Build RAG-optimized content
echo -e "${YELLOW}10. Building RAG-optimized content with Antora...${NC}"
cd "$PROJECT_ROOT"

# Check if npx is available
if ! command -v npx &> /dev/null; then
    echo -e "${RED}Error: npx not found. Please install Node.js${NC}"
    exit 1
fi

# Build the site to generate rag-content
npx antora default-site.yml
echo -e "${GREEN}✓ RAG content built${NC}"
echo ""

# 11. Start build
echo -e "${YELLOW}11. Starting container build...${NC}"
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
