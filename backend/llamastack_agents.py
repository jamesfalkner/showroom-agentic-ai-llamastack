#!/usr/bin/env python3
"""
LlamaStack Agents API integration
Functions for using LlamaStack's agents API with MCP tools
"""
import json
import logging
from typing import List, Dict, Optional, AsyncGenerator

logger = logging.getLogger(__name__)


async def create_or_get_agent_session(
    client,
    session_id: str,
    agent_config_name: str,
    system_prompt: str,
    tool_groups: Optional[List[Dict]] = None,
    model: str = "openai/gpt-4o"
):
    """Create or get an existing agent session

    Workflow:
    1. Register agent config if not exists
    2. Create session for that agent

    Args:
        client: LlamaStackClient instance
        session_id: Unique session identifier
        agent_config_name: Name for the agent configuration
        system_prompt: System prompt for the agent
        tool_groups: List of toolgroups to enable
        model: LLM model to use (e.g., "openai/gpt-4o")

    Returns: (session, agent_id)
    """
    try:
        import time
        # Step 1: Create/register agent config
        from llama_stack_client.types import AgentConfig, SamplingParams

        # Build sampling params
        sampling_params = SamplingParams(
            strategy={"type": "greedy"},
            max_tokens=2000
        )

        # Build agent config params
        config_params = {
            "model": model,
            "instructions": system_prompt,
            "sampling_params": sampling_params
        }

        # Build tool_config
        tool_config = {
            "tool_prompt_format": "json",
            "tool_choice": "auto"
        }

        # Add tool groups if available
        if tool_groups:
            config_params["enable_session_persistence"] = True
            config_params["toolgroups"] = tool_groups
            logger.info(f"Configuring agent with toolgroups: {tool_groups}")

        # Set tool_config
        config_params["tool_config"] = tool_config

        # Create the agent config
        logger.info(f"Creating agent config with params: {config_params}")
        agent_config = AgentConfig(**config_params)

        # Register the agent config (or it might already exist)
        try:
            agent_response = client.alpha.agents.create(agent_config=agent_config)
            agent_id = agent_response.agent_id
            logger.info(f"Registered agent: {agent_id}")
        except Exception as e:
            # Agent might already exist, use the agent_config_name as agent_id
            logger.warning(f"Agent registration returned: {e}, using agent_config_name as agent_id")
            agent_id = agent_config_name

        # Step 2: Create session for this agent with unique timestamp
        unique_session_id = f"{session_id}-{int(time.time() * 1000)}"
        session = client.alpha.agents.session.create(
            agent_id=agent_id,
            session_name=unique_session_id
        )

        logger.info(f"Created agent session: {unique_session_id} for agent: {agent_id}")
        return session, agent_id

    except Exception as e:
        logger.error(f"Session creation failed: {e}")
        import traceback
        traceback.print_exc()
        raise


async def stream_agent_turn(
    client,
    agent_id: str,
    session_id: str,
    user_message: str,
    stream: bool = True
) -> AsyncGenerator[Dict, None]:
    """Create an agent turn and stream the response"""
    try:
        # Create the turn
        response = client.alpha.agents.turn.create(
            agent_id=agent_id,
            session_id=session_id,
            messages=[
                {
                    "role": "user",
                    "content": user_message
                }
            ],
            stream=stream
        )

        # Stream the response
        # The LlamaStack SDK returns a synchronous Stream object
        if stream:
            for event in response:
                # DEBUG: Log the actual event structure
                logger.info(f"Event type: {type(event).__name__}")
                logger.info(f"Event repr: {repr(event)}")

                # Try to log the event as dict if possible
                if hasattr(event, 'model_dump'):
                    logger.info(f"Event data: {event.model_dump()}")

                yield event
        else:
            yield response

    except Exception as e:
        logger.error(f"Error creating agent turn: {e}")
        import traceback
        traceback.print_exc()
        raise


