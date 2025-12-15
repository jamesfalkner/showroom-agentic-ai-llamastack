#!/usr/bin/env python3
"""
Showroom AI Assistant Backend v2
FastAPI service with LlamaStack multi-agent system, RAG, and MCP integration
"""
import asyncio
import os
import json
import logging
from typing import Dict, List, Optional, AsyncGenerator, Literal
from pathlib import Path
import re
from contextlib import asynccontextmanager

import httpx
import yaml
from llama_stack_client import LlamaStackClient
from llama_stack_client.types import UserMessage, SystemMessage, CompletionMessage
from PyPDF2 import PdfReader

# Import LlamaStack agents helper
from llamastack_agents import create_or_get_agent_session, stream_agent_turn, format_agent_event_for_sse

# Import RAG initialization
from rag_init import initialize_vector_store

try:
    from fastmcp import Client as MCPClient
except ImportError:
    try:
        from fastmcp.client import Client as MCPClient
    except ImportError:
        try:
            from mcp.client import Client as MCPClient
        except ImportError:
            MCPClient = None

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# Configure logging
log_level = os.getenv("LOG_LEVEL", "INFO").upper()
log_level_value = getattr(logging, log_level, logging.INFO)
logging.basicConfig(level=log_level_value)
logger = logging.getLogger(__name__)


# Load configuration
def load_config():
    """Load configuration from assistant-config.yaml"""
    # Try multiple config paths (local development, Docker, absolute)
    possible_paths = [
        os.getenv("ASSISTANT_CONFIG_PATH"),
        "../config/assistant-config.yaml",  # Local development
        "/app/config/assistant-config.yaml",  # Docker
        "./config/assistant-config.yaml",  # Running from project root
    ]

    for config_path in possible_paths:
        if not config_path:
            continue

        config_file_path = Path(config_path)
        if config_file_path.exists():
            try:
                with open(config_file_path, 'r') as f:
                    config_data = yaml.safe_load(f) or {}
                logger.info(f"Loaded configuration from {config_file_path}")
                logger.info(f"Config keys: {list(config_data.keys())}")
                return config_data
            except Exception as e:
                logger.warning(f"Failed to load config from {config_file_path}: {e}")

    logger.warning("No configuration file found, using defaults")
    return {}


class Config:
    def __init__(self):
        self.config_data = load_config()

        # LlamaStack Configuration
        self.LLAMA_STACK_URL = os.getenv("LLAMA_STACK_URL", "http://localhost:8321")

        # LLM Configuration
        self.LLM_MODEL = self._get_config_value("llm.model", "openai/gpt-4o")
        self.EMBEDDING_MODEL = self._get_config_value("llm.embedding_model", "text-embedding-3-small")

        # Content directories
        # Default to local paths for development (relative to backend directory)
        # In production/Docker, these should be set via environment variables
        # Use RAG-optimized content with resolved AsciiDoc attributes
        self.CONTENT_DIR = os.getenv("CONTENT_DIR", "../rag-content")
        self.PDF_DIR = os.getenv("PDF_DIR", "../content/modules/ROOT/assets/techdocs")

        # Content processing
        self.MIN_CHUNK_SIZE = 100

    def _get_config_value(self, key_path: str, default_value):
        """Get configuration value using dot notation"""
        keys = key_path.split('.')
        value = self.config_data
        try:
            for key in keys:
                value = value[key]
            return value
        except (KeyError, TypeError):
            return default_value


config = Config()


# Pydantic models
class ConversationMessage(BaseModel):
    role: str = Field(..., description="Message role: 'user', 'assistant', or 'system'")
    content: str = Field(..., description="Message content")


class ChatRequest(BaseModel):
    message: str = Field(..., description="Current user message")
    conversation_history: List[ConversationMessage] = Field(default_factory=list)
    agent_type: Optional[Literal["lab_content", "openshift_debugging", "auto"]] = Field(default="auto", description="Which agent to use")
    include_mcp: bool = Field(default=True, description="Whether to include MCP tools")
    page_context: Optional[str] = Field(default=None, description="Current page context")


