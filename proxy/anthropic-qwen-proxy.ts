type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue }

type AnthropicTextBlock = {
  type: 'text'
  text: string
}

type AnthropicImageBlock = {
  type: 'image'
  source?: {
    type?: 'base64' | 'url'
    media_type?: string
    data?: string
    url?: string
  }
}

type AnthropicToolUseBlock = {
  type: 'tool_use'
  id: string
  name: string
  input: unknown
}

type AnthropicToolResultBlock = {
  type: 'tool_result'
  tool_use_id: string
  is_error?: boolean
  content?: string | AnthropicContentBlock[]
}

type AnthropicThinkingBlock = {
  type: 'thinking'
  thinking: string
  signature?: string
}

type AnthropicRedactedThinkingBlock = {
  type: 'redacted_thinking'
  data: string
}

type AnthropicContentBlock =
  | AnthropicTextBlock
  | AnthropicImageBlock
  | AnthropicToolUseBlock
  | AnthropicToolResultBlock
  | AnthropicThinkingBlock
  | AnthropicRedactedThinkingBlock
  | { type: string;[key: string]: unknown }

type AnthropicMessage = {
  role: 'user' | 'assistant'
  content: string | AnthropicContentBlock[]
}

type AnthropicTool = {
  name: string
  description?: string
  input_schema?: Record<string, unknown>
  strict?: boolean
}

type AnthropicToolChoice =
  | { type: 'auto' | 'any' | 'none' }
  | { type: 'tool'; name: string }

type AnthropicRequest = {
  model?: string
  messages?: AnthropicMessage[]
  system?: string | AnthropicContentBlock[]
  tools?: AnthropicTool[]
  tool_choice?: AnthropicToolChoice
  max_tokens?: number
  temperature?: number
  stop_sequences?: string[]
  stream?: boolean
  metadata?: Record<string, unknown>
  thinking?: { type?: string; budget_tokens?: number }
  output_config?: {
    format?: {
      type?: 'json_schema'
      schema?: Record<string, unknown>
    }
    task_budget?: { total?: number; remaining?: number }
    effort?: string
  }
}

type OpenAIChatMessage =
  | {
    role: 'system' | 'user'
    content:
    | string
    | Array<
      | { type: 'text'; text: string }
      | { type: 'image_url'; image_url: { url: string } }
    >
  }
  | {
    role: 'assistant'
    content: string | null
    reasoning_content?: string | null
    tool_calls?: Array<{
      id: string
      type: 'function'
      function: { name: string; arguments: string }
    }>
  }
  | {
    role: 'tool'
    tool_call_id: string
    content: string
  }

type OpenAIChatCompletionResponse = {
  id?: string
  object?: string
  created?: number
  model?: string
  choices?: Array<{
    index: number
    finish_reason?: string | null
    message?: {
      role?: string
      content?: string | null
      reasoning_content?: string | null
      tool_calls?: Array<{
        id?: string
        type?: 'function'
        function?: { name?: string; arguments?: string }
      }>
    }
  }>
  usage?: {
    prompt_tokens?: number
    completion_tokens?: number
    total_tokens?: number
  }
}

type OpenAIStreamChunk = {
  id?: string
  model?: string
  choices?: Array<{
    index: number
    finish_reason?: string | null
    delta?: {
      role?: string
      content?: string
      reasoning_content?: string
      tool_calls?: Array<{
        index?: number
        id?: string
        type?: 'function'
        function?: {
          name?: string
          arguments?: string
        }
      }>
    }
  }>
  usage?: {
    prompt_tokens?: number
    completion_tokens?: number
    total_tokens?: number
  }
}

const HOST = Bun.env.ANTHROPIC_PROXY_HOST || '127.0.0.1'
const PORT = parseInt(Bun.env.ANTHROPIC_PROXY_PORT || '8082', 10)
const OPENAI_BASE_URL = stripTrailingSlash(
  Bun.env.OPENAI_BASE_URL || 'http://127.0.0.1:8000/v1',
)
const OPENAI_API_KEY =
  Bun.env.OPENAI_API_KEY || Bun.env.VLLM_API_KEY || Bun.env.ANTHROPIC_AUTH_TOKEN || ''
