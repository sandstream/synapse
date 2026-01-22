#!/bin/bash
# =============================================================================
# lib/llm.sh - LLM API calls for multiple providers
#
# Supports: anthropic, openrouter, ollama
#
# Environment:
#   LLM_PROVIDER   - anthropic (default), openrouter, ollama
#   LLM_MODEL      - Model name (provider-specific)
#   LLM_MAX_TOKENS - Max output tokens (default: 8000)
#   LLM_TIMEOUT    - Request timeout in seconds (default: 300)
#   ANTHROPIC_API_KEY / OPENROUTER_API_KEY - API keys
# =============================================================================

# Defaults
LLM_PROVIDER="${LLM_PROVIDER:-anthropic}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-8000}"
LLM_TIMEOUT="${LLM_TIMEOUT:-300}"

# Default models per provider
get_default_model() {
    case "$LLM_PROVIDER" in
        anthropic)  echo "claude-sonnet-4-20250514" ;;
        openrouter) echo "anthropic/claude-sonnet-4" ;;
        ollama)     echo "llama3.1" ;;
        *)          echo "claude-sonnet-4-20250514" ;;
    esac
}

LLM_MODEL="${LLM_MODEL:-$(get_default_model)}"

# Call LLM and return raw response
# Usage: call_llm "prompt"
call_llm() {
    local prompt="$1"
    local response

    case "$LLM_PROVIDER" in
        anthropic)
            response=$(call_anthropic "$prompt")
            ;;
        openrouter)
            response=$(call_openrouter "$prompt")
            ;;
        ollama)
            response=$(call_ollama "$prompt")
            ;;
        *)
            echo "Error: Unknown provider: $LLM_PROVIDER" >&2
            return 1
            ;;
    esac

    echo "$response"
}

# Anthropic Claude API
call_anthropic() {
    local prompt="$1"

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "Error: ANTHROPIC_API_KEY not set" >&2
        return 1
    fi

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg model "$LLM_MODEL" \
            --argjson max_tokens "$LLM_MAX_TOKENS" \
            --arg prompt "$prompt" \
            '{
                model: $model,
                max_tokens: $max_tokens,
                messages: [{ role: "user", content: $prompt }]
            }')" \
        "https://api.anthropic.com/v1/messages")

    # Extract text from response
    echo "$response" | jq -r '.content[0].text // empty'
}

# OpenRouter API (OpenAI-compatible)
call_openrouter() {
    local prompt="$1"

    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
        echo "Error: OPENROUTER_API_KEY not set" >&2
        return 1
    fi

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENROUTER_API_KEY" \
        -d "$(jq -n \
            --arg model "$LLM_MODEL" \
            --argjson max_tokens "$LLM_MAX_TOKENS" \
            --arg prompt "$prompt" \
            '{
                model: $model,
                max_tokens: $max_tokens,
                messages: [{ role: "user", content: $prompt }]
            }')" \
        "https://openrouter.ai/api/v1/chat/completions")

    # Extract text from OpenAI-style response
    echo "$response" | jq -r '.choices[0].message.content // empty'
}

# Ollama local API
call_ollama() {
    local prompt="$1"
    local ollama_url="${OLLAMA_URL:-http://localhost:11434}"

    local response
    response=$(curl -s --max-time "$LLM_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$LLM_MODEL" \
            --arg prompt "$prompt" \
            '{
                model: $model,
                prompt: $prompt,
                stream: false
            }')" \
        "$ollama_url/api/generate")

    # Extract response text
    echo "$response" | jq -r '.response // empty'
}

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

# Validate response structure
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

# Check if response indicates completion
# Usage: if is_done "$json"; then ...
is_done() {
    local json="$1"
    local done_val
    done_val=$(echo "$json" | jq -r '.done // false')
    [ "$done_val" = "true" ]
}

# Get message from response
# Usage: message=$(get_message "$json")
get_message() {
    local json="$1"
    echo "$json" | jq -r '.message // "No message"'
}
