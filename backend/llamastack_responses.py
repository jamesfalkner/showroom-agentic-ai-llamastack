#!/usr/bin/env python3
"""
LlamaStack Responses API integration
Functions for using LlamaStack's modern Responses API with MCP tools and RAG
"""
import json
import logging
import re
from typing import List, Dict, Optional, AsyncGenerator

logger = logging.getLogger(__name__)


def _strip_inline_citations(text: str) -> str:
    """
    Remove inline file citations from text.

    The Responses API with file_search automatically inserts citations like:
    - <|file-abc123|>
    - 【35†source】

    Since we display sources separately, we strip these out.
    """
    # Remove <|file-id|> style citations
    text = re.sub(r'<\|file-[a-f0-9-]+\|>', '', text)

    # Remove 【number†source】 style citations (traditional format)
    text = re.sub(r'【\d+†[^】]+】', '', text)

    return text


async def stream_response(
    client,
    model: str,
    user_message: str,
    instructions: str,
    tools: Optional[List[Dict]] = None,
    previous_response_id: Optional[str] = None
) -> AsyncGenerator[Dict, None]:
    """Create a streaming response using the Responses API

    Args:
        client: LlamaStackClient instance
        model: LLM model to use (e.g., "openai/gpt-4o")
        user_message: User's message/input
        instructions: System instructions/prompt
        tools: List of tool configurations (MCP tools, RAG tools, etc.)
        previous_response_id: ID of previous response for multi-turn conversations

    Yields: Response events from the Responses API
    """
    try:
        # Build the request parameters
        request_params = {
            "model": model,
            "input": user_message,
            "instructions": instructions,
            "stream": True
        }

        # Add tools if provided
        if tools:
            request_params["tools"] = tools
            logger.info(f"Configuring response with {len(tools)} tools")

        # Add previous response ID for multi-turn conversations
        if previous_response_id:
            request_params["previous_response_id"] = previous_response_id

        # Create the streaming response
        logger.info(f"Creating Responses API request with model: {model}")
        response = client.responses.create(**request_params)

        # Stream the response
        # The LlamaStack SDK returns a synchronous Stream object
        for event in response:
            # DEBUG: Log the actual event structure
            logger.info(f"Event type: {type(event).__name__}")
            logger.info(f"Event repr: {repr(event)}")

            # Try to log the event as dict if possible
            if hasattr(event, 'model_dump'):
                logger.info(f"Event data: {event.model_dump()}")

            yield event

    except Exception as e:
        logger.error(f"Error creating response: {e}")
        import traceback
        traceback.print_exc()
        raise