const DEFAULT_MODEL =
  Bun.env.ANTHROPIC_PROXY_MODEL ||
  Bun.env.OPENAI_MODEL ||
  'Qwen3.6-35B-A3B'
const MAX_OUTPUT_TOKENS = parseInt(
  Bun.env.ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS || '4096',
  10,
)
const DEBUG = isTruthy(Bun.env.ANTHROPIC_PROXY_DEBUG)

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '')
}

function isTruthy(value: string | undefined): boolean {
  if (!value) return false
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase())
}

function logDebug(...args: unknown[]): void {
  if (DEBUG) {
    // biome-ignore lint/suspicious/noConsole: local proxy diagnostics
    console.error('[anthropic-qwen-proxy]', ...args)
  }
}

function makeRequestId(): string {
  return `req_${crypto.randomUUID().replace(/-/g, '')}`
}

function makeMessageId(): string {
  return `msg_${crypto.randomUUID().replace(/-/g, '')}`
}

function makeToolUseId(): string {
  return `toolu_${crypto.randomUUID().replace(/-/g, '')}`
}

function responseHeaders(requestId: string): Headers {
  const headers = new Headers()
  headers.set('request-id', requestId)
  headers.set('anthropic-version', '2023-06-01')
  headers.set('x-anthropic-proxy', 'qwen-openai-shim')
  return headers
}

function jsonResponse(
  body: unknown,
  status: number,
  requestId: string,
): Response {
  const headers = responseHeaders(requestId)
  headers.set('content-type', 'application/json; charset=utf-8')
  return new Response(JSON.stringify(body), { status, headers })
}

function anthropicErrorResponse(
  requestId: string,
  status: number,
  type: string,
  message: string,
): Response {
  return jsonResponse(
    {
      type: 'error',
      error: {
        type,
        message,
      },
    },
    status,
    requestId,
  )
}

function parseRequestPath(pathname: string): string {
  const routes = [
    '/v1/messages/count_tokens',
    '/v1/messages',
    '/v1/models',
    '/health',
  ]
  for (const route of routes) {
    if (pathname === route || pathname.endsWith(route)) {
      return route
    }
  }
  return pathname
}

function openAIHeaders(): HeadersInit {
  const headers = new Headers()
  headers.set('content-type', 'application/json')
  if (OPENAI_API_KEY) {
    headers.set('authorization', `Bearer ${OPENAI_API_KEY}`)
  }
  return headers
}

async function parseJsonRequest(request: Request): Promise<unknown> {
  const text = await request.text()
  if (!text.trim()) {
    return {}
  }
  return JSON.parse(text)
}

function ensureAnthropicRequest(value: unknown): AnthropicRequest {
  if (!value || typeof value !== 'object') {
    return {}
  }
  return value as AnthropicRequest
}

function flattenSystemPrompt(system: AnthropicRequest['system']): string {
  if (!system) return ''
  if (typeof system === 'string') return system
  return system
    .map(block => {
      if (block.type === 'text') {
        return block.text
      }
      return renderUnknownBlock(block)
    })
    .filter(Boolean)
    .join('\n')
}

function renderUnknownBlock(block: { type?: string;[key: string]: unknown }): string {
  const { type, ...rest } = block
  return `<anthropic-block type="${type || 'unknown'}">${safeJSONStringify(rest)}</anthropic-block>`
}

