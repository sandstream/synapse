#!/bin/bash
# =============================================================================
# lib/tools.sh - Universal Tool Definitions, Execution & Scope Validation
#
# Provides agent-like tool execution for ALL LLMs, regardless of native support.
# Handles scope/permissions to control what models can access.
#
# Tools available:
#   - read_file(path): Read file contents
#   - write_file(path, content): Write/create file
#   - edit_file(path, old_string, new_string): Edit file with string replacement
#   - delete_file(path): Delete a file
#   - move_file(source, destination): Move or rename a file
#   - mkdir(path): Create directory
#   - bash(command): Execute shell command
#   - search(query, path): Search for pattern in files (grep)
#   - glob(pattern, path): Find files matching glob pattern
#   - list_files(path, pattern): List files in directory
#   - think(thought): Reason/plan without executing (returns thought)
#   - done(message): Mark task as complete
#
# Scope configuration (via .infernorc or environment):
#   INFERNO_SCOPE_PATHS      - Allowed paths (comma-separated, default: ./)
#   INFERNO_DENY_PATHS       - Denied paths (comma-separated)
#   INFERNO_ALLOW_COMMANDS   - Allowed command patterns
#   INFERNO_DENY_COMMANDS    - Denied command patterns
# =============================================================================

# Load scope from environment or defaults
INFERNO_SCOPE_PATHS="${INFERNO_SCOPE_PATHS:-./}"
INFERNO_DENY_PATHS="${INFERNO_DENY_PATHS:-}"
INFERNO_ALLOW_COMMANDS="${INFERNO_ALLOW_COMMANDS:-*}"
INFERNO_DENY_COMMANDS="${INFERNO_DENY_COMMANDS:-rm -rf /,sudo *,:(){ :|:& };:}"
INFERNO_TOOL_TIMEOUT="${INFERNO_TOOL_TIMEOUT:-60}"

# Tool schema for JSON proxy mode
# This is sent to models without native tool-use
get_tool_schema() {
    cat << 'EOF'
{
  "tools": [
    {
      "name": "read_file",
      "description": "Read contents of a file",
      "params": {"path": "string (required) - file path to read"}
    },
    {
      "name": "write_file",
      "description": "Write content to a file (creates directories if needed). Use for NEW files.",
      "params": {
        "path": "string (required) - file path to write",
        "content": "string (required) - full content to write"
      }
    },
    {
      "name": "edit_file",
      "description": "Edit an existing file by replacing a specific string. More efficient than write_file for small changes.",
      "params": {
        "path": "string (required) - file path to edit",
        "old_string": "string (required) - exact string to find and replace (must be unique in file)",
        "new_string": "string (required) - replacement string"
      }
    },
    {
      "name": "delete_file",
      "description": "Delete a file",
      "params": {"path": "string (required) - file path to delete"}
    },
    {
      "name": "move_file",
      "description": "Move or rename a file",
      "params": {
        "source": "string (required) - source file path",
        "destination": "string (required) - destination file path"
      }
    },
    {
      "name": "mkdir",
      "description": "Create a directory (including parent directories)",
      "params": {"path": "string (required) - directory path to create"}
    },
    {
      "name": "bash",
      "description": "Execute a shell command",
      "params": {"command": "string (required) - command to execute"}
    },
    {
      "name": "search",
      "description": "Search for pattern in files using grep (shows matching lines with context)",
      "params": {
        "query": "string (required) - regex pattern to search",
        "path": "string (optional) - directory to search in, default: ."
      }
    },
    {
      "name": "glob",
      "description": "Find files matching a glob pattern (e.g., **/*.ts, src/**/*.js)",
      "params": {
        "pattern": "string (required) - glob pattern (e.g., **/*.ts)",
        "path": "string (optional) - base directory, default: ."
      }
    },
    {
      "name": "list_files",
      "description": "List files in directory (shallow, use glob for recursive)",
      "params": {
        "path": "string (optional) - directory path, default: .",
        "pattern": "string (optional) - filename pattern, default: *"
      }
    },
    {
      "name": "think",
      "description": "Think/reason about the problem without taking action. Use for planning complex tasks.",
      "params": {"thought": "string (required) - your reasoning or plan"}
    },
    {
      "name": "done",
      "description": "Mark the task as complete",
      "params": {"message": "string (required) - completion message"}
    }
  ]
}
EOF
}