class MCPManager:
    """MCP tools manager (keeping existing MCP integration)"""

    def __init__(self, mcp_config: Dict):
        self.mcp_config = mcp_config
        self.client = None
        self._initialized = False
        self._client_available = MCPClient is not None

    async def initialize(self):
        """Initialize MCP client"""
        if self._initialized or not self._client_available:
            return

        if "mcpServers" not in self.mcp_config:
            logger.warning("No MCP servers configured")
            return

        try:
            self.client = MCPClient(self.mcp_config)
            self._initialized = True
            logger.info("MCP client initialized")
        except Exception as e:
            logger.error(f"Failed to initialize MCP: {e}")

    async def get_tools(self) -> List[Dict]:
        """Get available MCP tools"""
        if not self._initialized:
            await self.initialize()

        if not self.client:
            return []

        try:
            async with self.client as client:
                tools = await client.list_tools()
                return [
                    {
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema.model_dump() if hasattr(tool.inputSchema, 'model_dump') else tool.inputSchema
                    }
                    for tool in tools
                ]
        except Exception as e:
            logger.error(f"Error getting MCP tools: {e}")
            return []

    async def call_tool(self, tool_name: str, arguments: Dict) -> Dict:
        """Call MCP tool"""
        if not self._initialized:
            await self.initialize()

        if not self.client:
            return {"error": "MCP not initialized"}

        try:
            async with self.client as client:
                result = await client.call_tool(tool_name, arguments)

                # Extract text from result
                if hasattr(result, 'content') and result.content:
                    if isinstance(result.content, list):
                        texts = []
                        for item in result.content:
                            if hasattr(item, 'text'):
                                texts.append(item.text)
                        return {"result": "\n".join(texts)}
                    elif hasattr(result.content, 'text'):
                        return {"result": result.content.text}

                return {"result": str(result)}
        except Exception as e:
            logger.error(f"Error calling MCP tool {tool_name}: {e}")
            return {"error": str(e)}

    def cleanup(self):
        """Cleanup MCP client"""
        self.client = None
        self._initialized = False