function safeJSONStringify(value: unknown): string {
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function buildImageUrl(block: AnthropicImageBlock): string | null {
  const source = block.source
  if (!source) return null
  if (source.type === 'url' && source.url) {
    return source.url
  }
  if (source.type === 'base64' && source.data) {
    const mediaType = source.media_type || 'application/octet-stream'
    return `data:${mediaType};base64,${source.data}`
  }
  return null
}

function extractThinkingText(block: AnthropicContentBlock): string {
  if (block.type !== 'thinking') return ''
  const value = (block as { thinking?: unknown }).thinking
  if (typeof value === 'string') return value
  return ''
}

function convertUserBlocksToOpenAIContent(
  blocks: AnthropicContentBlock[],
): string | Array<{ type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } }> {
  const parts: Array<
    { type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } }
  > = []

  for (const block of blocks) {
    if (block.type === 'text') {
      parts.push({ type: 'text', text: block.text })
      continue
    }
    if (block.type === 'image') {
      const url = buildImageUrl(block)
      if (url) {
        parts.push({ type: 'image_url', image_url: { url } })
      } else {
        parts.push({ type: 'text', text: '[unsupported image source]' })
      }
      continue
    }
    if (block.type === 'tool_result') {
      continue
    }
    parts.push({ type: 'text', text: renderUnknownBlock(block) })
  }

  if (
    parts.length > 0 &&
    parts.every(part => part.type === 'text')
  ) {
    return parts.map(part => part.text).join('\n')
  }
  if (parts.length === 0) {
    return ''
  }
  return parts
}

function renderToolResultContent(
  content: AnthropicToolResultBlock['content'],
  isError: boolean | undefined,
): string {
  const prefix = isError ? '[tool_error]\n' : ''
  if (typeof content === 'string') {
    return prefix + content
  }
  if (!Array.isArray(content)) {
    return prefix
  }
  const pieces: string[] = []
  for (const block of content) {
    if (block.type === 'text') {
      pieces.push(block.text)
      continue
    }
    if (block.type === 'image') {
      pieces.push('[image omitted]')
      continue
    }
    pieces.push(renderUnknownBlock(block))
  }
  return prefix + pieces.join('\n')
}

function convertAnthropicMessagesToOpenAI(
  request: AnthropicRequest,
): OpenAIChatMessage[] {
  const result: OpenAIChatMessage[] = []
  const systemPrompt = flattenSystemPrompt(request.system)
  if (systemPrompt) {
    result.push({
      role: 'system',
      content: systemPrompt,
    })
  }

  for (const message of request.messages || []) {
    const contentBlocks = Array.isArray(message.content)
      ? message.content
      : [{ type: 'text', text: String(message.content) } as AnthropicTextBlock]

    if (message.role === 'user') {
      const userBlocks = contentBlocks.filter(block => block.type !== 'tool_result')
      if (userBlocks.length > 0) {
        result.push({
          role: 'user',
          content: convertUserBlocksToOpenAIContent(userBlocks),
        })
      }
      for (const block of contentBlocks) {
        if (block.type !== 'tool_result') continue
        result.push({
          role: 'tool',
          tool_call_id: block.tool_use_id,
          content: renderToolResultContent(block.content, block.is_error),
        })
      }
      continue
    }

    const assistantText: string[] = []
    const assistantReasoning: string[] = []
    const toolCalls: Array<{
      id: string
      type: 'function'
      function: { name: string; arguments: string }
    }> = []

    for (const block of contentBlocks) {
      if (block.type === 'text') {
        assistantText.push(block.text)
        continue
      }
      if (block.type === 'tool_use') {
        toolCalls.push({
          id: block.id || makeToolUseId(),
          type: 'function',
          function: {
            name: block.name,
            arguments: safeJSONStringify(block.input ?? {}),
          },
        })
        continue
      }
      if (block.type === 'thinking') {
        const thinkingText = extractThinkingText(block)
        if (thinkingText) {
          assistantReasoning.push(thinkingText)
        }
        continue
      }
      if (block.type === 'redacted_thinking') {
        // Redacted thinking cannot be reconstructed for OpenAI-compatible APIs.
        // Keep a placeholder so the turn still indicates hidden reasoning happened.
        assistantReasoning.push('[redacted_thinking]')
        continue
      }
      // Preserve unsupported Anthropic-only blocks as tagged text so resume/history
      // keeps some semantic breadcrumbs instead of dropping them entirely.
      assistantText.push(renderUnknownBlock(block))
    }

    if (
      assistantText.length === 0 &&
      assistantReasoning.length === 0 &&
      toolCalls.length === 0
    ) {
      continue
    }

    result.push({
      role: 'assistant',
      content: assistantText.length > 0 ? assistantText.join('\n') : null,
      ...(assistantReasoning.length > 0
        ? { reasoning_content: assistantReasoning.join('\n') }
        : {}),
      ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
    })
  }

  return result
}

