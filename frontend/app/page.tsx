'use client'

import {
  Conversation,
  ConversationContent,
  ConversationScrollButton,
} from '@/components/ui/shadcn-io/ai/conversation'
import { Loader } from '@/components/ui/shadcn-io/ai/loader'
import { Message, MessageAvatar, MessageContent } from '@/components/ui/shadcn-io/ai/message'
import { Sources, SourcesTrigger, SourcesContent, Source } from '@/components/ui/shadcn-io/ai/source'
import {
  PromptInput,
  PromptInputModelSelect,
  PromptInputModelSelectContent,
  PromptInputModelSelectItem,
  PromptInputModelSelectTrigger,
  PromptInputModelSelectValue,
  PromptInputSubmit,
  PromptInputTextarea,
  PromptInputToolbar,
  PromptInputTools,
} from '@/components/ui/shadcn-io/ai/prompt-input'
import { Button } from '@/components/ui/button'
import { MarkdownRenderer } from '@/components/ui/markdown-renderer'
import { RotateCcwIcon } from 'lucide-react'
import { nanoid } from 'nanoid'
import { type FormEventHandler, useCallback, useEffect, useState } from 'react'

type Source = {
  title: string
  url: string
  content_type: string
}

type ChatMessage = {
  id: string
  content: string
  role: 'user' | 'assistant'
  timestamp: Date
  isStreaming?: boolean
  sources?: Source[]
}

type Agent = {
  id: string
  name: string
  description: string
}

// Helper function to convert file paths to URLs
function sourceToUrl(source: Source): string {
  const { url, content_type } = source

  if (content_type === 'pdf-documentation') {
    // PDF files - open in new tab
    return url
  }

  // Workshop pages - convert .adoc to .html
  if (url.endsWith('.adoc')) {
    const filename = url.split('/').pop()?.replace('.adoc', '.html') || ''
    return `/modules/${filename}`
  }

  return url
}

