#!/bin/bash
# =============================================================================
# Inferno CLI - Universal Agent Proxy
#
# Makes ANY LLM an agent through:
#   1. Native tool-use for supported providers (Anthropic, OpenAI)
#   2. JSON proxy mode for all other models (DeepSeek, Ollama, etc)
#   3. Automatic task routing to optimal models
#   4. Scope/permission control for safe execution
#
# Usage:
#   ./inferno-cli.sh "Create hello.ts and run tsc"
#   echo "Fix the bug" | ./inferno-cli.sh
#   ./inferno-cli.sh --scope="src/" --prompt "Refactor utils"
#
# Environment:
#   LLM_PROVIDER      - anthropic (default), openrouter, ollama, openai
#   LLM_MODEL         - Model name (provider-specific)
#   INFERNO_MODE      - auto, native, or proxy (default: auto)
#   INFERNO_AUTO_ROUTE - Enable task→model routing (default: true)
#   MAX_ITERATIONS    - Max agent loop iterations (default: 20)
#   VERBOSE           - Show detailed output (default: false)
#
# Exit codes:
#   0 - Success (task completed with "done" tool)
#   1 - Error (LLM error, JSON parse error, or tool failed)
#   2 - Max iterations reached without completion
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load libraries
source "$LIB_DIR/llm.sh"
source "$LIB_DIR/tools.sh"
source "$LIB_DIR/router.sh"

# Keep executor.sh for backwards compatibility
if [ -f "$LIB_DIR/executor.sh" ]; then
    source "$LIB_DIR/executor.sh"
fi

# Config
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
VERBOSE="${VERBOSE:-false}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log() { echo -e "$1"; }
log_verbose() { [ "$VERBOSE" = "true" ] && echo -e "${GRAY}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}" >&2; }
log_tool() { echo -e "${CYAN}→ $1${NC}"; }
log_result() { echo -e "${GRAY}$1${NC}"; }

# =============================================================================
# Message Management
# =============================================================================

# Initialize conversation with user prompt
# Usage: messages=$(init_messages "Fix the bug")
init_messages() {
    local user_prompt="$1"
    jq -n --arg content "$user_prompt" '[{"role": "user", "content": $content}]'
}

# Append assistant message (for native tool-use mode)
# Usage: messages=$(append_assistant_message "$messages" "$response")
append_assistant_message() {
    local messages="$1"
    local response="$2"

    # For Anthropic format, append the content array
    if echo "$response" | jq -e '.content' >/dev/null 2>&1; then
        local content
        content=$(echo "$response" | jq -c '.content')
        echo "$messages" | jq --argjson content "$content" '. + [{"role": "assistant", "content": $content}]'
    else
        # For text responses
        local text
        text=$(echo "$response" | jq -r '. // empty')
        echo "$messages" | jq --arg text "$text" '. + [{"role": "assistant", "content": $text}]'
    fi
}

# Append tool result (for native tool-use mode)
# Usage: messages=$(append_tool_result "$messages" "$tool_use_id" "$result")
append_tool_result() {
    local messages="$1"
    local tool_use_id="$2"
    local result="$3"

    echo "$messages" | jq --arg id "$tool_use_id" --arg result "$result" \
        '. + [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": $id, "content": $result}]}]'
}

# Append assistant JSON and result for proxy mode
# Usage: messages=$(append_proxy_turn "$messages" "$json_response" "$result")
append_proxy_turn() {
    local messages="$1"
    local assistant_json="$2"
    local tool_result="$3"

    # Add assistant's JSON response and the tool result as user message
    echo "$messages" | jq \
        --arg assistant "$assistant_json" \
        --arg result "$tool_result" \
        '. + [{"role": "assistant", "content": $assistant}, {"role": "user", "content": ("Tool result:\n" + $result)}]'
}

# =============================================================================
# Agent Loop - Native Tool-Use Mode
# =============================================================================