class MultiAgentSystem:
    """Multi-agent system using LlamaStack"""

    def __init__(self, llama_stack_url: str, mcp_manager: MCPManager, vector_store_id: Optional[str] = None, config_data: dict = None):
        self.llama_stack_url = llama_stack_url
        self.mcp_manager = mcp_manager
        self.vector_store_id = vector_store_id
        self.client = None
        self._tool_group_ids = []  # List of registered MCP tool group IDs
        self._rag_tool_group_id = None
        self._agent_sessions = {}  # Track agent sessions by user/conversation
        self._config = config_data or {}

        # Load LLM model from config
        llm_config = self._config.get('llm', {})
        self.llm_model = llm_config.get('model', 'openai/gpt-4o')

        # Load agent configurations from config
        config_agents = self._config.get('agents', {})
        if config_agents:
            self.agents = {
                agent_id: {
                    "name": agent_config.get("name", f"Agent {agent_id}"),
                    "description": agent_config.get("description", ""),
                    "system_prompt": agent_config.get("system_prompt", ""),
                    "toolgroups": agent_config.get("toolgroups", []),
                    "keywords": agent_config.get("keywords", [])
                }
                for agent_id, agent_config in config_agents.items()
            }
            logger.info(f"Loaded {len(self.agents)} agents from configuration")
        else:
            # No agents in config - this is an error
            logger.error("No agents found in configuration file!")
            self.agents = {}

    async def initialize(self):
        """Initialize LlamaStack client and configure tool groups"""
        self.client = LlamaStackClient(base_url=self.llama_stack_url)
        logger.info(f"LlamaStack client initialized at {self.llama_stack_url}")

        # Configure RAG tool group if vector store is available
        if self.vector_store_id:
            await self._configure_rag_tool_group()

        # Register MCP tools with LlamaStack
        await self._register_mcp_tools()

    async def _configure_rag_tool_group(self):
        """Configure built-in RAG tool group"""
        try:
            self._rag_tool_group_id = "builtin::rag"
            logger.info(f"RAG tool group configured with vector store: {self.vector_store_id}")
        except Exception as e:
            logger.error(f"Failed to configure RAG tool group: {e}")
            import traceback
            traceback.print_exc()

    async def _register_mcp_tools(self):
        """Register MCP toolgroups from config with LlamaStack"""
        try:
            # Get MCP server configurations from config
            mcp_config = self._config.get('mcp', {})
            mcp_servers = mcp_config.get('servers', {})

            if not mcp_servers:
                logger.warning("No MCP servers configured")
                return

            # Register each MCP server as a separate toolgroup
            for server_name, server_config in mcp_servers.items():
                try:
                    url = server_config.get('url')
                    if not url:
                        logger.warning(f"No URL specified for MCP server '{server_name}', skipping")
                        continue

                    # Generate toolgroup ID from server name (use mcp:: prefix per LlamaStack docs)
                    tool_group_id = f"mcp::{server_name}"

                    logger.info(f"Registering MCP server '{server_name}' as toolgroup '{tool_group_id}'")
                    logger.info(f"  URL: {url}")

                    # Unregister first if it exists, then register fresh
                    try:
                        self.client.toolgroups.unregister(toolgroup_id=tool_group_id)
                        logger.info(f"Unregistered existing toolgroup '{tool_group_id}'")
                    except Exception as unreg_error:
                        # Toolgroup might not exist yet, that's fine
                        logger.debug(f"Could not unregister '{tool_group_id}': {unreg_error}")

                    # Register the toolgroup with LlamaStack
                    self.client.toolgroups.register(
                        toolgroup_id=tool_group_id,
                        provider_id="model-context-protocol",
                        mcp_endpoint={
                            "uri": url
                        }
                    )
                    logger.info(f"Successfully registered toolgroup '{tool_group_id}'")

                    # Add to list of registered tool groups
                    self._tool_group_ids.append(tool_group_id)

                except Exception as e:
                    logger.error(f"Failed to register MCP server '{server_name}': {e}")
                    import traceback
                    traceback.print_exc()
                    # Continue with other servers

            if self._tool_group_ids:
                logger.info(f"Successfully registered {len(self._tool_group_ids)} MCP toolgroups: {self._tool_group_ids}")
            else:
                logger.warning("No MCP toolgroups were successfully registered")

        except Exception as e:
            logger.error(f"Error during MCP tool registration: {e}")
            import traceback
            traceback.print_exc()


    def _select_agent(self, message: str, agent_type: Optional[str] = None) -> str:
        """Select appropriate agent based on message content"""
        if agent_type and agent_type != "auto":
            return agent_type

        # Simple keyword-based routing using each agent's keywords
        message_lower = message.lower()

        # Score each agent based on keyword matches
        agent_scores = {}
        for agent_id, agent_config in self.agents.items():
            keywords = agent_config.get("keywords", [])
            score = sum(1 for kw in keywords if kw in message_lower)
            agent_scores[agent_id] = score

        # Return agent with highest score, or first agent if tie
        if agent_scores:
            best_agent = max(agent_scores.items(), key=lambda x: x[1])
            return best_agent[0]

        # Fallback to first agent if no scores
        return next(iter(self.agents.keys())) if self.agents else "lab_content"


    async def chat(
        self,
        message: str,
        conversation_history: List[ConversationMessage],
        agent_type: Optional[str] = None,
        include_mcp: bool = True,
        page_context: Optional[str] = None
    ) -> AsyncGenerator[str, None]:
        """Generate streaming chat response with selected agent"""

        # Select agent
        selected_agent = self._select_agent(message, agent_type)
        agent_config = self.agents[selected_agent]

        agent_name = agent_config["name"]
        yield f"data: {json.dumps({'status': f'Using {agent_name}...'})}\n\n"
        await asyncio.sleep(0.1)

        # Build system prompt
        system_prompt = agent_config["system_prompt"]
        if page_context:
            system_prompt += f"\n\nCURRENT PAGE: {page_context}"

        # Note: RAG context is now handled automatically by the builtin::rag tool group

        # Generate response
        yield f"data: {json.dumps({'status': 'Generating response...'})}\n\n"

        # Use LlamaStack Agents API
        async for chunk in self._stream_with_llamastack_agents(
            message,
            conversation_history,
            system_prompt,
            selected_agent,
            include_mcp
        ):
            yield chunk

    async def _stream_with_llamastack_agents(
        self,
        message: str,
        conversation_history: List[ConversationMessage],
        system_prompt: str,
        agent_type: str,
        include_mcp: bool
    ) -> AsyncGenerator[str, None]:
        """Stream response using LlamaStack Agents API"""
        import hashlib

        # Generate session ID from conversation context
        conv_data = json.dumps([{"role": msg.role, "content": msg.content[:100]} for msg in conversation_history[-5:]])
        conv_hash = hashlib.md5(conv_data.encode()).hexdigest()[:16]
        session_id = f"{agent_type}-{conv_hash}"

        try:
            # Get agent configuration
            agent_config = self.agents.get(agent_type, {})
            configured_toolgroups = agent_config.get("toolgroups", [])

            # Build tool groups based on agent's configured toolgroups
            tool_groups = []

            for toolgroup in configured_toolgroups:
                if toolgroup == "rag":
                    # Add RAG toolgroup with vector store configuration
                    if self.vector_store_id:
                        tool_groups.append({
                            "name": "builtin::rag/knowledge_search",
                            "args": {"vector_db_ids": [self.vector_store_id]}
                        })
                        logger.info(f"Including RAG toolgroup: builtin::rag/knowledge_search with vector store {self.vector_store_id}")
                elif toolgroup.startswith("mcp::"):
                    # Add MCP toolgroup if it's registered and MCP is enabled
                    if include_mcp and toolgroup in self._tool_group_ids:
                        # MCP toolgroups are referenced by string name only (not dict)
                        tool_groups.append(toolgroup)
                        logger.info(f"Including MCP toolgroup: {toolgroup}")

            logger.info(f"Agent '{agent_type}' configured with toolgroups: {tool_groups}")

            # Create or get agent session
            session, agent_id = await create_or_get_agent_session(
                self.client,
                session_id=session_id,
                agent_config_name=agent_type,
                system_prompt=system_prompt,
                tool_groups=tool_groups if tool_groups else None,
                model=self.llm_model
            )

            # Stream the agent turn using the actual session ID from the created session
            async for event in stream_agent_turn(
                self.client,
                agent_id=agent_id,
                session_id=session.session_id,
                user_message=message,
                stream=True
            ):
                # Format event for SSE
                formatted = format_agent_event_for_sse(event)
                if formatted:
                    yield f"data: {formatted}\n\n"

        except Exception as e:
            logger.error(f"LlamaStack agents error: {e}")
            import traceback
            traceback.print_exc()
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

    def _generate_attribution(self, sources: List[Dict]) -> str:
        """Generate source attribution"""
        if not sources:
            return ""

        workshop_sources = [s for s in sources if s['content_type'] != 'pdf-documentation']
        pdf_sources = [s for s in sources if s['content_type'] == 'pdf-documentation']

        parts = []

        if workshop_sources:
            links = []
            seen = set()
            for source in workshop_sources[:5]:
                title = source['title']
                file_path = source.get('file_path', '')

                # Convert to HTML URL
                if file_path.endswith('.adoc'):
                    filename = Path(file_path).stem
                    html_url = f"{filename}.html"

                    if title not in seen:
                        seen.add(title)
                        links.append(f'link:{html_url}[*{title}*]')

            if links:
                parts.append("RELEVANT WORKSHOP LINKS:\n" + "\n".join(links))

        if pdf_sources:
            pdf_names = list(set(s['title'] for s in pdf_sources[:3]))
            if pdf_names:
                parts.append("TECHDOC REFERENCES:\n" + "\n".join(pdf_names))

        if parts:
            return "\n\n---\n\n" + "\n\n".join(parts)

        return ""


