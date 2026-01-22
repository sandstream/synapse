#!/bin/bash
# =============================================================================
# lib/llm.sh - Dual-Mode LLM API (Native Tool-Use + JSON Proxy)
#
# Universal Agent Proxy - Makes ANY model an agent through:
#   1. Native tool-use for supported providers (Anthropic, OpenAI)
#   2. JSON proxy mode for all other models (DeepSeek, Ollama, etc)
#
# Supports: anthropic, openrouter, ollama, openai
#
# Environment:
#   LLM_PROVIDER      - anthropic (default), openrouter, ollama, openai
#   LLM_MODEL         - Model name (provider-specific)
#   LLM_MAX_TOKENS    - Max output tokens (default: 8000)
#   LLM_TIMEOUT       - Request timeout in seconds (default: 300)
#   INFERNO_MODE      - auto (default), native, proxy - force specific mode
#   ANTHROPIC_API_KEY / OPENROUTER_API_KEY / OPENAI_API_KEY - API keys
# =============================================================================

# Defaults
LLM_PROVIDER="${LLM_PROVIDER:-anthropic}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-8000}"
LLM_TIMEOUT="${LLM_TIMEOUT:-300}"
INFERNO_MODE="${INFERNO_MODE:-auto}"

# Default models per provider
get_default_model() {
    case "$LLM_PROVIDER" in
        anthropic)  echo "claude-sonnet-4-20250514" ;;
        openrouter) echo "anthropic/claude-sonnet-4" ;;
        openai)     echo "gpt-4o" ;;
        ollama)     echo "llama3.1" ;;
        *)          echo "claude-sonnet-4-20250514" ;;
    esac
}

LLM_MODEL="${LLM_MODEL:-$(get_default_model)}"

# =============================================================================
# Provider Capabilities Detection
# =============================================================================