function convertToolChoice(choice: AnthropicToolChoice | undefined): unknown {
  if (!choice) return undefined
  if (choice.type === 'auto') return 'auto'
  if (choice.type === 'none') return 'none'
  if (choice.type === 'any') return 'required'
  if (choice.type === 'tool') {
    return {
      type: 'function',
      function: { name: choice.name },
    }
  }
  return undefined
}

function convertTools(tools: AnthropicTool[] | undefined): unknown[] | undefined {
  if (!tools || tools.length === 0) return undefined
  return tools.map(tool => ({
    type: 'function',
    function: {
      name: tool.name,
      description: tool.description || '',
      parameters: tool.input_schema || {
        type: 'object',
        properties: {},
      },
      ...(tool.strict === true ? { strict: true } : {}),
    },
  }))
}

function convertOutputFormat(outputConfig: AnthropicRequest['output_config']): unknown {
  const format = outputConfig?.format
  if (!format || format.type !== 'json_schema' || !format.schema) {
    return undefined
  }
  return {
    type: 'json_schema',
    json_schema: {
      name: 'claude_code_output',
      schema: format.schema,
    },
  }
}

function buildOpenAIRequestBody(
  request: AnthropicRequest,
  stream: boolean,
): Record<string, unknown> {
  const requestedMaxTokens = request.max_tokens ?? 8192
  const cappedMaxTokens =
    Number.isFinite(MAX_OUTPUT_TOKENS) && MAX_OUTPUT_TOKENS > 0
      ? Math.min(requestedMaxTokens, MAX_OUTPUT_TOKENS)
      : requestedMaxTokens

  const body: Record<string, unknown> = {
    model: request.model || DEFAULT_MODEL,
    messages: convertAnthropicMessagesToOpenAI(request),
    stream,
    max_tokens: cappedMaxTokens,
  }

  const tools = convertTools(request.tools)
  if (tools) {
    body.tools = tools
  }

  const toolChoice = convertToolChoice(request.tool_choice)
  if (toolChoice !== undefined) {
    body.tool_choice = toolChoice
  }

  const responseFormat = convertOutputFormat(request.output_config)
  if (responseFormat) {
    body.response_format = responseFormat
  }

  if (request.temperature !== undefined) {
    body.temperature = request.temperature
  }
  if (request.stop_sequences && request.stop_sequences.length > 0) {
    body.stop = request.stop_sequences
  }
  if (stream) {
    body.stream_options = { include_usage: true }
  }

  return body
}

function mapOpenAIFinishReason(
  finishReason: string | null | undefined,
  hasToolCalls: boolean,
): string | null {
  if (hasToolCalls || finishReason === 'tool_calls') {
    return 'tool_use'
  }
  if (finishReason === 'length') {
    return 'max_tokens'
  }
  if (finishReason === 'stop') {
    return 'end_turn'
  }
  if (finishReason === 'content_filter') {
    return 'stop_sequence'
  }
  return finishReason ? 'end_turn' : null
}

function parseToolArguments(value: string | undefined): unknown {
  if (!value) return {}
  try {
    return JSON.parse(value)
  } catch {
    return { raw: value }
  }
}

function convertOpenAIMessageToAnthropicContent(
  message: NonNullable<OpenAIChatCompletionResponse['choices']>[number]['message'] | undefined,
): AnthropicContentBlock[] {
  if (!message) return []
  const content: AnthropicContentBlock[] = []
  if (message.reasoning_content) {
    content.push({
      type: 'thinking',
      thinking: message.reasoning_content,
      signature: '',
    })
  }
  if (message.content) {
    content.push({
      type: 'text',
      text: message.content,
    })
  }
  for (const toolCall of message.tool_calls || []) {
    content.push({
      type: 'tool_use',
      id: toolCall.id || makeToolUseId(),
      name: toolCall.function?.name || 'unknown_tool',
      input: parseToolArguments(toolCall.function?.arguments),
    })
  }

  // Anthropic message constraints require thinking not to be the last block.
  if (
    content.length > 0 &&
    content[content.length - 1]?.type === 'thinking'
  ) {
    content.push({
      type: 'text',
      text: '',
    })
  }

  return content
}

