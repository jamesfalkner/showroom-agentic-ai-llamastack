#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NETWORK_NAME="showroom-ai-network"
BACKEND_CONTAINER="showroom-backend"
LLAMASTACK_CONTAINER="showroom-llamastack"
MCP_CONTAINER="showroom-mcp-server"
FRONTEND_CONTAINER="showroom-frontend"

echo -e "${YELLOW}Stopping Showroom AI Assistant containers...${NC}"
echo ""

# Stop and remove containers
echo -e "${YELLOW}Stopping containers...${NC}"
podman rm -f $FRONTEND_CONTAINER 2>/dev/null && echo -e "${GREEN}✓ Frontend stopped${NC}" || echo -e "${YELLOW}⚠ Frontend not running${NC}"
podman rm -f $BACKEND_CONTAINER 2>/dev/null && echo -e "${GREEN}✓ Backend stopped${NC}" || echo -e "${YELLOW}⚠ Backend not running${NC}"
podman rm -f $MCP_CONTAINER 2>/dev/null && echo -e "${GREEN}✓ MCP Server stopped${NC}" || echo -e "${YELLOW}⚠ MCP Server not running${NC}"
podman rm -f $LLAMASTACK_CONTAINER 2>/dev/null && echo -e "${GREEN}✓ LlamaStack stopped${NC}" || echo -e "${YELLOW}⚠ LlamaStack not running${NC}"
echo ""

# Remove network
echo -e "${YELLOW}Removing network...${NC}"
podman network rm $NETWORK_NAME 2>/dev/null && echo -e "${GREEN}✓ Network removed${NC}" || echo -e "${YELLOW}⚠ Network not found${NC}"
echo ""

echo -e "${GREEN}All services stopped and cleaned up!${NC}"
