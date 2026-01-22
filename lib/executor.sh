#!/bin/bash
# =============================================================================
# lib/executor.sh - File and command execution
#
# Handles:
#   - Applying files from JSON response
#   - Running commands from JSON response
#   - Reading requested files
# =============================================================================

# Apply files from JSON response
# Usage: apply_files "$json_response"
apply_files() {
    local json="$1"
    local files_json
    files_json=$(echo "$json" | jq -c '.files // []')

    if [ "$files_json" = "[]" ] || [ "$files_json" = "null" ]; then
        return 0
    fi

    echo "$files_json" | jq -c '.[]' | while read -r file_obj; do
        local path content
        path=$(echo "$file_obj" | jq -r '.path')
        content=$(echo "$file_obj" | jq -r '.content')

        if [ -z "$path" ] || [ "$path" = "null" ]; then
            continue
        fi

        # Create directory if needed
        local dir
        dir=$(dirname "$path")
        if [ "$dir" != "." ] && [ ! -d "$dir" ]; then
            mkdir -p "$dir"
        fi

        # Write file
        echo "$content" > "$path"
        echo "  → $path"
    done
}

# Run commands from JSON response
# Usage: output=$(run_commands "$json_response")
# Returns: exit code of last failed command, or 0 if all succeeded
run_commands() {
    local json="$1"
    local commands_json
    commands_json=$(echo "$json" | jq -c '.commands // []')

    if [ "$commands_json" = "[]" ] || [ "$commands_json" = "null" ]; then
        return 0
    fi

    local exit_code=0
    local cmd_output=""

    while read -r cmd; do
        if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
            continue
        fi

        echo "  $ $cmd"

        # Run command and capture output
        local output
        output=$(eval "$cmd" 2>&1)
        local cmd_exit=$?

        if [ -n "$output" ]; then
            echo "$output"
            cmd_output="${cmd_output}${output}"$'\n'
        fi

        if [ $cmd_exit -ne 0 ]; then
            exit_code=$cmd_exit
            echo "  ✗ Exit code: $cmd_exit"
        fi
    done < <(echo "$commands_json" | jq -r '.[]')

    echo "$cmd_output"
    return $exit_code
}

# Read files requested by LLM
# Usage: context=$(read_requested_files "$json_response")
read_requested_files() {
    local json="$1"
    local read_files_json
    read_files_json=$(echo "$json" | jq -c '.read_files // []')

    if [ "$read_files_json" = "[]" ] || [ "$read_files_json" = "null" ]; then
        echo ""
        return 0
    fi

    local context="FILE CONTENTS:"
    local files_read=0

    while read -r file_path; do
        if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
            continue
        fi

        if [ -f "$file_path" ]; then
            context="${context}"$'\n\n'"--- $file_path ---"$'\n'
            context="${context}$(cat "$file_path")"
            ((files_read++))
            echo "  → Read: $file_path" >&2
        else
            context="${context}"$'\n\n'"--- $file_path ---"$'\n'
            context="${context}[FILE NOT FOUND]"
            echo "  → Not found: $file_path" >&2
        fi
    done < <(echo "$read_files_json" | jq -r '.[]')

    if [ $files_read -eq 0 ]; then
        echo ""
    else
        echo "$context"
    fi
}

# Run a single command with timeout
# Usage: output=$(run_command_with_timeout "npm run build" 120)
run_command_with_timeout() {
    local cmd="$1"
    local timeout="${2:-120}"

    if command -v timeout &>/dev/null; then
        timeout "$timeout" bash -c "$cmd" 2>&1
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$timeout" bash -c "$cmd" 2>&1
    else
        # Fallback without timeout
        eval "$cmd" 2>&1
    fi
}

# Check if a command exists
# Usage: if command_exists "npm"; then ...
command_exists() {
    command -v "$1" &>/dev/null
}

# Get file extension
# Usage: ext=$(get_extension "file.ts")
get_extension() {
    local file="$1"
    echo "${file##*.}"
}

# Check if file is a test file
# Usage: if is_test_file "file.test.ts"; then ...
is_test_file() {
    local file="$1"
    [[ "$file" =~ \.(test|spec)\.(ts|tsx|js|jsx)$ ]] || [[ "$file" =~ ^tests?/ ]]
}
