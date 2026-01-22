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
#   - multi_edit(path, edits[]): Multiple edits on a file in one operation
#   - git(action, message?, files?): Git operations (status/diff/commit/log/undo/add)
#   - ask_user(question, options?): Ask user for input/confirmation
#   - web_fetch(url): Fetch content from a URL
#   - web_search(query): Search the web
#   - todo(action, items?): Manage internal task list (add/list/complete/clear)
#   - spawn_agent(task, model?): Spawn a sub-agent for parallel work
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
      "name": "multi_edit",
      "description": "Perform multiple edits on a single file in one operation. More efficient than multiple edit_file calls.",
      "params": {
        "path": "string (required) - file path to edit",
        "edits": "array (required) - array of {old_string, new_string} objects"
      }
    },
    {
      "name": "git",
      "description": "Git operations for version control",
      "params": {
        "action": "string (required) - status, diff, staged, add, commit, log, undo, branch, stash",
        "message": "string (optional) - commit message (required for commit)",
        "files": "string/array (optional) - file(s) to add or diff"
      }
    },
    {
      "name": "ask_user",
      "description": "Ask the user a question and wait for their response. Use for confirmations or gathering input.",
      "params": {
        "question": "string (required) - the question to ask",
        "options": "array (optional) - list of options for user to choose from"
      }
    },
    {
      "name": "web_fetch",
      "description": "Fetch content from a URL (returns text/markdown)",
      "params": {"url": "string (required) - the URL to fetch"}
    },
    {
      "name": "web_search",
      "description": "Search the web for information",
      "params": {"query": "string (required) - search query"}
    },
    {
      "name": "todo",
      "description": "Manage an internal task list for tracking progress",
      "params": {
        "action": "string (required) - add, list, complete, or clear",
        "items": "array/string (optional) - task(s) to add or complete"
      }
    },
    {
      "name": "spawn_agent",
      "description": "Spawn a sub-agent to work on a task in parallel",
      "params": {
        "task": "string (required) - the task for the sub-agent",
        "model": "string (optional) - specific model to use"
      }
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
- multi_edit(path, edits[]): Multiple edits on one file [{old_string, new_string}, ...]
- delete_file(path): Delete a file
- move_file(source, destination): Move or rename a file
- mkdir(path): Create directory
- bash(command): Run a shell command
- git(action, message?, files?): Git ops (status/diff/add/commit/log/undo/branch/stash)
- search(query, path?): Search for pattern in files (grep)
- glob(pattern, path?): Find files matching pattern (e.g., **/*.ts)
- list_files(path?, pattern?): List files in directory
- think(thought): Reason/plan without taking action
- ask_user(question, options?): Ask user for input/confirmation
- web_fetch(url): Fetch content from a URL
- web_search(query): Search the web for information
- todo(action, items?): Manage task list (add/list/complete/clear)
- spawn_agent(task, model?): Run sub-agent in parallel
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
        read_file|write_file|edit_file|multi_edit|delete_file|list_files|mkdir|glob)
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
        done|think|ask_user|todo|git)
            # Always allowed (git works within repo)
            return 0
            ;;
        web_fetch|web_search|spawn_agent)
            # Allowed but may require network
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
        multi_edit)
            execute_multi_edit "$params"
            ;;
        git)
            execute_git "$params"
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
        ask_user)
            execute_ask_user "$params"
            ;;
        web_fetch)
            execute_web_fetch "$params"
            ;;
        web_search)
            execute_web_search "$params"
            ;;
        todo)
            execute_todo "$params"
            ;;
        spawn_agent)
            execute_spawn_agent "$params"
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

# Tool: multi_edit
# Perform multiple edits on a single file in one operation
execute_multi_edit() {
    local params="$1"
    local path edits
    path=$(echo "$params" | jq -r '.path')
    edits=$(echo "$params" | jq -c '.edits')

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        echo "ERROR: multi_edit requires 'path' parameter"
        return 1
    fi

    if [ -z "$edits" ] || [ "$edits" = "null" ]; then
        echo "ERROR: multi_edit requires 'edits' array parameter"
        return 1
    fi

    if [ ! -f "$path" ]; then
        echo "ERROR: File not found: $path"
        return 1
    fi

    # Count edits
    local edit_count
    edit_count=$(echo "$edits" | jq 'length')

    if [ "$edit_count" -eq 0 ]; then
        echo "ERROR: edits array is empty"
        return 1
    fi

    # Read file content
    local content
    content=$(cat "$path")

    # Apply each edit in order
    local i=0
    local success_count=0
    local errors=""

    while [ $i -lt "$edit_count" ]; do
        local old_string new_string
        old_string=$(echo "$edits" | jq -r ".[$i].old_string")
        new_string=$(echo "$edits" | jq -r ".[$i].new_string // \"\"")

        if [ -z "$old_string" ] || [ "$old_string" = "null" ]; then
            errors="${errors}Edit $((i+1)): missing old_string\n"
            ((i++))
            continue
        fi

        # Check if old_string exists in current content
        if [[ "$content" != *"$old_string"* ]]; then
            errors="${errors}Edit $((i+1)): old_string not found\n"
            ((i++))
            continue
        fi

        # Replace (only first occurrence) - use temp var to avoid quoting issues
        local before="${content%%"$old_string"*}"
        local after="${content#*"$old_string"}"
        content="${before}${new_string}${after}"
        ((success_count++))
        ((i++))
    done

    # Write back if any edits succeeded
    if [ $success_count -gt 0 ]; then
        printf '%s' "$content" > "$path"
        local bytes
        bytes=$(wc -c < "$path")
        echo "✓ Multi-edit: $path - $success_count/$edit_count edits applied ($bytes bytes)"
    fi

    # Report errors if any
    if [ -n "$errors" ]; then
        printf "⚠️ Some edits failed:\n%b" "$errors"
    fi

    if [ $success_count -eq 0 ]; then
        return 1
    fi
}

# Tool: git
# Git operations: status, diff, commit, log, undo
execute_git() {
    local params="$1"
    local action message files
    action=$(echo "$params" | jq -r '.action')
    message=$(echo "$params" | jq -r '.message // empty')
    files=$(echo "$params" | jq -r '.files // empty')

    if [ -z "$action" ] || [ "$action" = "null" ]; then
        echo "ERROR: git requires 'action' parameter (status/diff/commit/log/undo/add)"
        return 1
    fi

    # Check if we're in a git repo
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "ERROR: Not in a git repository"
        return 1
    fi

    case "$action" in
        status)
            echo "📊 Git Status:"
            git status --short
            ;;

        diff)
            echo "📝 Git Diff:"
            if [ -n "$files" ] && [ "$files" != "null" ]; then
                git diff -- "$files"
            else
                git diff
            fi
            ;;

        staged)
            echo "📝 Staged Changes:"
            git diff --cached
            ;;

        add)
            if [ -z "$files" ] || [ "$files" = "null" ]; then
                echo "ERROR: git add requires 'files' parameter"
                return 1
            fi
            # Handle array or string
            if echo "$files" | jq -e 'type == "array"' >/dev/null 2>&1; then
                local file_list
                file_list=$(echo "$files" | jq -r '.[]')
                echo "$file_list" | while read -r f; do
                    git add "$f" && echo "✓ Added: $f"
                done
            else
                git add "$files" && echo "✓ Added: $files"
            fi
            ;;

        commit)
            if [ -z "$message" ]; then
                echo "ERROR: git commit requires 'message' parameter"
                return 1
            fi
            # Check if there are staged changes
            if git diff --cached --quiet; then
                echo "⚠️ Nothing staged to commit. Use git add first."
                return 1
            fi
            git commit -m "$message" && echo "✓ Committed: $message"
            ;;

        log)
            echo "📜 Git Log (last 10):"
            git log --oneline -10
            ;;

        undo)
            # Undo last commit (keep changes staged)
            echo "⏪ Undoing last commit..."
            git reset --soft HEAD~1 && echo "✓ Last commit undone (changes kept staged)"
            ;;

        branch)
            echo "🌿 Current branch:"
            git branch --show-current
            echo ""
            echo "All branches:"
            git branch -a
            ;;

        stash)
            local stash_action
            stash_action=$(echo "$params" | jq -r '.stash_action // "push"')
            case "$stash_action" in
                push)
                    git stash push -m "${message:-Auto stash}" && echo "✓ Changes stashed"
                    ;;
                pop)
                    git stash pop && echo "✓ Stash applied and removed"
                    ;;
                list)
                    git stash list
                    ;;
                *)
                    echo "ERROR: Unknown stash action. Use push/pop/list"
                    return 1
                    ;;
            esac
            ;;

        *)
            echo "ERROR: Unknown git action '$action'"
            echo "Available actions: status, diff, staged, add, commit, log, undo, branch, stash"
            return 1
            ;;
    esac
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

# Tool: ask_user
# Ask user for input/confirmation
execute_ask_user() {
    local params="$1"
    local question options
    question=$(echo "$params" | jq -r '.question')
    options=$(echo "$params" | jq -r '.options // empty')

    if [ -z "$question" ] || [ "$question" = "null" ]; then
        echo "ERROR: ask_user requires 'question' parameter"
        return 1
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ 🤖 AGENT QUESTION                                           │"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│ $question"
    echo "└─────────────────────────────────────────────────────────────┘"

    # If options provided, show them
    if [ -n "$options" ] && [ "$options" != "null" ]; then
        echo ""
        echo "Options:"
        echo "$options" | jq -r 'to_entries | .[] | "  \(.key + 1). \(.value)"'
        echo ""
        read -p "Enter choice (number or text): " user_response
    else
        echo ""
        read -p "Your response: " user_response
    fi

    if [ -z "$user_response" ]; then
        echo "⚠️ No response provided (empty)"
    else
        echo "✓ User responded: $user_response"
    fi

    echo "$user_response"
}

# Tool: web_fetch
# Fetch content from a URL
execute_web_fetch() {
    local params="$1"
    local url
    url=$(echo "$params" | jq -r '.url')

    if [ -z "$url" ] || [ "$url" = "null" ]; then
        echo "ERROR: web_fetch requires 'url' parameter"
        return 1
    fi

    # Validate URL format
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "ERROR: Invalid URL format. Must start with http:// or https://"
        return 1
    fi

    echo "🌐 Fetching: $url"

    # Use curl with timeout and user agent
    local content exit_code
    content=$(curl -sL --max-time 30 \
        -H "User-Agent: Mozilla/5.0 (compatible; InfernoCLI/1.0)" \
        "$url" 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "ERROR: Failed to fetch URL (exit code: $exit_code)"
        echo "$content"
        return 1
    fi

    # Check if content is HTML and try to extract text
    if echo "$content" | head -50 | grep -qi '<html'; then
        # Try to extract readable text using various methods
        if command -v lynx &>/dev/null; then
            content=$(echo "$content" | lynx -stdin -dump -nolist 2>/dev/null | head -500)
        elif command -v w3m &>/dev/null; then
            content=$(echo "$content" | w3m -T text/html -dump 2>/dev/null | head -500)
        elif command -v pandoc &>/dev/null; then
            content=$(echo "$content" | pandoc -f html -t plain 2>/dev/null | head -500)
        else
            # Basic extraction: remove HTML tags
            content=$(echo "$content" | sed 's/<script[^>]*>.*<\/script>//gi' | \
                      sed 's/<style[^>]*>.*<\/style>//gi' | \
                      sed 's/<[^>]*>//g' | \
                      sed 's/&nbsp;/ /g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' | \
                      tr -s '[:space:]' ' ' | \
                      head -c 20000)
        fi
    fi

    # Truncate if too long
    if [ ${#content} -gt 50000 ]; then
        content="${content:0:50000}... (truncated)"
    fi

    echo "--- Content from $url ---"
    echo "$content"
    echo "--- End of content ---"
}

# Tool: web_search
# Search the web for information
execute_web_search() {
    local params="$1"
    local query
    query=$(echo "$params" | jq -r '.query')

    if [ -z "$query" ] || [ "$query" = "null" ]; then
        echo "ERROR: web_search requires 'query' parameter"
        return 1
    fi

    echo "🔍 Searching: $query"

    # URL encode the query
    local encoded_query
    encoded_query=$(echo "$query" | jq -sRr @uri)

    # Try DuckDuckGo HTML (no API key needed)
    local search_url="https://html.duckduckgo.com/html/?q=$encoded_query"

    local content
    content=$(curl -sL --max-time 30 \
        -H "User-Agent: Mozilla/5.0 (compatible; InfernoCLI/1.0)" \
        "$search_url" 2>&1)

    if [ $? -ne 0 ]; then
        echo "ERROR: Search failed"
        return 1
    fi

    # Extract search results (basic parsing)
    local results
    results=$(echo "$content" | grep -oE 'class="result__a"[^>]*>[^<]+' | \
              sed 's/class="result__a"[^>]*>//g' | \
              head -10)

    if [ -z "$results" ]; then
        # Try extracting links another way
        results=$(echo "$content" | grep -oE 'href="[^"]*" class="result__url"' | \
                  sed 's/href="//g; s/" class="result__url"//g' | \
                  head -10)
    fi

    if [ -z "$results" ]; then
        echo "No results found for: $query"
        echo "You might want to try web_fetch with a specific URL instead."
    else
        echo "Search results for '$query':"
        echo "$results"
    fi
}

# Internal todo list storage (per session)
INFERNO_TODO_LIST=""
INFERNO_TODO_COUNT=0

# Tool: todo
# Manage internal task list
execute_todo() {
    local params="$1"
    local action items
    action=$(echo "$params" | jq -r '.action')
    items=$(echo "$params" | jq -r '.items // empty')

    if [ -z "$action" ] || [ "$action" = "null" ]; then
        echo "ERROR: todo requires 'action' parameter (add/list/complete/clear)"
        return 1
    fi

    case "$action" in
        add)
            if [ -z "$items" ] || [ "$items" = "null" ]; then
                echo "ERROR: todo add requires 'items' parameter"
                return 1
            fi

            # Handle array or string
            if echo "$items" | jq -e 'type == "array"' >/dev/null 2>&1; then
                # Array of items
                while IFS= read -r item; do
                    ((INFERNO_TODO_COUNT++))
                    INFERNO_TODO_LIST="${INFERNO_TODO_LIST}${INFERNO_TODO_COUNT}. [ ] ${item}\n"
                done < <(echo "$items" | jq -r '.[]')
            else
                # Single item
                ((INFERNO_TODO_COUNT++))
                INFERNO_TODO_LIST="${INFERNO_TODO_LIST}${INFERNO_TODO_COUNT}. [ ] ${items}\n"
            fi
            echo "✓ Added to todo list"
            printf "%b" "$INFERNO_TODO_LIST"
            ;;

        list)
            if [ -z "$INFERNO_TODO_LIST" ]; then
                echo "📋 Todo list is empty"
            else
                echo "📋 Todo list:"
                printf "%b" "$INFERNO_TODO_LIST"
            fi
            ;;

        complete)
            if [ -z "$items" ] || [ "$items" = "null" ]; then
                echo "ERROR: todo complete requires 'items' (task number or text)"
                return 1
            fi

            # Mark as complete (replace [ ] with [x])
            if [[ "$items" =~ ^[0-9]+$ ]]; then
                # By number
                INFERNO_TODO_LIST=$(printf "%b" "$INFERNO_TODO_LIST" | \
                    sed "s/^${items}\. \[ \]/\n${items}. [x]/")
            else
                # By text match
                INFERNO_TODO_LIST=$(printf "%b" "$INFERNO_TODO_LIST" | \
                    sed "s/\[ \] .*${items}.*/[x] &/")
            fi
            echo "✓ Marked complete"
            printf "%b" "$INFERNO_TODO_LIST"
            ;;

        clear)
            INFERNO_TODO_LIST=""
            INFERNO_TODO_COUNT=0
            echo "✓ Todo list cleared"
            ;;

        *)
            echo "ERROR: Unknown todo action '$action'. Use: add, list, complete, clear"
            return 1
            ;;
    esac
}