# Check if provider/model supports native tool-use
# Usage: if supports_native_tools; then ...
supports_native_tools() {
    # Allow forcing mode
    if [ "$INFERNO_MODE" = "proxy" ]; then
        return 1
    fi
    if [ "$INFERNO_MODE" = "native" ]; then
        return 0
    fi

    # Auto-detect based on provider
    case "$LLM_PROVIDER" in
        anthropic)
            return 0  # All Claude models support tools
            ;;
        openai)
            return 0  # GPT-4, GPT-3.5-turbo support tools
            ;;
        openrouter)
            # Only Anthropic and OpenAI models via OpenRouter support native tools
            if [[ "$LLM_MODEL" == anthropic/* ]] || [[ "$LLM_MODEL" == openai/* ]]; then
                return 0
            fi
            return 1  # DeepSeek, Llama, etc don't support native tools
            ;;
        ollama)
            return 1  # Most Ollama models don't have native tool support
            ;;
        *)
            return 1
            ;;
    esac
}

# Get provider mode description
get_provider_mode() {
    if supports_native_tools; then
        echo "native"
    else
        echo "proxy"
    fi
}

# =============================================================================
# Tool Definitions for Native Mode
# =============================================================================

# Get tools array for Anthropic API
get_anthropic_tools() {
    cat << 'EOF'
[
  {
    "name": "read_file",
    "description": "Read the contents of a file at the specified path",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "The file path to read"
        }
      },
      "required": ["path"]
    }
  },
  {
    "name": "write_file",
    "description": "Write content to a file at the specified path. Creates directories if needed.",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "The file path to write to"
        },
        "content": {
          "type": "string",
          "description": "The content to write to the file"
        }
      },
      "required": ["path", "content"]
    }
  },
  {
    "name": "bash",
    "description": "Execute a shell command and return the output",
    "input_schema": {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The shell command to execute"
        }
      },
      "required": ["command"]
    }
  },
  {
    "name": "search",
    "description": "Search for a pattern in files using grep",
    "input_schema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The regex pattern to search for"
        },
        "path": {
          "type": "string",
          "description": "The directory to search in (default: current directory)"
        }
      },
      "required": ["query"]
    }
  },
  {
    "name": "list_files",
    "description": "List files in a directory with optional pattern matching",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "The directory path (default: current directory)"
        },
        "pattern": {
          "type": "string",
          "description": "Glob pattern to match files (default: *)"
        }
      }
    }
  },
  {
    "name": "done",
    "description": "Mark the task as complete with a summary message",
    "input_schema": {
      "type": "object",
      "properties": {
        "message": {
          "type": "string",
          "description": "Completion summary message"
        }
      },
      "required": ["message"]
    }
  }
]
EOF
}

# Get tools array for OpenAI API format
get_openai_tools() {
    cat << 'EOF'
[
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read the contents of a file at the specified path",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "The file path to read"}
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Write content to a file at the specified path",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "The file path to write to"},
          "content": {"type": "string", "description": "The content to write"}
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Execute a shell command",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "The command to execute"}
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search",
      "description": "Search for pattern in files using grep",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "The regex pattern"},
          "path": {"type": "string", "description": "Directory to search (default: .)"}
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "list_files",
      "description": "List files in directory",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Directory path (default: .)"},
          "pattern": {"type": "string", "description": "Glob pattern (default: *)"}
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "done",
      "description": "Mark task as complete",
      "parameters": {
        "type": "object",
        "properties": {
          "message": {"type": "string", "description": "Completion message"}
        },
        "required": ["message"]
      }
    }
  }
]
EOF
}

# =============================================================================
# JSON Proxy System Prompt
# =============================================================================

# Get system prompt for JSON proxy mode
# This instructs models without native tool-use how to call tools
get_json_proxy_system_prompt() {
    cat << 'EOF'
You are a coding agent with access to tools. You MUST use tools to complete tasks.

AVAILABLE TOOLS:
- read_file(path): Read contents of a file
- write_file(path, content): Write content to a file
- bash(command): Execute a shell command
- search(query, path?): Search for pattern in files
- list_files(path?, pattern?): List files in directory
- done(message): Mark task as complete

RESPONSE FORMAT:
You MUST respond with ONLY valid JSON in this exact format:
{
  "reasoning": "Brief explanation of what you're doing and why",
  "tool": "tool_name",
  "params": {
    "param1": "value1"
  }
}

RULES:
1. ALWAYS respond with valid JSON only - no markdown, no explanation outside JSON
2. Call ONE tool at a time - you will receive the result and can continue
3. Use "reasoning" to explain your thought process
4. When task is complete, use the "done" tool with a summary message
5. If you need file contents, read them first before making changes
6. Always verify your changes worked (e.g., run tests, build commands)

EXAMPLE WORKFLOW:
User: "Create a hello.ts file that exports a greet function"

Step 1: {"reasoning": "Creating the TypeScript file", "tool": "write_file", "params": {"path": "hello.ts", "content": "export function greet(name: string): string {\n  return `Hello, ${name}!`;\n}"}}
[You receive: "✓ Written: hello.ts (78 bytes)"]

Step 2: {"reasoning": "Verifying the file was created correctly", "tool": "read_file", "params": {"path": "hello.ts"}}
[You receive the file contents]

Step 3: {"reasoning": "Task complete - file created and verified", "tool": "done", "params": {"message": "Created hello.ts with greet function that takes a name and returns a greeting"}}

Remember: ONLY output JSON, nothing else!
EOF
}

# =============================================================================
# API Calls - Native Mode
# =============================================================================

# Call Anthropic API with native tool-use
# Usage: response=$(call_anthropic_with_tools "$messages_json" "$system_prompt")
call_anthropic_with_tools() {
    local messages_json="$1"
    local system_prompt="${2:-You are a helpful coding assistant.}"

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo '{"error": "ANTHROPIC_API_KEY not set"}' >&2
        return 1
    fi

    local tools
    tools=$(get_anthropic_tools)

    local request_body
    request_body=$(jq -n \
        --arg model "$LLM_MODEL" \
        --argjson max_tokens "$LLM_MAX_TOKENS" \
        --arg system "$system_prompt" \
        --argjson messages "$messages_json" \
        --argjson tools "$tools" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            system: $system,
            messages: $messages,
            tools: $tools
        }')

    curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$request_body" \
        "https://api.anthropic.com/v1/messages"
}

# Call OpenAI API with native tool-use
call_openai_with_tools() {
    local messages_json="$1"
    local system_prompt="${2:-You are a helpful coding assistant.}"

    if [ -z "${OPENAI_API_KEY:-}" ]; then
        echo '{"error": "OPENAI_API_KEY not set"}' >&2
        return 1
    fi

    local tools
    tools=$(get_openai_tools)

    # Prepend system message
    local full_messages
    full_messages=$(jq -n \
        --arg system "$system_prompt" \
        --argjson messages "$messages_json" \
        '[{"role": "system", "content": $system}] + $messages')

    local request_body
    request_body=$(jq -n \
        --arg model "$LLM_MODEL" \
        --argjson max_tokens "$LLM_MAX_TOKENS" \
        --argjson messages "$full_messages" \
        --argjson tools "$tools" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: $messages,
            tools: $tools
        }')

    curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "$request_body" \
        "https://api.openai.com/v1/chat/completions"
}

# =============================================================================
# API Calls - JSON Proxy Mode
# =============================================================================

# Call LLM with JSON proxy instructions (for models without native tools)
# Usage: response=$(call_with_json_proxy "$messages_json" "$task_prompt")
call_with_json_proxy() {
    local messages_json="$1"
    local system_prompt
    system_prompt=$(get_json_proxy_system_prompt)

    case "$LLM_PROVIDER" in
        anthropic)
            call_anthropic_proxy "$messages_json" "$system_prompt"
            ;;
        openrouter)
            call_openrouter_proxy "$messages_json" "$system_prompt"
            ;;
        openai)
            call_openai_proxy "$messages_json" "$system_prompt"
            ;;
        ollama)
            call_ollama_proxy "$messages_json" "$system_prompt"
            ;;
        *)
            echo '{"error": "Unknown provider: '"$LLM_PROVIDER"'"}' >&2
            return 1
            ;;
    esac
}

# Anthropic in proxy mode (without tools API)
call_anthropic_proxy() {
    local messages_json="$1"
    local system_prompt="$2"

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo '{"error": "ANTHROPIC_API_KEY not set"}' >&2
        return 1
    fi

    local request_body
    request_body=$(jq -n \
        --arg model "$LLM_MODEL" \
        --argjson max_tokens "$LLM_MAX_TOKENS" \
        --arg system "$system_prompt" \
        --argjson messages "$messages_json" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            system: $system,
            messages: $messages
        }')

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$request_body" \
        "https://api.anthropic.com/v1/messages")

    # Extract text content for proxy mode
    echo "$response" | jq -r '.content[0].text // empty'
}

# OpenRouter in proxy mode
call_openrouter_proxy() {
    local messages_json="$1"
    local system_prompt="$2"

    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
        echo '{"error": "OPENROUTER_API_KEY not set"}' >&2
        return 1
    fi

    # Prepend system message
    local full_messages
    full_messages=$(jq -n \
        --arg system "$system_prompt" \
        --argjson messages "$messages_json" \
        '[{"role": "system", "content": $system}] + $messages')

    local request_body
    request_body=$(jq -n \
        --arg model "$LLM_MODEL" \
        --argjson max_tokens "$LLM_MAX_TOKENS" \
        --argjson messages "$full_messages" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: $messages
        }')

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENROUTER_API_KEY" \
        -d "$request_body" \
        "https://openrouter.ai/api/v1/chat/completions")

    # Extract text content
    echo "$response" | jq -r '.choices[0].message.content // empty'
}

# OpenAI in proxy mode
call_openai_proxy() {
    local messages_json="$1"
    local system_prompt="$2"

    if [ -z "${OPENAI_API_KEY:-}" ]; then
        echo '{"error": "OPENAI_API_KEY not set"}' >&2
        return 1
    fi

    # Prepend system message
    local full_messages
    full_messages=$(jq -n \
        --arg system "$system_prompt" \
        --argjson messages "$messages_json" \
        '[{"role": "system", "content": $system}] + $messages')

    local request_body
    request_body=$(jq -n \
        --arg model "$LLM_MODEL" \
        --argjson max_tokens "$LLM_MAX_TOKENS" \
        --argjson messages "$full_messages" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: $messages
        }')

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "$request_body" \
        "https://api.openai.com/v1/chat/completions")

    # Extract text content
    echo "$response" | jq -r '.choices[0].message.content // empty'
}

# Ollama in proxy mode
call_ollama_proxy() {
    local messages_json="$1"
    local system_prompt="$2"
    local ollama_url="${OLLAMA_URL:-http://localhost:11434}"

    # Prepend system message
    local full_messages
    full_messages=$(jq -n \
        --arg system "$system_prompt" \
        --argjson messages "$messages_json" \
        '[{"role": "system", "content": $system}] + $messages')

    local request_body
    request_body=$(jq -n \
        --arg model "$LLM_MODEL" \
        --argjson messages "$full_messages" \
        '{
            model: $model,
            messages: $messages,
            stream: false
        }')

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        "$ollama_url/api/chat")

    # Extract text content
    echo "$response" | jq -r '.message.content // empty'
}

# =============================================================================
# Unified API Calls
# =============================================================================

# Call LLM with appropriate mode (native or proxy)
# Usage: response=$(call_llm_agent "$messages_json" "$system_prompt")
# Returns: Raw API response (native) or text content (proxy)
call_llm_agent() {
    local messages_json="$1"
    local system_prompt="${2:-You are a helpful coding assistant.}"

    if supports_native_tools; then
        # Use native tool-use API
        case "$LLM_PROVIDER" in
            anthropic)
                call_anthropic_with_tools "$messages_json" "$system_prompt"
                ;;
            openai)
                call_openai_with_tools "$messages_json" "$system_prompt"
                ;;
            openrouter)
                # For OpenRouter with Anthropic models, use their format
                if [[ "$LLM_MODEL" == anthropic/* ]]; then
                    call_anthropic_with_tools "$messages_json" "$system_prompt"
                else
                    call_openai_with_tools "$messages_json" "$system_prompt"
                fi
                ;;
            *)
                call_with_json_proxy "$messages_json"
                ;;
        esac
    else
        # Use JSON proxy mode
        call_with_json_proxy "$messages_json"
    fi
}

# =============================================================================
# Legacy API (backwards compatibility)
# =============================================================================

# Simple call without tools (legacy interface)
# Usage: response=$(call_llm "prompt")
call_llm() {
    local prompt="$1"
    local messages
    messages=$(jq -n --arg content "$prompt" '[{"role": "user", "content": $content}]')

    case "$LLM_PROVIDER" in
        anthropic)
            call_anthropic_proxy "$messages" "You are a helpful coding assistant."
            ;;
        openrouter)
            call_openrouter_proxy "$messages" "You are a helpful coding assistant."
            ;;
        openai)
            call_openai_proxy "$messages" "You are a helpful coding assistant."
            ;;
        ollama)
            call_ollama_proxy "$messages" "You are a helpful coding assistant."
            ;;
        *)
            echo "Error: Unknown provider: $LLM_PROVIDER" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# Response Parsing (from original llm.sh)
# =============================================================================

# Extract JSON from LLM response (handles markdown code blocks)
# Usage: json=$(extract_json "$llm_output")
extract_json() {
    local output="$1"

    # Try to extract JSON from markdown code block first
    local json
    json=$(echo "$output" | sed -n '/```json/,/```/p' | sed '1d;$d')

    if [ -z "$json" ]; then
        # Try plain code block
        json=$(echo "$output" | sed -n '/```/,/```/p' | sed '1d;$d')
    fi

    if [ -z "$json" ]; then
        # Assume raw JSON
        json="$output"
    fi

    # Validate and clean
    if echo "$json" | jq . >/dev/null 2>&1; then
        echo "$json"
    else
        # Try to find JSON object in text
        json=$(echo "$output" | grep -o '{.*}' | head -1)
        if echo "$json" | jq . >/dev/null 2>&1; then
            echo "$json"
        else
            echo "null"
        fi
    fi
}

# Validate response structure (legacy format)
# Usage: if validate_response "$json"; then ...
validate_response() {
    local json="$1"

    if [ -z "$json" ] || [ "$json" = "null" ]; then
        return 1
    fi

    # Must be valid JSON
    if ! echo "$json" | jq . >/dev/null 2>&1; then
        return 1
    fi

    # Must have at least files, commands, or read_files
    local has_files has_commands has_reads
    has_files=$(echo "$json" | jq -r '.files | length // 0')
    has_commands=$(echo "$json" | jq -r '.commands | length // 0')
    has_reads=$(echo "$json" | jq -r '.read_files | length // 0')

    if [ "$has_files" -eq 0 ] && [ "$has_commands" -eq 0 ] && [ "$has_reads" -eq 0 ]; then
        # Check if at least done field exists
        if ! echo "$json" | jq -e '.done' >/dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

# Check if response indicates completion (legacy format)
# Usage: if is_done "$json"; then ...
is_done() {
    local json="$1"
    local done_val
    done_val=$(echo "$json" | jq -r '.done // false')
    [ "$done_val" = "true" ]
}

# Get message from response (legacy format)
# Usage: message=$(get_message "$json")
get_message() {
    local json="$1"
    echo "$json" | jq -r '.message // "No message"'
}

# =============================================================================
# Response Parsing - Native Tool Format
# =============================================================================

# Parse tool calls from Anthropic native response
# Returns: JSON array of {name, params, id}
parse_anthropic_tool_calls() {
    local response="$1"

    # Check for tool_use in content array
    if echo "$response" | jq -e '.content[] | select(.type == "tool_use")' >/dev/null 2>&1; then
        echo "$response" | jq -c '[.content[] | select(.type == "tool_use") | {name: .name, params: .input, id: .id}]'
    else
        echo "[]"
    fi
}

# Parse tool calls from OpenAI native response
# Returns: JSON array of {name, params, id}
parse_openai_tool_calls() {
    local response="$1"

    # Check for tool_calls in message
    if echo "$response" | jq -e '.choices[0].message.tool_calls' >/dev/null 2>&1; then
        echo "$response" | jq -c '[.choices[0].message.tool_calls[] | {name: .function.name, params: (.function.arguments | fromjson), id: .id}]'
    else
        echo "[]"
    fi
}

# Check if response has stop reason indicating completion
has_stop_reason() {
    local response="$1"

    # Anthropic format
    if echo "$response" | jq -e '.stop_reason == "end_turn"' >/dev/null 2>&1; then
        return 0
    fi

    # OpenAI format
    if echo "$response" | jq -e '.choices[0].finish_reason == "stop"' >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Extract text from native response
extract_native_text() {
    local response="$1"

    # Anthropic format
    local text
    text=$(echo "$response" | jq -r '[.content[] | select(.type == "text") | .text] | join("\n")' 2>/dev/null)
    if [ -n "$text" ] && [ "$text" != "null" ]; then
        echo "$text"
        return
    fi

    # OpenAI format
    text=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    echo "$text"
}