# Get tool schema as compact JSON for prompts
get_tool_schema_compact() {
    cat << 'EOF'
Available tools:
- read_file(path): Read a file's contents
- write_file(path, content): Create a new file with content
- edit_file(path, old_string, new_string): Edit file by replacing string (efficient for changes)
- delete_file(path): Delete a file
- move_file(source, destination): Move or rename a file
- mkdir(path): Create directory
- bash(command): Run a shell command
- search(query, path?): Search for pattern in files (grep)
- glob(pattern, path?): Find files matching pattern (e.g., **/*.ts)
- list_files(path?, pattern?): List files in directory
- think(thought): Reason/plan without taking action
- done(message): Mark task as complete
EOF
}

# =============================================================================
# Scope Validation
# =============================================================================

# Check if a path is within allowed scope
# Usage: if is_path_allowed "/some/path"; then ...
is_path_allowed() {
    local check_path="$1"
    local current_dir
    current_dir=$(pwd)

    # Normalize path (resolve ../ etc)
    local normalized_path
    if [[ "$check_path" == /* ]]; then
        # Absolute path
        normalized_path=$(cd "$(dirname "$check_path")" 2>/dev/null && pwd)/$(basename "$check_path")
        normalized_path=${normalized_path:-$check_path}
    elif [[ "$check_path" == "." ]]; then
        normalized_path="$current_dir"
    elif [[ "$check_path" == "./"* ]]; then
        normalized_path="$current_dir/${check_path#./}"
    else
        normalized_path="$current_dir/$check_path"
    fi

    # Check denied paths first
    if [ -n "$INFERNO_DENY_PATHS" ]; then
        local OLD_IFS="$IFS"
        IFS=','
        for denied in $INFERNO_DENY_PATHS; do
            IFS="$OLD_IFS"
            denied=$(echo "$denied" | xargs)  # trim whitespace
            # Handle glob patterns
            if [[ "$normalized_path" == $denied ]] || \
               [[ "$check_path" == *"$denied"* ]] || \
               [[ "$normalized_path" == *".env"* ]] || \
               [[ "$normalized_path" == *".key"* ]] || \
               [[ "$normalized_path" == *"credentials"* ]]; then
                return 1
            fi
        done
        IFS="$OLD_IFS"
    fi

    # Check allowed paths
    local OLD_IFS="$IFS"
    IFS=','
    for allowed in $INFERNO_SCOPE_PATHS; do
        IFS="$OLD_IFS"
        allowed=$(echo "$allowed" | xargs)  # trim whitespace

        # Resolve allowed path relative to current directory
        local allowed_full
        if [[ "$allowed" == /* ]]; then
            allowed_full="$allowed"
        else
            allowed_full="$current_dir/$allowed"
        fi
        allowed_full=$(realpath -m "$allowed_full" 2>/dev/null || echo "$allowed_full")

        # Check if path starts with allowed path or equals it
        if [[ "$normalized_path" == "$allowed_full"* ]] || \
           [[ "$normalized_path" == "$allowed_full" ]] || \
           [[ "$normalized_path" == "$current_dir"* ]] || \
           [[ "$normalized_path" == "$current_dir" ]]; then
            IFS="$OLD_IFS"
            return 0
        fi
    done
    IFS="$OLD_IFS"

    return 1
}

# Check if a command is allowed
# Usage: if is_command_allowed "npm install"; then ...
is_command_allowed() {
    local cmd="$1"

    # Check denied commands first (more specific patterns)
    if [ -n "$INFERNO_DENY_COMMANDS" ]; then
        local OLD_IFS="$IFS"
        IFS=','
        for denied in $INFERNO_DENY_COMMANDS; do
            IFS="$OLD_IFS"
            denied=$(echo "$denied" | xargs)  # trim whitespace

            # Exact dangerous commands
            case "$cmd" in
                "rm -rf /"*|"rm -rf /*"|"sudo "*|":(){ :|:& };:"*)
                    return 1
                    ;;
            esac

            # Pattern matching (convert * to .*)
            local pattern="${denied//\*/.*}"
            if [[ "$cmd" =~ ^$pattern$ ]]; then
                return 1
            fi
        done
        IFS="$OLD_IFS"
    fi

    # Check allowed commands (if not wildcard)
    if [ "$INFERNO_ALLOW_COMMANDS" != "*" ]; then
        local OLD_IFS="$IFS"
        IFS=','
        for allowed in $INFERNO_ALLOW_COMMANDS; do
            IFS="$OLD_IFS"
            allowed=$(echo "$allowed" | xargs)
            local pattern="${allowed//\*/.*}"
            if [[ "$cmd" =~ ^$pattern$ ]]; then
                return 0
            fi
        done
        IFS="$OLD_IFS"
        return 1  # Not in allow list
    fi

    return 0  # Wildcard allows all (except denied)
}