function estimateTokensFromText(text: string): number {
  if (!text) return 0
  return Math.max(1, Math.ceil(text.length / 4))
}

function estimateRequestTokens(request: AnthropicRequest): number {
  const serialized = safeJSONStringify({
    system: request.system,
    messages: request.messages,
    tools: request.tools,
    output_config: request.output_config,
  })
  return estimateTokensFromText(serialized)
}

function buildAnthropicMessageResponse(
  request: AnthropicRequest,
  openai: OpenAIChatCompletionResponse,
): Record<string, unknown> {
  const choice = openai.choices?.[0]
  const content = convertOpenAIMessageToAnthropicContent(choice?.message)
  const stopReason = mapOpenAIFinishReason(
    choice?.finish_reason,
    (choice?.message?.tool_calls?.length || 0) > 0,
  )
  const promptTokens =
    openai.usage?.prompt_tokens ?? estimateRequestTokens(request)
  const completionText =
    `${choice?.message?.reasoning_content || ''}${choice?.message?.content || ''}${safeJSONStringify(choice?.message?.tool_calls || [])}`
  const completionTokens =
    openai.usage?.completion_tokens ?? estimateTokensFromText(completionText)

  return {
    id: openai.id || makeMessageId(),
    type: 'message',
    role: 'assistant',
    model: request.model || DEFAULT_MODEL,
    content,
    stop_reason: stopReason,
    stop_sequence: null,
    usage: {
      input_tokens: promptTokens,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: completionTokens,
    },
  }
}

function mapUpstreamErrorType(status: number): string {
  if (status === 400) return 'invalid_request_error'
  if (status === 401 || status === 403) return 'authentication_error'
  if (status === 404) return 'not_found_error'
  if (status === 409) return 'conflict_error'
  if (status === 413) return 'request_too_large'
  if (status === 429) return 'rate_limit_error'
  if (status >= 500) return 'api_error'
  return 'api_error'
}

async function mapUpstreamError(response: Response, requestId: string): Promise<Response> {
  const status = response.status || 500
  let message = `Upstream error (${status})`
  try {
    const text = await response.text()
    if (text) {
      try {
        const parsed = JSON.parse(text) as {
          error?: { message?: string }
          message?: string
        }
        message =
          parsed.error?.message ||
          parsed.message ||
          text
      } catch {
        message = text
      }
    }
  } catch {
    // ignore read errors
  }
  return anthropicErrorResponse(requestId, status, mapUpstreamErrorType(status), message)
}

function encodeSSE(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
}

async function* parseOpenAISSE(body: ReadableStream<Uint8Array>): AsyncGenerator<OpenAIStreamChunk> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })

    while (true) {
      const boundary = buffer.indexOf('\n\n')
      if (boundary === -1) break
      const rawEvent = buffer.slice(0, boundary)
      buffer = buffer.slice(boundary + 2)

      const lines = rawEvent
        .split(/\r?\n/)
        .filter(line => line.startsWith('data:'))
        .map(line => line.slice(5).trim())

      if (lines.length === 0) continue
      const data = lines.join('\n')
      if (data === '[DONE]') {
        return
      }
      yield JSON.parse(data) as OpenAIStreamChunk
    }
  }
}

type ToolStreamState = {
  anthropicIndex: number
  toolUseId: string
  name: string
  started: boolean
}