# Tool: spawn_agent
# Spawn a sub-agent for parallel work
execute_spawn_agent() {
    local params="$1"
    local task model
    task=$(echo "$params" | jq -r '.task')
    model=$(echo "$params" | jq -r '.model // empty')

    if [ -z "$task" ] || [ "$task" = "null" ]; then
        echo "ERROR: spawn_agent requires 'task' parameter"
        return 1
    fi

    echo "🚀 Spawning sub-agent..."
    echo "   Task: $task"
    [ -n "$model" ] && echo "   Model: $model"

    # Get the directory where inferno-cli is located
    local inferno_dir
    inferno_dir=$(dirname "${BASH_SOURCE[0]}")/..
    inferno_dir=$(cd "$inferno_dir" && pwd)

    # Build command
    local cmd="$inferno_dir/inferno-cli.sh"
    [ -n "$model" ] && cmd="$cmd --model $model"
    cmd="$cmd \"$task\""

    # Run in background and capture PID
    local output_file
    output_file=$(mktemp)

    echo "   Output: $output_file"

    # Start the sub-agent in background
    (
        eval "$cmd" > "$output_file" 2>&1
        echo "--- Sub-agent completed ---" >> "$output_file"
    ) &

    local pid=$!
    echo "   PID: $pid"

    # Store for later retrieval
    echo "✓ Sub-agent spawned (PID: $pid)"
    echo "   Check results with: cat $output_file"
    echo "   Or wait with: wait $pid && cat $output_file"

    # Return the output file path and PID as JSON
    jq -n --arg pid "$pid" --arg output "$output_file" \
        '{pid: $pid, output_file: $output}'
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