# Global instances
mcp_manager = None
agent_system = None


# Application lifespan
@asynccontextmanager
async def lifespan(app):
    """Application startup and shutdown"""
    global mcp_manager, agent_system

    logger.info("Application starting up...")

    # Initialize LlamaStack client for vector store initialization
    llama_client = LlamaStackClient(base_url=config.LLAMA_STACK_URL)

    # Initialize vector store with workshop documents
    vector_store_id = await initialize_vector_store(
        llama_client,
        config.CONTENT_DIR,
        config.PDF_DIR,
        config.MIN_CHUNK_SIZE,
        config.EMBEDDING_MODEL
    )
    logger.info(f"Vector store initialized: {vector_store_id}")

    # Load MCP config
    mcp_config = config.config_data.get('mcp', {})
    if 'servers' in mcp_config:
        # Transform to mcpServers format
        cleaned_servers = {}
        for server_name, server_config in mcp_config['servers'].items():
            # Check if this is a remote server (has 'url') or stdio server (has 'command')
            if 'url' in server_config:
                # Remote MCP server
                cleaned_servers[server_name] = {
                    "url": server_config["url"]
                }
            else:
                # Stdio MCP server
                cleaned_servers[server_name] = {
                    "command": server_config.get("command"),
                    "args": server_config.get("args", []),
                    "env": server_config.get("env", {})
                }

        mcp_config = {"mcpServers": cleaned_servers}

    # Initialize MCP manager
    mcp_manager = MCPManager(mcp_config)
    await mcp_manager.initialize()

    # Initialize agent system with vector store ID and config
    agent_system = MultiAgentSystem(
        config.LLAMA_STACK_URL,
        mcp_manager,
        vector_store_id,
        config.config_data  # Pass the full config data
    )
    await agent_system.initialize()

    logger.info("Application startup complete")

    yield

    # Shutdown
    logger.info("Application shutting down...")
    if mcp_manager:
        mcp_manager.cleanup()