async function handleStreamingMessages(
  anthropicRequest: AnthropicRequest,
  requestId: string,
): Promise<Response> {
  let upstream: Response
  try {
    upstream = await fetch(`${OPENAI_BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: openAIHeaders(),
      body: JSON.stringify(buildOpenAIRequestBody(anthropicRequest, true)),
    })
  } catch (error) {
    const message =
      error instanceof Error
        ? `Unable to reach upstream OpenAI endpoint ${OPENAI_BASE_URL}: ${error.message}`
        : `Unable to reach upstream OpenAI endpoint ${OPENAI_BASE_URL}`
    return anthropicErrorResponse(requestId, 502, 'api_error', message)
  }

  if (!upstream.ok || !upstream.body) {
    return mapUpstreamError(upstream, requestId)
  }

  const responseStream = new ReadableStream({
    async start(controller) {
      const messageId = makeMessageId()
      const modelName = anthropicRequest.model || DEFAULT_MODEL
      let textBlockStarted = false
      let textBlockIndex = 0
      let nextBlockIndex = 0
      const toolStates = new Map<number, ToolStreamState>()
      let thinkingBlockStarted = false
      let thinkingBlockIndex = 0
      let promptTokens = estimateRequestTokens(anthropicRequest)
      let completionTokens = 0
      let finalStopReason: string | null = null
      let sawAnyContent = false

      controller.enqueue(
        encodeSSE('message_start', {
          type: 'message_start',
          message: {
            id: messageId,
            type: 'message',
            role: 'assistant',
            model: modelName,
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: {
              input_tokens: promptTokens,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              output_tokens: 0,
            },
          },
        }),
      )

      try {
        for await (const chunk of parseOpenAISSE(upstream.body!)) {
          if (chunk.usage?.prompt_tokens !== undefined) {
            promptTokens = chunk.usage.prompt_tokens
          }
          if (chunk.usage?.completion_tokens !== undefined) {
            completionTokens = chunk.usage.completion_tokens
          }

          const choice = chunk.choices?.[0]
          if (!choice) continue
          const delta = choice.delta || {}

          if (delta.content) {
            sawAnyContent = true
            if (!textBlockStarted) {
              textBlockStarted = true
              textBlockIndex = nextBlockIndex++
              controller.enqueue(
                encodeSSE('content_block_start', {
                  type: 'content_block_start',
                  index: textBlockIndex,
                  content_block: {
                    type: 'text',
                    text: '',
                  },
                }),
              )
            }
            controller.enqueue(
              encodeSSE('content_block_delta', {
                type: 'content_block_delta',
                index: textBlockIndex,
                delta: {
                  type: 'text_delta',
                  text: delta.content,
                },
              }),
            )
          }

          if (delta.reasoning_content) {
            sawAnyContent = true
            if (!thinkingBlockStarted) {
              thinkingBlockStarted = true
              thinkingBlockIndex = nextBlockIndex++
              controller.enqueue(
                encodeSSE('content_block_start', {
                  type: 'content_block_start',
                  index: thinkingBlockIndex,
                  content_block: {
                    type: 'thinking',
                    thinking: '',
                    signature: '',
                  },
                }),
              )
            }
            controller.enqueue(
              encodeSSE('content_block_delta', {
                type: 'content_block_delta',
                index: thinkingBlockIndex,
                delta: {
                  type: 'thinking_delta',
                  thinking: delta.reasoning_content,
                },
              }),
            )
          }

          for (const toolDelta of delta.tool_calls || []) {
            const toolIndex = toolDelta.index ?? 0
            let state = toolStates.get(toolIndex)
            if (!state) {
              state = {
                anthropicIndex: nextBlockIndex++,
                toolUseId: toolDelta.id || makeToolUseId(),
                name: toolDelta.function?.name || 'unknown_tool',
                started: false,
              }
              toolStates.set(toolIndex, state)
            }
            if (toolDelta.id) {
              state.toolUseId = toolDelta.id
            }
            if (toolDelta.function?.name) {
              state.name = toolDelta.function.name
            }
            if (!state.started && state.name) {
              sawAnyContent = true
              state.started = true
              controller.enqueue(
                encodeSSE('content_block_start', {
                  type: 'content_block_start',
                  index: state.anthropicIndex,
                  content_block: {
                    type: 'tool_use',
                    id: state.toolUseId,
                    name: state.name,
                    input: {},
                  },
                }),
              )
            }
            if (toolDelta.function?.arguments) {
              controller.enqueue(
                encodeSSE('content_block_delta', {
                  type: 'content_block_delta',
                  index: state.anthropicIndex,
                  delta: {
                    type: 'input_json_delta',
                    partial_json: toolDelta.function.arguments,
                  },
                }),
              )
            }
          }

          if (choice.finish_reason) {
            finalStopReason = mapOpenAIFinishReason(
              choice.finish_reason,
              toolStates.size > 0,
            )
          }
        }

        if (textBlockStarted) {
          controller.enqueue(
            encodeSSE('content_block_stop', {
              type: 'content_block_stop',
              index: textBlockIndex,
            }),
          )
        }

        if (thinkingBlockStarted) {
          controller.enqueue(
            encodeSSE('content_block_stop', {
              type: 'content_block_stop',
              index: thinkingBlockIndex,
            }),
          )
        }

        for (const state of [...toolStates.values()].sort(
          (a, b) => a.anthropicIndex - b.anthropicIndex,
        )) {
          if (!state.started) continue
          controller.enqueue(
            encodeSSE('content_block_stop', {
              type: 'content_block_stop',
              index: state.anthropicIndex,
            }),
          )
        }

        if (!completionTokens) {
          completionTokens = sawAnyContent ? 1 : 0
        }

        if (thinkingBlockStarted && !textBlockStarted && toolStates.size === 0) {
          controller.enqueue(
            encodeSSE('content_block_start', {
              type: 'content_block_start',
              index: nextBlockIndex,
              content_block: {
                type: 'text',
                text: '',
              },
            }),
          )
          controller.enqueue(
            encodeSSE('content_block_stop', {
              type: 'content_block_stop',
              index: nextBlockIndex,
            }),
          )
        }

        controller.enqueue(
          encodeSSE('message_delta', {
            type: 'message_delta',
            delta: {
              stop_reason: finalStopReason || (toolStates.size > 0 ? 'tool_use' : 'end_turn'),
              stop_sequence: null,
            },
            usage: {
              input_tokens: promptTokens,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              output_tokens: completionTokens,
            },
          }),
        )
        controller.enqueue(
          encodeSSE('message_stop', {
            type: 'message_stop',
          }),
        )
      } catch (error) {
        const message =
          error instanceof Error ? error.message : 'stream bridge failed'
        controller.enqueue(
          encodeSSE('error', {
            type: 'error',
            error: {
              type: 'api_error',
              message,
            },
          }),
        )
      } finally {
        controller.close()
      }
    },
  })

  const headers = responseHeaders(requestId)
  headers.set('content-type', 'text/event-stream; charset=utf-8')
  headers.set('cache-control', 'no-cache')
  headers.set('connection', 'keep-alive')
  return new Response(responseStream, {
    status: 200,
    headers,
  })
}

async function handleNonStreamingMessages(
  anthropicRequest: AnthropicRequest,
  requestId: string,
): Promise<Response> {
  let upstream: Response
  try {
    upstream = await fetch(`${OPENAI_BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: openAIHeaders(),
      body: JSON.stringify(buildOpenAIRequestBody(anthropicRequest, false)),
    })
  } catch (error) {
    const message =
      error instanceof Error
        ? `Unable to reach upstream OpenAI endpoint ${OPENAI_BASE_URL}: ${error.message}`
        : `Unable to reach upstream OpenAI endpoint ${OPENAI_BASE_URL}`
    return anthropicErrorResponse(requestId, 502, 'api_error', message)
  }

  if (!upstream.ok) {
    return mapUpstreamError(upstream, requestId)
  }

  const body = (await upstream.json()) as OpenAIChatCompletionResponse
  return jsonResponse(buildAnthropicMessageResponse(anthropicRequest, body), 200, requestId)
}