def format_response_event_for_sse(chunk) -> Optional[str]:
    """Format a Responses API event for Server-Sent Events (SSE)

    The Responses API returns OpenAI-compatible streaming events.
    This function converts them to the SSE format expected by the frontend.
    """
    try:
        # The chunk is the event itself with a 'type' field
        event_type = getattr(chunk, 'type', None)

        if not event_type:
            logger.debug(f"Event has no type field, skipping: {type(chunk).__name__}")
            return None

        logger.debug(f"Processing event type: {event_type}")

        # Handle reasoning text deltas (thinking/reasoning content)
        if event_type == 'response.reasoning_text.delta':
            delta = getattr(chunk, 'delta', None)
            if delta:
                # Strip inline file citations (format: <|file-id|>)
                cleaned_delta = _strip_inline_citations(delta)
                if cleaned_delta:
                    return json.dumps({'content': cleaned_delta})

        # Handle output text deltas (final response content)
        elif event_type == 'response.output_text.delta':
            delta = getattr(chunk, 'delta', None)
            if delta:
                # Strip inline file citations (format: <|file-id|>)
                cleaned_delta = _strip_inline_citations(delta)
                if cleaned_delta:
                    return json.dumps({'content': cleaned_delta})

        # Handle response creation
        elif event_type == 'response.created':
            return json.dumps({'status': 'Response started...'})

        # Handle response completion
        elif event_type == 'response.done':
            return json.dumps({'status': 'Complete'})

        # Handle response failure
        elif event_type == 'response.failed':
            # Extract error information
            error_info = getattr(chunk, 'error', None)
            if error_info:
                error_code = getattr(error_info, 'code', 'unknown_error')
                error_message = getattr(error_info, 'message', 'An error occurred')
                logger.error(f"Response failed: {error_code} - {error_message}")
                return json.dumps({'error': f"{error_message} (Error code: {error_code})"})
            else:
                return json.dumps({'error': 'Response failed with unknown error'})

        # Handle output item start (e.g., message output starting)
        elif event_type == 'response.output_item.added':
            return json.dumps({'status': 'Generating response...'})

        # Handle content part boundaries
        elif event_type == 'response.content_part.added':
            # A new content part is being added (e.g., reasoning vs output)
            part = getattr(chunk, 'part', None)
            part_type = getattr(part, 'type', None) if part else None
            logger.debug(f"Content part added: {part_type}")
            # Don't send status for this - just structural marker
            return None

        elif event_type == 'response.content_part.done':
            # Content part completed
            part = getattr(chunk, 'part', None)
            part_type = getattr(part, 'type', None) if part else None
            logger.debug(f"Content part done: {part_type}")
            # Don't send status for this - just structural marker
            return None

        # Handle MCP events
        elif event_type == 'response.mcp_list_tools.in_progress':
            return json.dumps({'status': 'Loading tools...'})

        elif event_type == 'response.mcp_list_tools.completed':
            return json.dumps({'status': 'Tools loaded'})

        elif event_type == 'response.mcp_call.in_progress':
            return json.dumps({'status': 'Calling tool...'})

        elif event_type == 'response.mcp_call.completed':
            return json.dumps({'status': 'Tool execution complete'})

        # Handle file search events
        elif event_type == 'response.file_search_call.in_progress':
            return json.dumps({'status': 'Searching knowledge base...'})

        elif event_type == 'response.file_search_call.searching':
            return json.dumps({'status': 'Searching documents...'})

        elif event_type == 'response.file_search_call.completed':
            # File search completed - extract sources
            logger.info(f"File search completed, extracting sources")
            logger.info(f"Event data: {chunk.model_dump() if hasattr(chunk, 'model_dump') else chunk}")

            # Extract results from the completed file search
            sources = []

            # The results should be in chunk.results or chunk.file_search_call.results
            results = None
            if hasattr(chunk, 'results'):
                results = chunk.results
            elif hasattr(chunk, 'file_search_call'):
                file_search_call = chunk.file_search_call
                if hasattr(file_search_call, 'results'):
                    results = file_search_call.results

            if results:
                logger.info(f"Found {len(results) if isinstance(results, list) else 1} file search results")

                # Process each result
                if isinstance(results, list):
                    for result in results[:10]:  # Limit to 10 sources
                        # Extract file name/title and content
                        file_name = getattr(result, 'file_name', None) or getattr(result, 'name', 'Unknown')
                        file_id = getattr(result, 'file_id', None)
                        content = getattr(result, 'content', None)

                        # Create source entry
                        sources.append({
                            'title': file_name,
                            'url': f'/files/{file_id}' if file_id else '#',
                            'content_type': 'file-search-result'
                        })

            if sources:
                logger.info(f"Extracted {len(sources)} sources from file_search_call.completed")
                return json.dumps({'sources': sources})
            else:
                logger.warning("File search completed but no results found in event")
                return None

        # Handle output item done (contains file search results)
        elif event_type == 'response.output_item.done':
            # Check if this is a file search result
            item = getattr(chunk, 'item', None)
            if item and getattr(item, 'type', None) == 'file_search_call':
                results = getattr(item, 'results', [])

                if results:
                    logger.info(f"Found {len(results)} file search results in output_item.done")
                    sources = []

                    for result in results[:10]:  # Limit to 10 sources
                        text = getattr(result, 'text', '')

                        # Parse the metadata header that was embedded during RAG initialization
                        # Format: [module - title]\nSource: /path/to/file\n\n...

                        # Extract title and source from the standardized header format
                        header_match = re.match(r'\[(.*?)\]\s*\nSource:\s*([^\n]+)', text)

                        if header_match:
                            # Parse the bracketed part: [modules - ROOT - Title] or [PDF Documentation - Title]
                            full_title = header_match.group(1)
                            source_url = header_match.group(2).strip()

                            # Extract just the title (last part after last dash)
                            title_parts = full_title.split(' - ')
                            title = title_parts[-1].strip() if title_parts else full_title.strip()

                            # Determine content type from the source URL
                            if source_url.endswith('.pdf') or '/_/techdocs/' in source_url:
                                content_type = 'pdf-documentation'
                            else:
                                content_type = 'workshop-content'

                            sources.append({
                                'title': title,
                                'url': source_url,
                                'content_type': content_type
                            })
                        else:
                            # No metadata header found - skip this result
                            logger.warning(f"Could not parse metadata from result text: {text[:100]}")
                            continue

                    if sources:
                        logger.info(f"Extracted {len(sources)} sources from file search")
                        return json.dumps({'sources': sources})

            return None

        # Handle function calls (generic)
        elif event_type == 'response.function_call_arguments.delta':
            # Tool being called - could show this to user
            return json.dumps({'status': 'Using tools...'})

        elif event_type == 'response.function_call_arguments.done':
            # Generic function call complete
            function_call_id = getattr(chunk, 'call_id', None)
            function_name = getattr(chunk, 'name', None)
            logger.debug(f"Function call completed: {function_name} ({function_call_id})")

        # Handle errors
        elif event_type == 'error':
            error_msg = getattr(chunk, 'error', {}).get('message', 'Unknown error')
            return json.dumps({'error': error_msg})

        # Log unknown event types for debugging
        else:
            logger.debug(f"Unhandled event type: {event_type}")

        return None

    except Exception as e:
        logger.warning(f"Error formatting event: {e}")
        import traceback
        traceback.print_exc()
        return None