# FastAPI app
app = FastAPI(
    title="Showroom AI Assistant Backend v2",
    description="Multi-agent AI Assistant with LlamaStack, RAG, and MCP integration",
    version="2.0.0",
    lifespan=lifespan
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# API Routes
@app.post("/api/chat/stream")
async def stream_chat(chat_request: ChatRequest):
    """Stream chat responses with multi-agent support"""

    async def generate():
        yield "data: {\"status\": \"starting\"}\n\n"
        await asyncio.sleep(0)

        async for chunk in agent_system.chat(
            chat_request.message,
            chat_request.conversation_history,
            chat_request.agent_type,
            chat_request.include_mcp,
            chat_request.page_context
        ):
            yield chunk
            await asyncio.sleep(0)  # Force flush

        yield "data: {\"status\": \"complete\"}\n\n"
        await asyncio.sleep(0)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


@app.get("/api/agents")
async def get_agents():
    """Get available agents"""
    return {
        "agents": [
            {
                "id": agent_id,
                "name": config["name"],
                "description": config["description"]
            }
            for agent_id, config in agent_system.agents.items()
        ]
    }


@app.get("/api/mcp/tools")
async def get_mcp_tools():
    """Get available MCP tools"""
    tools = await mcp_manager.get_tools()
    return {"tools": tools}


@app.get("/api/health")
async def health_check():
    """Health check endpoint"""
    errors = []

    # Check if agent system is initialized
    if not agent_system or not agent_system.client:
        errors.append("Agent system not initialized")

    # Check if LlamaStack is reachable
    llama_stack_healthy = False
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(f"{config.LLAMA_STACK_URL}/v1/models")
            llama_stack_healthy = response.status_code == 200
    except Exception as e:
        errors.append(f"LlamaStack unreachable: {str(e)}")

    # Check if MCP manager initialized
    if mcp_manager and not mcp_manager._initialized:
        errors.append("MCP manager not initialized")

    # Check if MCP toolgroups were registered (if MCP is configured)
    mcp_config = config.config_data.get('mcp', {})
    if mcp_config.get('servers'):
        if not agent_system or not agent_system._tool_group_ids:
            errors.append("MCP servers configured but no toolgroups registered")

    # Check if vector store initialized
    if not agent_system or not agent_system.vector_store_id:
        errors.append("Vector store not initialized")

    # Determine overall health
    is_healthy = len(errors) == 0

    response_data = {
        "status": "healthy" if is_healthy else "unhealthy",
        "version": "2.0.0",
        "llama_stack": {
            "enabled": True,
            "url": config.LLAMA_STACK_URL,
            "healthy": llama_stack_healthy
        },
        "vector_store": agent_system.vector_store_id if agent_system else None,
        "rag_enabled": agent_system._rag_tool_group_id is not None if agent_system else False,
        "agents": list(agent_system.agents.keys()) if agent_system else [],
        "mcp_initialized": mcp_manager._initialized if mcp_manager else False,
        "mcp_toolgroups": agent_system._tool_group_ids if agent_system else []
    }

    if errors:
        response_data["errors"] = errors
        raise HTTPException(status_code=503, detail=response_data)

    return response_data


@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "service": "showroom-assistant-backend",
        "version": "2.0.0",
        "status": "running"
    }


if __name__ == "__main__":
    import uvicorn
    import os
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
        log_level="info",
        timeout_keep_alive=75
    )