async function handleMessages(request: Request, requestId: string): Promise<Response> {
  const payload = ensureAnthropicRequest(await parseJsonRequest(request))
  if (!payload.model) {
    payload.model = DEFAULT_MODEL
  }
  if (!Array.isArray(payload.messages)) {
    return anthropicErrorResponse(
      requestId,
      400,
      'invalid_request_error',
      '`messages` must be an array',
    )
  }
  logDebug('messages request', {
    model: payload.model,
    stream: payload.stream,
    messageCount: payload.messages.length,
    toolCount: payload.tools?.length || 0,
  })
  if (payload.stream) {
    return handleStreamingMessages(payload, requestId)
  }
  return handleNonStreamingMessages(payload, requestId)
}

async function handleCountTokens(request: Request, requestId: string): Promise<Response> {
  const payload = ensureAnthropicRequest(await parseJsonRequest(request))
  const inputTokens = estimateRequestTokens(payload)
  return jsonResponse(
    {
      input_tokens: inputTokens,
    },
    200,
    requestId,
  )
}

function mapOpenAIModelsToAnthropic(models: unknown): Record<string, unknown> {
  const data =
    models &&
      typeof models === 'object' &&
      Array.isArray((models as { data?: unknown[] }).data)
      ? (models as { data: Array<{ id?: string; created?: number }> }).data
      : [{ id: DEFAULT_MODEL }]

  const mapped = data.map(model => ({
    type: 'model',
    id: model.id || DEFAULT_MODEL,
    display_name: model.id || DEFAULT_MODEL,
    created_at: model.created || Math.floor(Date.now() / 1000),
  }))

  return {
    data: mapped,
    has_more: false,
    first_id: mapped[0]?.id || null,
    last_id: mapped[mapped.length - 1]?.id || null,
  }
}