# Validate tool call against scope
# Usage: if validate_scope "read_file" '{"path": "/etc/passwd"}'; then ...
validate_scope() {
    local tool_name="$1"
    local params="$2"

    case "$tool_name" in
        read_file|write_file|edit_file|delete_file|list_files|mkdir|glob)
            local path
            path=$(echo "$params" | jq -r '.path // "."')
            if ! is_path_allowed "$path"; then
                echo "SCOPE_DENIED: Path '$path' is outside allowed scope"
                return 1
            fi
            ;;
        move_file)
            local source dest
            source=$(echo "$params" | jq -r '.source')
            dest=$(echo "$params" | jq -r '.destination')
            if ! is_path_allowed "$source"; then
                echo "SCOPE_DENIED: Source path '$source' is outside allowed scope"
                return 1
            fi
            if ! is_path_allowed "$dest"; then
                echo "SCOPE_DENIED: Destination path '$dest' is outside allowed scope"
                return 1
            fi
            ;;
        search)
            local path
            path=$(echo "$params" | jq -r '.path // "."')
            if ! is_path_allowed "$path"; then
                echo "SCOPE_DENIED: Search path '$path' is outside allowed scope"
                return 1
            fi
            ;;
        bash)
            local cmd
            cmd=$(echo "$params" | jq -r '.command')
            if ! is_command_allowed "$cmd"; then
                echo "SCOPE_DENIED: Command '$cmd' is not allowed"
                return 1
            fi
            ;;
        done|think)
            # Always allowed
            return 0
            ;;
        *)
            echo "UNKNOWN_TOOL: '$tool_name' is not a valid tool"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# Tool Execution
# =============================================================================

# Execute a tool and return result
# Usage: result=$(execute_tool "read_file" '{"path": "src/main.ts"}')
# Exit codes:
#   0   - Success
#   1   - Error (file not found, command failed, etc)
#   100 - Done signal (task complete)
execute_tool() {
    local tool_name="$1"
    local params="$2"

    # Validate scope first
    local scope_error
    scope_error=$(validate_scope "$tool_name" "$params")
    if [ $? -ne 0 ]; then
        echo "$scope_error"
        return 1
    fi

    case "$tool_name" in
        read_file)
            execute_read_file "$params"
            ;;
        write_file)
            execute_write_file "$params"
            ;;
        edit_file)
            execute_edit_file "$params"
            ;;
        delete_file)
            execute_delete_file "$params"
            ;;
        move_file)
            execute_move_file "$params"
            ;;
        mkdir)
            execute_mkdir "$params"
            ;;
        bash)
            execute_bash "$params"
            ;;
        search)
            execute_search "$params"
            ;;
        glob)
            execute_glob "$params"
            ;;
        list_files)
            execute_list_files "$params"
            ;;
        think)
            execute_think "$params"
            ;;
        done)
            execute_done "$params"
            return 100  # Special exit code for done
            ;;
        *)
            echo "ERROR: Unknown tool '$tool_name'"
            return 1
            ;;
    esac
}