# Run agent loop with native tool-use (Anthropic, OpenAI)
run_native_agent_loop() {
    local prompt="$1"
    local iteration=0
    local messages
    local system_prompt="You are a coding agent. Complete the task using the available tools. When the task is fully complete, call the 'done' tool with a summary message."

    messages=$(init_messages "$prompt")

    while [ $iteration -lt $MAX_ITERATIONS ]; do
        ((iteration++))
        log_verbose "Iteration $iteration/$MAX_ITERATIONS (native mode)"

        # Call LLM with tools
        local response
        response=$(call_llm_agent "$messages" "$system_prompt")

        if [ -z "$response" ] || echo "$response" | jq -e '.error' >/dev/null 2>&1; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.error // "Empty response"')
            log_error "LLM Error: $error_msg"
            return 1
        fi

        # Parse tool calls
        local tool_calls
        tool_calls=$(parse_anthropic_tool_calls "$response")

        # If no tool calls, check if model is done talking
        if [ "$tool_calls" = "[]" ] || [ -z "$tool_calls" ]; then
            local text_content
            text_content=$(extract_native_text "$response")
            if [ -n "$text_content" ]; then
                log "$text_content"
            fi

            # Check for stop reason
            if has_stop_reason "$response"; then
                log "${YELLOW}⚠️  Agent finished without calling done tool${NC}"
                return 2
            fi

            # Append response and continue
            messages=$(append_assistant_message "$messages" "$response")
            continue
        fi

        # Append assistant message with tool calls
        messages=$(append_assistant_message "$messages" "$response")

        # Execute each tool call
        local all_done=false
        while read -r tool_call; do
            local name params id
            name=$(echo "$tool_call" | jq -r '.name')
            params=$(echo "$tool_call" | jq -c '.params')
            id=$(echo "$tool_call" | jq -r '.id')

            log_tool "$name"
            log_verbose "  Params: $params"

            # Execute tool
            local result exit_code
            result=$(execute_tool "$name" "$params")
            exit_code=$?

            # Truncate long results for display
            local display_result="$result"
            if [ ${#result} -gt 500 ]; then
                display_result="${result:0:500}..."
            fi
            log_result "$display_result"

            # Append tool result
            messages=$(append_tool_result "$messages" "$id" "$result")

            # Check for done signal
            if [ $exit_code -eq 100 ]; then
                all_done=true
                break
            fi
        done <<< "$(echo "$tool_calls" | jq -c '.[]')"

        if [ "$all_done" = true ]; then
            log "${GREEN}✅ Task completed${NC}"
            return 0
        fi
    done

    log_error "Max iterations ($MAX_ITERATIONS) reached"
    return 2
}

# =============================================================================
# Agent Loop - JSON Proxy Mode
# =============================================================================

# Run agent loop with JSON proxy (for models without native tool-use)
run_proxy_agent_loop() {
    local prompt="$1"
    local iteration=0
    local messages

    # Initialize with enhanced prompt including task context
    local enhanced_prompt="TASK: $prompt

Please use the tools to complete this task. Start by reading any relevant files if needed, then make your changes, and finally call 'done' when complete."

    messages=$(init_messages "$enhanced_prompt")

    while [ $iteration -lt $MAX_ITERATIONS ]; do
        ((iteration++))
        log_verbose "Iteration $iteration/$MAX_ITERATIONS (proxy mode)"

        # Call LLM (returns text, not structured response)
        local response
        response=$(call_with_json_proxy "$messages")

        if [ -z "$response" ]; then
            log_error "Empty response from LLM"
            return 1
        fi

        log_verbose "Raw response: ${response:0:200}..."

        # Parse JSON from response
        local json
        json=$(extract_json "$response")

        if [ "$json" = "null" ] || [ -z "$json" ]; then
            # Model returned text without JSON - try to prompt it to use tools
            log_verbose "Non-JSON response, prompting for tool use"
            messages=$(jq --arg resp "$response" '. + [{"role": "assistant", "content": $resp}, {"role": "user", "content": "Please respond with a JSON tool call. Remember to use the format: {\"reasoning\": \"...\", \"tool\": \"tool_name\", \"params\": {...}}"}]' <<< "$messages")
            continue
        fi

        # Extract tool call
        local tool_name tool_params reasoning
        tool_name=$(echo "$json" | jq -r '.tool // empty')
        tool_params=$(echo "$json" | jq -c '.params // {}')
        reasoning=$(echo "$json" | jq -r '.reasoning // empty')

        if [ -z "$tool_name" ]; then
            log_verbose "No tool in response, prompting..."
            messages=$(jq --arg resp "$response" '. + [{"role": "assistant", "content": $resp}, {"role": "user", "content": "Please call a tool using the JSON format. What tool do you want to use next?"}]' <<< "$messages")
            continue
        fi

        # Log reasoning if present
        if [ -n "$reasoning" ]; then
            log "${GRAY}💭 $reasoning${NC}"
        fi

        log_tool "$tool_name"
        log_verbose "  Params: $tool_params"

        # Execute tool
        local result exit_code
        result=$(execute_tool "$tool_name" "$tool_params")
        exit_code=$?

        # Display result (truncated)
        local display_result="$result"
        if [ ${#result} -gt 500 ]; then
            display_result="${result:0:500}..."
        fi
        log_result "$display_result"

        # Check for done signal
        if [ $exit_code -eq 100 ]; then
            log "${GREEN}✅ Task completed${NC}"
            return 0
        fi

        # Append turn to conversation
        messages=$(append_proxy_turn "$messages" "$response" "$result")
    done

    log_error "Max iterations ($MAX_ITERATIONS) reached"
    return 2
}

# =============================================================================
# Main Agent Entry Point
# =============================================================================

# Run the universal agent loop
# Automatically selects native or proxy mode based on provider
run_agent() {
    local prompt="$1"

    # Load configurations
    load_scope_config
    load_task_router_config

    # Auto-route if enabled
    if [ "$INFERNO_AUTO_ROUTE" = "true" ]; then
        local route
        route=$(get_route_for_prompt "$prompt")
        apply_route "$route"

        local task_type
        task_type=$(echo "$route" | jq -r '.task_type')
        log "${BLUE}📋 Task: $task_type → ${LLM_MODEL} (${LLM_PROVIDER})${NC}"
    fi

    local mode
    mode=$(get_provider_mode)
    log_verbose "Mode: $mode"

    if [ "$mode" = "native" ]; then
        run_native_agent_loop "$prompt"
    else
        run_proxy_agent_loop "$prompt"
    fi
}

# =============================================================================
# Legacy Mode (backwards compatibility)
# =============================================================================

# Run in legacy one-shot mode (for backwards compatibility)
run_legacy_mode() {
    local prompt="$1"
    local context="${2:-}"

    # Build prompt in old format
    local full_prompt
    full_prompt=$(cat << EOF
You are a coding agent. Implement this task:

$prompt

${context:+CONTEXT:
$context

}RESPOND WITH VALID JSON ONLY:
{
  "files": [{"path": "src/example.ts", "content": "..."}],
  "commands": ["npm install"],
  "done": true,
  "message": "Brief status"
}
EOF
)

    local response
    response=$(call_llm "$full_prompt")

    local json
    json=$(extract_json "$response")

    if ! validate_response "$json"; then
        log_error "Invalid JSON response"
        return 1
    fi

    # Apply files (using executor.sh)
    if type apply_files &>/dev/null; then
        apply_files "$json"
    fi

    # Run commands
    if type run_commands &>/dev/null; then
        run_commands "$json"
    fi

    # Get result
    local message
    message=$(get_message "$json")
    log "💬 $message"

    if is_done "$json"; then
        log "${GREEN}✅ Done${NC}"
        return 0
    else
        return 2
    fi
}

# =============================================================================
# CLI Interface
# =============================================================================

show_help() {
    cat << 'EOF'
Inferno CLI - Universal Agent Proxy

Makes ANY LLM an agent through native tool-use or JSON proxy mode.

USAGE:
  ./inferno-cli.sh "prompt"              Run with prompt
  echo "prompt" | ./inferno-cli.sh       Run with prompt from stdin
  ./inferno-cli.sh --prompt-file f       Run with prompt from file

OPTIONS:
  --help, -h                Show this help
  --verbose, -v             Show detailed output
  --scope PATH              Restrict to paths (comma-separated)
  --deny-paths PATH         Deny access to paths
  --allow-commands CMDS     Only allow these commands
  --deny-commands CMDS      Deny these commands
  --mode MODE               Force mode: auto, native, or proxy
  --no-route                Disable auto task→model routing
  --legacy                  Use legacy one-shot mode
  --config FILE             Use custom config file (default: .infernorc)
  --dry-run                 Show routing decision without executing

ENVIRONMENT:
  LLM_PROVIDER              anthropic (default), openrouter, ollama, openai
  LLM_MODEL                 Model name (provider-specific)
  INFERNO_MODE              auto, native, or proxy (default: auto)
  INFERNO_AUTO_ROUTE        Enable task routing (default: true)
  MAX_ITERATIONS            Max agent iterations (default: 20)
  VERBOSE                   Show detailed output (default: false)

  ANTHROPIC_API_KEY         Required for Anthropic
  OPENROUTER_API_KEY        Required for OpenRouter
  OPENAI_API_KEY            Required for OpenAI

SCOPE CONTROL:
  # Restrict to src/ directory
  ./inferno-cli.sh --scope="src/" "Refactor utils"

  # Deny access to secrets
  ./inferno-cli.sh --deny-paths=".env,*.key" "Read config"

  # Only allow npm commands
  ./inferno-cli.sh --allow-commands="npm *" "Install deps"

TASK ROUTING:
  Configure in .infernorc:
  {
    "taskModels": {
      "architect": "claude-opus",
      "codegen": "deepseek/deepseek-chat",
      "fix": "gemini-flash"
    }
  }

EXIT CODES:
  0  Success (task completed)
  1  Error (LLM error, tool error)
  2  Incomplete (max iterations or no done signal)

EXAMPLES:
  # Simple task
  ./inferno-cli.sh "Create hello.ts with a greet function"

  # Multi-step task
  ./inferno-cli.sh "Create src/utils.ts, add tests, run npm test"

  # With DeepSeek via OpenRouter
  LLM_PROVIDER=openrouter LLM_MODEL=deepseek/deepseek-chat \
    ./inferno-cli.sh "Fix the TypeScript error in App.tsx"

  # Scoped execution
  ./inferno-cli.sh --scope="src/,tests/" "Refactor the auth module"

  # Dry run (show routing)
  ./inferno-cli.sh --dry-run "Plan the architecture for a new feature"
EOF
}

main() {
    local prompt=""
    local config_file=".infernorc"
    local dry_run=false
    local legacy_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --scope)
                INFERNO_SCOPE_PATHS="$2"
                shift 2
                ;;
            --scope=*)
                INFERNO_SCOPE_PATHS="${1#*=}"
                shift
                ;;
            --deny-paths)
                INFERNO_DENY_PATHS="$2"
                shift 2
                ;;
            --deny-paths=*)
                INFERNO_DENY_PATHS="${1#*=}"
                shift
                ;;
            --allow-commands)
                INFERNO_ALLOW_COMMANDS="$2"
                shift 2
                ;;
            --allow-commands=*)
                INFERNO_ALLOW_COMMANDS="${1#*=}"
                shift
                ;;
            --deny-commands)
                INFERNO_DENY_COMMANDS="$2"
                shift 2
                ;;
            --deny-commands=*)
                INFERNO_DENY_COMMANDS="${1#*=}"
                shift
                ;;
            --mode)
                INFERNO_MODE="$2"
                shift 2
                ;;
            --mode=*)
                INFERNO_MODE="${1#*=}"
                shift
                ;;
            --no-route)
                INFERNO_AUTO_ROUTE=false
                shift
                ;;
            --legacy)
                legacy_mode=true
                shift
                ;;
            --config)
                config_file="$2"
                shift 2
                ;;
            --config=*)
                config_file="${1#*=}"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --prompt-file)
                if [ -z "${2:-}" ] || [ ! -f "$2" ]; then
                    log_error "Error: --prompt-file requires a valid file path"
                    exit 1
                fi
                prompt=$(cat "$2")
                shift 2
                ;;
            --prompt-file=*)
                local file="${1#*=}"
                if [ ! -f "$file" ]; then
                    log_error "Error: File not found: $file"
                    exit 1
                fi
                prompt=$(cat "$file")
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                prompt="$1"
                shift
                ;;
        esac
    done

    # Read from stdin if no prompt provided
    if [ -z "$prompt" ]; then
        if [ -t 0 ]; then
            log_error "Error: No prompt provided"
            log_error "Usage: ./inferno-cli.sh \"prompt\" or echo \"prompt\" | ./inferno-cli.sh"
            exit 1
        fi
        prompt=$(cat)
    fi

    if [ -z "$prompt" ]; then
        log_error "Error: Empty prompt"
        exit 1
    fi

    # Load config
    load_scope_config "$config_file"
    load_task_router_config "$config_file"

    # Dry run - just show routing
    if [ "$dry_run" = true ]; then
        echo "Dry run - routing decision:"
        echo ""
        local route
        route=$(get_route_for_prompt "$prompt")
        echo "$route" | jq .
        echo ""
        echo "Task classification:"
        get_task_classification "$prompt" | jq .
        echo ""
        echo "Complexity: $(assess_task_complexity "$prompt")"
        exit 0
    fi

    # Run in appropriate mode
    if [ "$legacy_mode" = true ]; then
        run_legacy_mode "$prompt"
    else
        run_agent "$prompt"
    fi
}

main "$@"