async function handleModels(requestId: string): Promise<Response> {
  let upstream: Response
  try {
    upstream = await fetch(`${OPENAI_BASE_URL}/models`, {
      method: 'GET',
      headers: openAIHeaders(),
    })
  } catch (error) {
    const message =
      error instanceof Error
        ? `Unable to reach upstream OpenAI endpoint ${OPENAI_BASE_URL}: ${error.message}`
        : `Unable to reach upstream OpenAI endpoint ${OPENAI_BASE_URL}`
    return anthropicErrorResponse(requestId, 502, 'api_error', message)
  }

  if (!upstream.ok) {
    return mapUpstreamError(upstream, requestId)
  }

  const body = await upstream.json()
  return jsonResponse(mapOpenAIModelsToAnthropic(body), 200, requestId)
}

async function handleRequest(request: Request): Promise<Response> {
  const requestId = makeRequestId()
  const route = parseRequestPath(new URL(request.url).pathname)

  try {
    if (request.method === 'GET' && route === '/health') {
      return jsonResponse(
        {
          ok: true,
          openai_base_url: OPENAI_BASE_URL,
          default_model: DEFAULT_MODEL,
        },
        200,
        requestId,
      )
    }
    if (request.method === 'GET' && route === '/v1/models') {
      return handleModels(requestId)
    }
    if (request.method === 'POST' && route === '/v1/messages') {
      return handleMessages(request, requestId)
    }
    if (request.method === 'POST' && route === '/v1/messages/count_tokens') {
      return handleCountTokens(request, requestId)
    }
    return anthropicErrorResponse(
      requestId,
      404,
      'not_found_error',
      `Unsupported route: ${request.method} ${new URL(request.url).pathname}`,
    )
  } catch (error) {
    const message = error instanceof Error ? error.message : 'unknown proxy error'
    return anthropicErrorResponse(requestId, 500, 'api_error', message)
  }
}

export {
  buildOpenAIRequestBody,
  buildAnthropicMessageResponse,
  convertAnthropicMessagesToOpenAI,
  estimateRequestTokens,
  handleRequest,
  mapOpenAIFinishReason,
  parseRequestPath,
}

export function startProxy(): Server {
  const server = Bun.serve({
    hostname: HOST,
    port: PORT,
    fetch: handleRequest,
  })

  // biome-ignore lint/suspicious/noConsole: intentional startup log
  console.log(
    `[anthropic-qwen-proxy] listening on http://${HOST}:${PORT} -> ${OPENAI_BASE_URL} (default model: ${DEFAULT_MODEL})`,
  )
  return server
}

if (import.meta.main) {
  startProxy()
}