def format_agent_event_for_sse(chunk) -> Optional[str]:
    """Format an agent event for Server-Sent Events (SSE)"""
    try:
        # LlamaStack returns AgentTurnResponseStreamChunk objects
        # These have 'event' and 'error' fields

        # Check for errors first
        if hasattr(chunk, 'error') and chunk.error:
            error_msg = chunk.error.get('message', str(chunk.error)) if isinstance(chunk.error, dict) else str(chunk.error)
            return json.dumps({'error': error_msg})

        # Get the actual event from the chunk
        if hasattr(chunk, 'event') and chunk.event:
            event = chunk.event
            # Check if event has payload (v0.3.2 structure)
            payload = getattr(event, 'payload', event)
            event_type = getattr(payload, 'event_type', type(event).__name__)

            logger.info(f"Processing event type: {event_type}")

            # Handle different event types
            if event_type == 'turn_start' or 'TurnStart' in event_type:
                return json.dumps({'status': 'Agent is thinking...'})

            elif event_type == 'turn_complete' or 'TurnComplete' in event_type:
                return json.dumps({'status': 'Complete'})

            elif event_type == 'step_start' or 'StepStart' in event_type:
                step_type = getattr(payload, 'step_type', '')
                if 'inference' in str(step_type).lower():
                    return json.dumps({'status': 'Generating response...'})
                elif 'tool' in str(step_type).lower():
                    return json.dumps({'status': 'Executing tool...'})

            elif event_type == 'step_progress' or 'StepProgress' in event_type:
                # Check for content delta in payload
                if hasattr(payload, 'delta'):
                    delta = payload.delta
                    if isinstance(delta, str):
                        return json.dumps({'content': delta})
                    elif hasattr(delta, 'text'):
                        return json.dumps({'content': delta.text})
                    elif hasattr(delta, 'content'):
                        return json.dumps({'content': delta.content})

            elif event_type == 'step_complete' or 'StepComplete' in event_type:
                # Final response - check payload for step_details
                if hasattr(payload, 'step_details'):
                    details = payload.step_details

                    # Tool execution results - check for knowledge_search responses first
                    if hasattr(details, 'tool_responses'):
                        # Match tool_calls with tool_responses to find knowledge_search results
                        tool_calls_map = {}
                        if hasattr(details, 'tool_calls'):
                            for tool_call in details.tool_calls:
                                if hasattr(tool_call, 'call_id') and hasattr(tool_call, 'tool_name'):
                                    tool_calls_map[tool_call.call_id] = tool_call.tool_name

                        sources = []
                        sources_seen = set()  # Track unique sources

                        for tool_response in details.tool_responses:
                            # Check if this is a knowledge_search response
                            call_id = getattr(tool_response, 'call_id', None)
                            is_knowledge_search = (call_id and call_id in tool_calls_map and
                                                 'knowledge_search' in str(tool_calls_map[call_id]))

                            if is_knowledge_search and hasattr(tool_response, 'content'):
                                # Parse text content to extract source info
                                for content_item in tool_response.content:
                                    if hasattr(content_item, 'text'):
                                        text = content_item.text
                                        # Look for result chunks with metadata
                                        import re
                                        # Pattern: Result N\nContent: ...\nMetadata: {...}
                                        results = re.findall(r'Result \d+\nContent:\s*(.*?)\nMetadata:', text, re.DOTALL)
                                        for result_text in results:
                                            # Extract title and source from content header
                                            # Format: [Module - Title]\nSource: file_path\n
                                            header_match = re.search(r'\[(.*?)\s*-\s*(.*?)\]\s*Source:\s*([^\n]+)', result_text)
                                            if header_match:
                                                module = header_match.group(1).strip()
                                                title = header_match.group(2).strip()
                                                file_path = header_match.group(3).strip()

                                                # Create unique key to avoid duplicates
                                                source_key = f"{title}|{file_path}"
                                                if source_key not in sources_seen:
                                                    sources_seen.add(source_key)
                                                    sources.append({
                                                        'title': title,
                                                        'url': file_path,
                                                        'content_type': 'pdf-documentation' if file_path.endswith('.pdf') else 'workshop-content'
                                                    })

                        # Send sources if found
                        if sources:
                            logger.info(f"Extracted {len(sources)} sources from knowledge_search")
                            return json.dumps({'sources': sources[:10]})  # Limit to 10 sources

                    # Check for final text response in inference steps
                    if hasattr(details, 'text'):
                        return json.dumps({'content': details.text})
                    elif hasattr(details, 'content'):
                        return json.dumps({'content': details.content})

            # For any event with a text/content attribute
            if hasattr(event, 'text'):
                return json.dumps({'content': event.text})
            elif hasattr(event, 'content'):
                return json.dumps({'content': event.content})

        return None

    except Exception as e:
        logger.warning(f"Error formatting event: {e}")
        import traceback
        traceback.print_exc()
        return None