# Tool: read_file
execute_read_file() {
    local params="$1"
    local path
    path=$(echo "$params" | jq -r '.path')

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        echo "ERROR: read_file requires 'path' parameter"
        return 1
    fi

    if [ -f "$path" ]; then
        # Limit output to prevent context explosion
        local content
        content=$(head -c 100000 "$path")
        local size
        size=$(wc -c < "$path")

        if [ "$size" -gt 100000 ]; then
            echo "--- $path (truncated, ${size} bytes total) ---"
        else
            echo "--- $path ---"
        fi
        echo "$content"
    elif [ -d "$path" ]; then
        echo "ERROR: '$path' is a directory, not a file. Use list_files or glob to see contents."
        return 1
    else
        echo "ERROR: File not found: $path"
        return 1
    fi
}

# Tool: write_file
execute_write_file() {
    local params="$1"
    local path content
    path=$(echo "$params" | jq -r '.path')
    content=$(echo "$params" | jq -r '.content')

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        echo "ERROR: write_file requires 'path' parameter"
        return 1
    fi

    if [ -z "$content" ] || [ "$content" = "null" ]; then
        echo "ERROR: write_file requires 'content' parameter"
        return 1
    fi

    # Create directory if needed
    local dir
    dir=$(dirname "$path")
    if [ "$dir" != "." ] && [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            echo "ERROR: Could not create directory: $dir"
            return 1
        }
    fi

    # Write file
    printf '%s' "$content" > "$path" || {
        echo "ERROR: Could not write to file: $path"
        return 1
    }

    local bytes
    bytes=$(wc -c < "$path")
    echo "✓ Written: $path ($bytes bytes)"
}

