#!/bin/bash
# =============================================================================
# Inferno CLI - Core LLM coding agent
#
# A standalone CLI for LLM-powered code generation. Takes a prompt and:
#   1. Calls LLM via lib/llm.sh
#   2. Parses JSON response
#   3. Applies files via lib/executor.sh
#   4. Runs commands
#   5. Returns exit code based on success
#
# Usage:
#   ./inferno-cli.sh "Create hello.txt with 'Hello World'"
#   echo "Create hello.txt" | ./inferno-cli.sh
#   ./inferno-cli.sh --prompt-file prompt.txt
#
# Environment:
#   LLM_PROVIDER   - anthropic (default), openrouter, ollama
#   LLM_MODEL      - Model name (provider-specific)
#   MAX_READ_FILES - Max file read iterations (default: 20)
#   VERBOSE        - Show detailed output (default: false)
#
# Exit codes:
#   0 - Success (LLM marked done=true and commands succeeded)
#   1 - Error (LLM error, JSON parse error, or commands failed)
#   2 - Not done (LLM did not mark done=true)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load libraries
source "$LIB_DIR/llm.sh"
source "$LIB_DIR/executor.sh"

# Config
MAX_READ_FILES="${MAX_READ_FILES:-20}"
VERBOSE="${VERBOSE:-false}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

log() { echo -e "$1"; }
log_verbose() { [ "$VERBOSE" = "true" ] && echo -e "${GRAY}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}" >&2; }

# Build prompt with JSON instruction
build_cli_prompt() {
    local user_prompt="$1"
    local context="${2:-}"

    cat << EOF
You are a coding agent. Implement this task:

$user_prompt

${context:+CONTEXT:
$context

}RESPOND WITH VALID JSON ONLY (no markdown, no explanation):
{
  "files": [
    {"path": "src/example.ts", "content": "file content here"}
  ],
  "commands": ["npm install", "npm run build"],
  "read_files": ["src/existing.ts"],
  "done": true,
  "message": "Brief status message"
}

RULES:
- "files": Array of files to create/update. Use full file content, not diffs.
- "commands": Array of shell commands to run (npm install, build, etc)
- "read_files": Request to read existing files before continuing (optional, max $MAX_READ_FILES)
- "done": Set to true ONLY when task is fully implemented
- "message": Brief description of what you did

If you need to read existing files first, return ONLY read_files and done=false.
After reading, you'll get the file contents in CONTEXT.
EOF
}

# Main CLI function
run_cli() {
    local prompt="$1"
    local context=""
    local read_count=0

    log_verbose "Provider: ${LLM_PROVIDER:-anthropic}, Model: ${LLM_MODEL:-default}"

    while true; do
        # Build full prompt
        local full_prompt
        full_prompt=$(build_cli_prompt "$prompt" "$context")

        # Call LLM
        log_verbose "Calling LLM..."
        local llm_output
        llm_output=$(call_llm "$full_prompt")

        if [ -z "$llm_output" ] || [ "$llm_output" = "null" ]; then
            log_error "Error: Empty LLM response"
            return 1
        fi

        # Extract and validate JSON
        local json_response
        json_response=$(extract_json "$llm_output")

        if ! validate_response "$json_response"; then
            log_error "Error: Invalid JSON response"
            log_verbose "Raw output: ${llm_output:0:500}"
            return 1
        fi

        # Check if LLM wants to read files first
        local read_files
        read_files=$(echo "$json_response" | jq -r '.read_files // []')

        if [ "$read_files" != "[]" ] && [ "$read_files" != "null" ]; then
            ((read_count++))
            if [ $read_count -gt $MAX_READ_FILES ]; then
                log "${YELLOW}⚠️  Max read_files limit ($MAX_READ_FILES) reached${NC}"
                context="You have requested too many file reads. Please implement now with what you have. Set done=true when complete."
            else
                log_verbose "📖 Reading requested files... ($read_count/$MAX_READ_FILES)"
                context=$(read_requested_files "$json_response")
                continue
            fi
        fi

        # Apply files
        local files_count
        files_count=$(echo "$json_response" | jq -r '.files | length // 0')
        if [ "$files_count" -gt 0 ]; then
            log "📝 Applying $files_count file(s)..."
            apply_files "$json_response"
        fi

        # Run commands
        local commands_count
        commands_count=$(echo "$json_response" | jq -r '.commands | length // 0')
        if [ "$commands_count" -gt 0 ]; then
            log "🔧 Running $commands_count command(s)..."
        fi

        local cmd_output
        cmd_output=$(run_commands "$json_response" 2>&1)
        local cmd_exit=$?

        # Get message
        local message
        message=$(get_message "$json_response")
        log "💬 $message"

        # Check result
        if is_done "$json_response"; then
            if [ $cmd_exit -eq 0 ]; then
                log "${GREEN}✅ Done${NC}"
                return 0
            else
                log_error "Commands failed (exit $cmd_exit)"
                log_verbose "Output: $cmd_output"
                return 1
            fi
        else
            log "${YELLOW}⚠️  Not marked as done${NC}"
            return 2
        fi
    done
}

# Help
show_help() {
    cat << 'EOF'
Inferno CLI - Core LLM coding agent

USAGE:
  ./inferno-cli.sh "prompt"           Run with prompt argument
  echo "prompt" | ./inferno-cli.sh    Run with prompt from stdin
  ./inferno-cli.sh --prompt-file f    Run with prompt from file
  ./inferno-cli.sh --help             Show this help

ENVIRONMENT:
  LLM_PROVIDER      anthropic (default), openrouter, ollama
  LLM_MODEL         Model name (default: claude-sonnet-4-20250514)
  LLM_MAX_TOKENS    Max tokens (default: 8000)
  LLM_TIMEOUT       Timeout in seconds (default: 300)
  MAX_READ_FILES    Max file read iterations (default: 20)
  VERBOSE           Show detailed output (default: false)

  ANTHROPIC_API_KEY   Required for anthropic provider
  OPENROUTER_API_KEY  Required for openrouter provider

EXIT CODES:
  0  Success (LLM marked done=true and commands succeeded)
  1  Error (LLM error, JSON parse error, or commands failed)
  2  Not done (LLM did not mark done=true)

EXAMPLES:
  # Simple file creation
  ./inferno-cli.sh "Create hello.txt containing 'Hello World'"

  # From stdin
  echo "Add a sum function to math.ts" | ./inferno-cli.sh

  # Verbose mode
  VERBOSE=true ./inferno-cli.sh "Create a React component"

  # Using OpenRouter
  LLM_PROVIDER=openrouter LLM_MODEL=deepseek/deepseek-chat ./inferno-cli.sh "..."
EOF
}

# Main
main() {
    local prompt=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --prompt-file)
                if [ -z "${2:-}" ] || [ ! -f "$2" ]; then
                    log_error "Error: --prompt-file requires a valid file path"
                    exit 1
                fi
                prompt=$(cat "$2")
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
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

    run_cli "$prompt"
}

main "$@"