export default function ChatPage() {
  const [messages, setMessages] = useState<ChatMessage[]>([
    {
      id: nanoid(),
      content: "Hello! I'm your workshop AI assistant. I can help you with questions about the workshop content, troubleshooting, and guidance. What would you like to know?",
      role: 'assistant',
      timestamp: new Date()
    }
  ])

  const [inputValue, setInputValue] = useState('')
  const [agents, setAgents] = useState<Agent[]>([])
  const [selectedAgent, setSelectedAgent] = useState('auto')
  const [isStreaming, setIsStreaming] = useState(false)
  const [streamingMessageId, setStreamingMessageId] = useState<string | null>(null)

  // Dynamically construct backend URL based on current hostname
  // Pattern: <service>-<namespace>.<subdomain> -> showroom-ai-assistant-<namespace>.<subdomain>
  const getBackendUrl = () => {
    if (typeof window === 'undefined') {
      return 'http://localhost:8000' // SSR fallback
    }

    const hostname = window.location.hostname

    // For localhost development
    if (hostname === 'localhost' || hostname === '127.0.0.1') {
      return 'http://localhost:8000'
    }

    // For OpenShift/Kubernetes deployment
    // Replace service name with 'showroom-ai-assistant' keeping namespace and subdomain
    // Pattern: <service>-<namespace>.<subdomain> -> showroom-ai-assistant-<namespace>.<subdomain>
    const parts = hostname.split('-')
    if (parts.length >= 2) {
      // Replace first part (service name) with 'showroom-ai-assistant'
      parts[0] = 'showroom-ai-assistant'
      const backendHostname = parts.join('-')
      return `${window.location.protocol}//${backendHostname}`
    }

    // Fallback
    return 'http://localhost:8000'
  }

  const backendUrl = getBackendUrl()

  // Fetch available agents on mount
  useEffect(() => {
    fetch(`${backendUrl}/api/agents`)
      .then(res => res.json())
      .then(data => {
        setAgents(data.agents || [])
      })
      .catch(err => console.error('Failed to fetch agents:', err))
  }, [backendUrl])

  const handleSubmit: FormEventHandler<HTMLFormElement> = useCallback(
    async (event) => {
      event.preventDefault()

      if (!inputValue.trim() || isStreaming) return

      // Add user message
      const userMessage: ChatMessage = {
        id: nanoid(),
        content: inputValue.trim(),
        role: 'user',
        timestamp: new Date()
      }

      setMessages(prev => [...prev, userMessage])
      setInputValue('')
      setIsStreaming(true)

      // Create empty assistant message for streaming
      const assistantMessageId = nanoid()
      const assistantMessage: ChatMessage = {
        id: assistantMessageId,
        content: '',
        role: 'assistant',
        timestamp: new Date(),
        isStreaming: true
      }

      setMessages(prev => [...prev, assistantMessage])
      setStreamingMessageId(assistantMessageId)

      // Build conversation history
      const conversationHistory = messages.map(m => ({
        role: m.role,
        content: m.content
      }))

      try {
        const response = await fetch(`${backendUrl}/api/chat/stream`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: userMessage.content,
            conversation_history: conversationHistory,
            agent_type: selectedAgent,
            include_mcp: true,
            page_context: null
          })
        })

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`)
        }

        const reader = response.body?.getReader()
        const decoder = new TextDecoder()

        if (reader) {
          let buffer = ''
          while (true) {
            const { done, value } = await reader.read()
            if (done) break

            // Decode chunk with stream: true to handle multi-byte characters
            const chunk = decoder.decode(value, { stream: true })
            buffer += chunk

            // Process complete lines
            const lines = buffer.split('\n')
            // Keep the last incomplete line in the buffer
            buffer = lines.pop() || ''

            for (const line of lines) {
              if (line.startsWith('data: ')) {
                const dataStr = line.slice(6)
                try {
                  const data = JSON.parse(dataStr)

                  if (data.content) {
                    // Update the assistant message by appending new content
                    setMessages(prev => {
                      const newMessages = [...prev]
                      const lastMsg = newMessages[newMessages.length - 1]
                      if (lastMsg && lastMsg.role === 'assistant' && lastMsg.id === assistantMessageId) {
                        newMessages[newMessages.length - 1] = {
                          ...lastMsg,
                          content: lastMsg.content + data.content
                        }
                      }
                      return newMessages
                    })
                  }

                  if (data.sources) {
                    // Add sources to the assistant message
                    setMessages(prev => {
                      const newMessages = [...prev]
                      const lastMsg = newMessages[newMessages.length - 1]
                      if (lastMsg && lastMsg.role === 'assistant' && lastMsg.id === assistantMessageId) {
                        newMessages[newMessages.length - 1] = {
                          ...lastMsg,
                          sources: data.sources
                        }
                      }
                      return newMessages
                    })
                  }

                  if (data.error) {
                    console.error('Error from backend:', data.error)
                    setMessages(prev => {
                      const newMessages = [...prev]
                      const lastMsg = newMessages[newMessages.length - 1]
                      if (lastMsg && lastMsg.role === 'assistant' && lastMsg.id === assistantMessageId) {
                        newMessages[newMessages.length - 1] = {
                          ...lastMsg,
                          content: lastMsg.content + `\n\nError: ${data.error}`
                        }
                      }
                      return newMessages
                    })
                  }
                } catch (e) {
                  // Ignore JSON parse errors
                }
              }
            }
          }
        }

        // Mark streaming as complete
        setMessages(prev => {
          const newMessages = [...prev]
          const lastMsg = newMessages[newMessages.length - 1]
          if (lastMsg && lastMsg.id === assistantMessageId) {
            newMessages[newMessages.length - 1] = {
              ...lastMsg,
              isStreaming: false
            }
          }
          return newMessages
        })

      } catch (error) {
        console.error('Error:', error)
        setMessages(prev => {
          const newMessages = [...prev]
          const lastMsg = newMessages[newMessages.length - 1]
          if (lastMsg && lastMsg.id === assistantMessageId) {
            newMessages[newMessages.length - 1] = {
              ...lastMsg,
              content: 'Sorry, I encountered an error. Please try again.',
              isStreaming: false
            }
          }
          return newMessages
        })
      } finally {
        setIsStreaming(false)
        setStreamingMessageId(null)
      }
    },
    [inputValue, isStreaming, messages, selectedAgent, backendUrl]
  )

  const handleReset = useCallback(() => {
    setMessages([
      {
        id: nanoid(),
        content: "Hello! I'm your workshop AI assistant. I can help you with questions about the workshop content, troubleshooting, and guidance. What would you like to know?",
        role: 'assistant',
        timestamp: new Date()
      }
    ])
    setInputValue('')
    setIsStreaming(false)
    setStreamingMessageId(null)
  }, [])

  // Find selected agent name for display
  const selectedAgentName = selectedAgent === 'auto'
    ? 'Auto-select'
    : agents.find(a => a.id === selectedAgent)?.name || 'Unknown'

  return (
    <div className="flex h-full w-full flex-col overflow-hidden bg-background">
      {/* Header */}
      <div className="flex items-center justify-between border-b bg-muted/50 px-4 py-3 flex-shrink-0">
        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2">
            <div className="size-2 rounded-full bg-green-500" />
            <span className="font-medium text-sm">Workshop AI Assistant</span>
          </div>
          <div className="h-4 w-px bg-border" />
          <span className="text-muted-foreground text-xs">
            {selectedAgentName}
          </span>
        </div>
        <Button
          variant="ghost"
          size="sm"
          onClick={handleReset}
          className="h-8 px-2"
        >
          <RotateCcwIcon className="size-4" />
          <span className="ml-1">Reset</span>
        </Button>
      </div>

      {/* Conversation Area */}
      <Conversation className="flex-1 min-h-0">
        <ConversationContent className="space-y-4">
          {messages.map((message) => (
            <div key={message.id} className="space-y-3">
              <Message from={message.role}>
                <MessageContent>
                  {message.isStreaming && message.content === '' ? (
                    <div className="flex items-center gap-2">
                      <Loader size={14} />
                      <span className="text-muted-foreground text-sm">Thinking...</span>
                    </div>
                  ) : (
                    <>
                      <MarkdownRenderer>{message.content}</MarkdownRenderer>
                      {message.sources && message.sources.length > 0 && (
                        <Sources className="mt-4">
                          <SourcesTrigger count={message.sources.length} />
                          <SourcesContent>
                            {message.sources.map((source, idx) => (
                              <Source
                                key={idx}
                                href={sourceToUrl(source)}
                                title={source.title}
                              />
                            ))}
                          </SourcesContent>
                        </Sources>
                      )}
                    </>
                  )}
                </MessageContent>
                <MessageAvatar
                  src={message.role === 'user' ? 'https://github.com/shadcn.png' : '/_/img/favicon.ico'}
                  name={message.role === 'user' ? 'User' : 'AI'}
                  className={message.role === 'assistant' ? 'size-8 ring-0' : undefined}
                />
              </Message>
            </div>
          ))}
        </ConversationContent>
        <ConversationScrollButton />
      </Conversation>

      {/* Input Area */}
      <div className="border-t p-4 flex-shrink-0">
        <PromptInput onSubmit={handleSubmit}>
          <PromptInputTextarea
            value={inputValue}
            onChange={(e) => setInputValue(e.target.value)}
            placeholder="Ask me anything about the workshop..."
            disabled={isStreaming}
          />
          <PromptInputToolbar>
            <PromptInputTools>
              <PromptInputModelSelect
                value={selectedAgent}
                onValueChange={setSelectedAgent}
                disabled={isStreaming}
              >
                <PromptInputModelSelectTrigger>
                  <PromptInputModelSelectValue />
                </PromptInputModelSelectTrigger>
                <PromptInputModelSelectContent>
                  <PromptInputModelSelectItem value="auto">
                    Auto-select
                  </PromptInputModelSelectItem>
                  {agents.map((agent) => (
                    <PromptInputModelSelectItem key={agent.id} value={agent.id}>
                      {agent.name}
                    </PromptInputModelSelectItem>
                  ))}
                </PromptInputModelSelectContent>
              </PromptInputModelSelect>
            </PromptInputTools>
            <PromptInputSubmit
              disabled={!inputValue.trim() || isStreaming}
              status={isStreaming ? 'streaming' : 'ready'}
            />
          </PromptInputToolbar>
        </PromptInput>
      </div>
    </div>
  )
}