# Tool: edit_file
execute_edit_file() {
    local params="$1"
    local path old_string new_string
    path=$(echo "$params" | jq -r '.path')
    old_string=$(echo "$params" | jq -r '.old_string')
    new_string=$(echo "$params" | jq -r '.new_string')

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        echo "ERROR: edit_file requires 'path' parameter"
        return 1
    fi

    if [ -z "$old_string" ] || [ "$old_string" = "null" ]; then
        echo "ERROR: edit_file requires 'old_string' parameter"
        return 1
    fi

    if [ "$new_string" = "null" ]; then
        new_string=""
    fi

    if [ ! -f "$path" ]; then
        echo "ERROR: File not found: $path"
        return 1
    fi

    # Read the file
    local content
    content=$(cat "$path")

    # Check if old_string exists and is unique
    local count
    count=$(grep -F -c "$old_string" "$path" 2>/dev/null || echo "0")

    if [ "$count" -eq 0 ]; then
        echo "ERROR: String not found in file. Make sure old_string matches exactly."
        echo "--- First 50 lines of $path ---"
        head -50 "$path"
        return 1
    fi

    if [ "$count" -gt 1 ]; then
        echo "ERROR: String found $count times in file. old_string must be unique."
        echo "Add more context to make it unique."
        echo "--- Matches ---"
        grep -n -F "$old_string" "$path" | head -10
        return 1
    fi

    # Perform the replacement using awk for robustness with special chars
    local new_content
    new_content=$(awk -v old="$old_string" -v new="$new_string" '
    BEGIN { found = 0 }
    {
        if (!found && index($0, old) > 0) {
            # Found the line containing old_string
            # We need to handle multiline old_string
            found = 1
        }
        print
    }
    ' "$path")

    # Use perl for proper multiline replacement (more robust)
    perl -i -p0e "s/\Q$old_string\E/$new_string/s" "$path" 2>/dev/null

    if [ $? -ne 0 ]; then
        # Fallback: use temp file approach
        local temp_file
        temp_file=$(mktemp)

        # Use Python if available for robust replacement
        if command -v python3 &>/dev/null; then
            python3 -c "
import sys
with open('$path', 'r') as f:
    content = f.read()
old_str = '''$old_string'''
new_str = '''$new_string'''
if old_str not in content:
    sys.exit(1)
content = content.replace(old_str, new_str, 1)
with open('$path', 'w') as f:
    f.write(content)
" 2>/dev/null
        else
            # Last resort: simple sed (may fail with special chars)
            sed -i.bak "s|$old_string|$new_string|" "$path" 2>/dev/null
            rm -f "${path}.bak"
        fi
    fi

    local bytes
    bytes=$(wc -c < "$path")
    echo "✓ Edited: $path ($bytes bytes)"
}

# Tool: delete_file
execute_delete_file() {
    local params="$1"
    local path
    path=$(echo "$params" | jq -r '.path')

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        echo "ERROR: delete_file requires 'path' parameter"
        return 1
    fi

    if [ ! -f "$path" ]; then
        echo "ERROR: File not found: $path"
        return 1
    fi

    rm "$path" || {
        echo "ERROR: Could not delete file: $path"
        return 1
    }

    echo "✓ Deleted: $path"
}

# Tool: move_file
execute_move_file() {
    local params="$1"
    local source dest
    source=$(echo "$params" | jq -r '.source')
    dest=$(echo "$params" | jq -r '.destination')

    if [ -z "$source" ] || [ "$source" = "null" ]; then
        echo "ERROR: move_file requires 'source' parameter"
        return 1
    fi

    if [ -z "$dest" ] || [ "$dest" = "null" ]; then
        echo "ERROR: move_file requires 'destination' parameter"
        return 1
    fi

    if [ ! -f "$source" ]; then
        echo "ERROR: Source file not found: $source"
        return 1
    fi

    # Create destination directory if needed
    local dest_dir
    dest_dir=$(dirname "$dest")
    if [ "$dest_dir" != "." ] && [ ! -d "$dest_dir" ]; then
        mkdir -p "$dest_dir" || {
            echo "ERROR: Could not create directory: $dest_dir"
            return 1
        }
    fi

    mv "$source" "$dest" || {
        echo "ERROR: Could not move file from $source to $dest"
        return 1
    }

    echo "✓ Moved: $source → $dest"
}

# Tool: mkdir
execute_mkdir() {
    local params="$1"
    local path
    path=$(echo "$params" | jq -r '.path')

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        echo "ERROR: mkdir requires 'path' parameter"
        return 1
    fi

    if [ -d "$path" ]; then
        echo "✓ Directory already exists: $path"
        return 0
    fi

    mkdir -p "$path" || {
        echo "ERROR: Could not create directory: $path"
        return 1
    }

    echo "✓ Created directory: $path"
}

# Tool: bash
execute_bash() {
    local params="$1"
    local cmd
    cmd=$(echo "$params" | jq -r '.command')

    if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
        echo "ERROR: bash requires 'command' parameter"
        return 1
    fi

    # Execute with timeout
    local output exit_code
    if command -v timeout &>/dev/null; then
        output=$(timeout "$INFERNO_TOOL_TIMEOUT" bash -c "$cmd" 2>&1)
        exit_code=$?
    elif command -v gtimeout &>/dev/null; then
        output=$(gtimeout "$INFERNO_TOOL_TIMEOUT" bash -c "$cmd" 2>&1)
        exit_code=$?
    else
        output=$(eval "$cmd" 2>&1)
        exit_code=$?
    fi

    # Truncate very long output
    if [ ${#output} -gt 50000 ]; then
        output="${output:0:50000}... (truncated)"
    fi

    if [ $exit_code -eq 0 ]; then
        echo "$ $cmd"
        [ -n "$output" ] && echo "$output"
        echo "✓ Exit code: 0"
    else
        echo "$ $cmd"
        [ -n "$output" ] && echo "$output"
        echo "✗ Exit code: $exit_code"
    fi

    return $exit_code
}

# Tool: search
execute_search() {
    local params="$1"
    local query path
    query=$(echo "$params" | jq -r '.query')
    path=$(echo "$params" | jq -r '.path // "."')

    if [ -z "$query" ] || [ "$query" = "null" ]; then
        echo "ERROR: search requires 'query' parameter"
        return 1
    fi

    # Use grep -r with context
    local results
    results=$(grep -rn --include="*" "$query" "$path" 2>/dev/null | head -100)

    if [ -z "$results" ]; then
        echo "No matches found for '$query' in $path"
    else
        local count
        count=$(echo "$results" | wc -l)
        echo "Found $count matches for '$query' in $path:"
        echo "$results"

        # Warn if truncated
        local total
        total=$(grep -r "$query" "$path" 2>/dev/null | wc -l)
        if [ "$total" -gt 100 ]; then
            echo "... (showing 100 of $total matches)"
        fi
    fi
}

# Tool: glob
execute_glob() {
    local params="$1"
    local pattern path
    pattern=$(echo "$params" | jq -r '.pattern')
    path=$(echo "$params" | jq -r '.path // "."')

    if [ -z "$pattern" ] || [ "$pattern" = "null" ]; then
        echo "ERROR: glob requires 'pattern' parameter"
        return 1
    fi

    if [ ! -d "$path" ]; then
        echo "ERROR: Directory not found: $path"
        return 1
    fi

    # Use find with pattern matching
    # Handle ** patterns by converting to find syntax
    local results

    if [[ "$pattern" == "**/"* ]]; then
        # Pattern like **/*.ts - recursive search
        local ext_pattern="${pattern#**/}"
        results=$(find "$path" -type f -name "$ext_pattern" 2>/dev/null | sort | head -200)
    elif [[ "$pattern" == *"**"* ]]; then
        # Pattern with ** somewhere - use find recursively
        local name_pattern="${pattern//\*\*\//}"
        name_pattern="${name_pattern//\*\*/}"
        results=$(find "$path" -type f -name "$name_pattern" 2>/dev/null | sort | head -200)
    else
        # Simple pattern - use find with maxdepth
        results=$(find "$path" -maxdepth 5 -type f -name "$pattern" 2>/dev/null | sort | head -200)
    fi

    if [ -z "$results" ]; then
        echo "No files found matching '$pattern' in $path"
    else
        local count
        count=$(echo "$results" | wc -l)
        echo "Found $count files matching '$pattern' in $path:"
        echo "$results"

        if [ "$count" -ge 200 ]; then
            echo "... (showing first 200 files)"
        fi
    fi
}

# Tool: list_files
execute_list_files() {
    local params="$1"
    local path pattern
    path=$(echo "$params" | jq -r '.path // "."')
    pattern=$(echo "$params" | jq -r '.pattern // "*"')

    if [ ! -d "$path" ]; then
        echo "ERROR: Directory not found: $path"
        return 1
    fi

    # List files with find (shallow by default)
    local results
    results=$(find "$path" -maxdepth 1 -name "$pattern" 2>/dev/null | sort | head -100)

    if [ -z "$results" ]; then
        echo "No files found in $path matching '$pattern'"
    else
        local count
        count=$(echo "$results" | wc -l)
        echo "Files in $path (pattern: $pattern):"
        echo "$results"

        # Warn if truncated
        local total
        total=$(find "$path" -maxdepth 1 -name "$pattern" 2>/dev/null | wc -l)
        if [ "$total" -gt 100 ]; then
            echo "... (showing 100 of $total files)"
        fi
    fi
}

# Tool: think
execute_think() {
    local params="$1"
    local thought
    thought=$(echo "$params" | jq -r '.thought // "No thought provided"')

    echo "💭 Thinking: $thought"
    # Think tool doesn't do anything - just lets the model reason
    # Return success so it can continue
}

# Tool: done
execute_done() {
    local params="$1"
    local message
    message=$(echo "$params" | jq -r '.message // "Task completed"')

    echo "✅ DONE: $message"
}

# =============================================================================
# Tool Call Parsing
# =============================================================================

# Parse tool calls from LLM response (JSON proxy format)
# Input: JSON response from LLM in proxy mode
# Output: JSON array of tool calls
parse_json_proxy_response() {
    local response="$1"

    # Try to extract JSON from the response
    local json

    # First, try to find a JSON object directly
    if echo "$response" | jq -e . >/dev/null 2>&1; then
        json="$response"
    else
        # Try to extract from markdown code block
        json=$(echo "$response" | sed -n '/```json/,/```/p' | sed '1d;$d')
        if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
            # Try plain code block
            json=$(echo "$response" | sed -n '/```/,/```/p' | sed '1d;$d')
        fi
        if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
            # Try to find JSON object in text
            json=$(echo "$response" | grep -o '{[^}]*}' | head -1)
        fi
    fi

    # Validate we got JSON
    if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
        echo "null"
        return 1
    fi

    # Check if this is a tool call (has "tool" field)
    if echo "$json" | jq -e '.tool' >/dev/null 2>&1; then
        # Single tool call format: {"tool": "name", "params": {...}}
        local tool_name tool_params
        tool_name=$(echo "$json" | jq -r '.tool')
        tool_params=$(echo "$json" | jq -c '.params // {}')

        # Return as array of tool calls
        jq -n --arg name "$tool_name" --argjson params "$tool_params" \
            '[{"name": $name, "params": $params}]'
    elif echo "$json" | jq -e '.tools' >/dev/null 2>&1; then
        # Multiple tool calls format: {"tools": [{"name": "...", "params": {...}}, ...]}
        echo "$json" | jq -c '.tools'
    else
        # No tool calls - might be text response
        echo "null"
    fi
}

# Parse native tool-use response (Anthropic format)
# Input: API response with tool_use blocks
# Output: JSON array of tool calls
parse_native_tool_response() {
    local response="$1"

    # Anthropic format: content array with tool_use blocks
    if echo "$response" | jq -e '.content' >/dev/null 2>&1; then
        echo "$response" | jq -c '[.content[] | select(.type == "tool_use") | {name: .name, params: .input, id: .id}]'
    else
        echo "null"
    fi
}

# Extract text content from LLM response
# Works for both proxy mode (plain text) and native mode (content array)
extract_text_content() {
    local response="$1"

    # Check if it's Anthropic format with content array
    if echo "$response" | jq -e '.content' >/dev/null 2>&1; then
        echo "$response" | jq -r '[.content[] | select(.type == "text") | .text] | join("\n")'
    else
        # Plain text - extract any non-JSON text
        echo "$response" | sed 's/```json[^`]*```//g' | sed 's/```[^`]*```//g' | xargs
    fi
}

# =============================================================================
# Scope Configuration Loading
# =============================================================================

# Load scope configuration from .infernorc file
load_scope_config() {
    local config_file="${1:-.infernorc}"

    if [ ! -f "$config_file" ]; then
        return 0  # Use defaults
    fi

    # Load scope paths
    local scope_paths
    scope_paths=$(jq -r '.scope.paths // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$scope_paths" ] && [ "$scope_paths" != "" ]; then
        INFERNO_SCOPE_PATHS="$scope_paths"
    fi

    # Load denied paths
    local deny_paths
    deny_paths=$(jq -r '.scope.deny_paths // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$deny_paths" ] && [ "$deny_paths" != "" ]; then
        INFERNO_DENY_PATHS="$deny_paths"
    fi

    # Load allowed commands
    local allow_cmds
    allow_cmds=$(jq -r '.scope.allow_commands // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$allow_cmds" ] && [ "$allow_cmds" != "" ]; then
        INFERNO_ALLOW_COMMANDS="$allow_cmds"
    fi

    # Load denied commands
    local deny_cmds
    deny_cmds=$(jq -r '.scope.deny_commands // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$deny_cmds" ] && [ "$deny_cmds" != "" ]; then
        INFERNO_DENY_COMMANDS="$deny_cmds"
    fi
}
