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
# Scope configuration (via .synapserc or environment):
#   SYNAPSE_SCOPE_PATHS      - Allowed paths (comma-separated, default: ./)
#   SYNAPSE_DENY_PATHS       - Denied paths (comma-separated)
#   SYNAPSE_ALLOW_COMMANDS   - Allowed command patterns
#   SYNAPSE_DENY_COMMANDS    - Denied command patterns
# =============================================================================

# Load scope from environment or defaults
SYNAPSE_SCOPE_PATHS="${SYNAPSE_SCOPE_PATHS:-./}"
SYNAPSE_DENY_PATHS="${SYNAPSE_DENY_PATHS:-}"

# Deny-by-default command gate.
# SYNAPSE_ALLOW_COMMANDS is an allowlist matched against the parsed first token
# (the binary name). An empty value means "use the conservative built-in default
# allowlist below" — it NEVER means "allow everything". To intentionally widen
# the gate the operator must set SYNAPSE_ALLOW_COMMANDS explicitly (e.g. to "*").
SYNAPSE_ALLOW_COMMANDS="${SYNAPSE_ALLOW_COMMANDS:-}"

# Conservative built-in allowlist (binary names) used when no allowlist is set.
SYNAPSE_DEFAULT_ALLOW_COMMANDS="${SYNAPSE_DEFAULT_ALLOW_COMMANDS:-ls,cat,head,tail,wc,grep,rg,find,echo,pwd,which,file,stat,git,npm,npx,node,yarn,pnpm,python,python3,pip,pip3,tsc,jest,vitest,go,cargo,make,bash,sh,sed,awk,sort,uniq,cut,diff,test,true,false,mkdir,touch}"

# Always-denied command binaries / patterns (cannot be re-enabled via allowlist).
SYNAPSE_DENY_COMMANDS="${SYNAPSE_DENY_COMMANDS:-rm,sudo,su,shutdown,reboot,mkfs,dd,chown,chmod,curl|sh,wget|sh,:(){ :|:& };:}"
SYNAPSE_TOOL_TIMEOUT="${SYNAPSE_TOOL_TIMEOUT:-60}"

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

# Resolve a path to an absolute, normalized form (resolving ../, ., and symlinks
# where possible). `realpath -m` is GNU-only, so fall back portably: resolve the
# existing parent directory and re-attach the basename when the leaf does not
# yet exist.
resolve_path() {
    local p="$1"
    # Try GNU realpath -m (resolves even non-existent leaves).
    local resolved
    resolved=$(realpath -m "$p" 2>/dev/null) && { echo "$resolved"; return; }
    # Try plain realpath (must exist).
    resolved=$(realpath "$p" 2>/dev/null) && { echo "$resolved"; return; }
    # Portable fallback: resolve the parent dir, re-attach the basename.
    local dir base
    dir=$(dirname "$p")
    base=$(basename "$p")
    local dir_abs
    dir_abs=$(cd "$dir" 2>/dev/null && pwd) || dir_abs="$dir"
    if [ "$base" = "." ] || [ -z "$base" ]; then
        echo "$dir_abs"
    else
        echo "$dir_abs/$base"
    fi
}

# Check if a path is within allowed scope
# Usage: if is_path_allowed "/some/path"; then ...
is_path_allowed() {
    local check_path="$1"
    local current_dir
    current_dir=$(pwd)

    # Normalize path (resolve ../, symlinks, and relative prefixes)
    local normalized_path
    if [[ "$check_path" == /* ]]; then
        normalized_path=$(resolve_path "$check_path")
    elif [[ "$check_path" == "." ]]; then
        normalized_path="$current_dir"
    elif [[ "$check_path" == "./"* ]]; then
        normalized_path=$(resolve_path "$current_dir/${check_path#./}")
    else
        normalized_path=$(resolve_path "$current_dir/$check_path")
    fi
    normalized_path=${normalized_path:-$check_path}

    # ALWAYS-ON secret-file denial (independent of SYNAPSE_DENY_PATHS).
    # Reading/writing .env, *.key, *.pem and credentials.* is blocked by DEFAULT.
    case "$normalized_path" in
        *.env|*.env.*|*/.env|*/.env.*|*.key|*.pem|*credentials*)
            return 1
            ;;
    esac
    case "$check_path" in
        *.env|*.env.*|*/.env|*/.env.*|*.key|*.pem|*credentials*)
            return 1
            ;;
    esac

    # Check configured denied paths
    if [ -n "$SYNAPSE_DENY_PATHS" ]; then
        local OLD_IFS="$IFS"
        IFS=','
        for denied in $SYNAPSE_DENY_PATHS; do
            IFS="$OLD_IFS"
            denied=$(echo "$denied" | xargs)  # trim whitespace
            [ -z "$denied" ] && continue
            # Handle glob patterns
            if [[ "$normalized_path" == $denied ]] || \
               [[ "$check_path" == *"$denied"* ]]; then
                return 1
            fi
        done
        IFS="$OLD_IFS"
    fi

    # Check allowed paths
    local OLD_IFS="$IFS"
    IFS=','
    for allowed in $SYNAPSE_SCOPE_PATHS; do
        IFS="$OLD_IFS"
        allowed=$(echo "$allowed" | xargs)  # trim whitespace

        # Resolve allowed path relative to current directory
        local allowed_full
        if [[ "$allowed" == /* ]]; then
            allowed_full="$allowed"
        else
            allowed_full="$current_dir/$allowed"
        fi
        allowed_full=$(resolve_path "$allowed_full")

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

# Extract the first token (the binary name) from a command string.
# Strips a leading "VAR=value " environment prefix and any directory path,
# so "/usr/bin/rm" and "env FOO=1 rm" both resolve to "rm".
command_first_token() {
    local cmd="$1"
    # Trim leading whitespace
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    # Read the first whitespace-delimited word
    local first
    read -r first _ <<< "$cmd"
    # Skip leading env-assignment prefixes (FOO=bar) and `env`
    while [[ "$first" == *=* && "$first" != *[[:space:]]* ]] || [ "$first" = "env" ]; do
        cmd="${cmd#"$first"}"
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        read -r first _ <<< "$cmd"
        [ -z "$first" ] && break
    done
    # Strip directory component (basename of the binary)
    echo "${first##*/}"
}

# Check if a command is allowed.
# Deny-by-default: rejects shell metacharacters and chained commands, blocks an
# always-denied binary set, then requires the first token to be in the allowlist
# (the conservative built-in default when SYNAPSE_ALLOW_COMMANDS is empty).
# Usage: if is_command_allowed "npm install"; then ...
is_command_allowed() {
    local cmd="$1"
    local first_token
    first_token=$(command_first_token "$cmd")

    # Effective allowlist: explicit config, or the conservative built-in default.
    local allowlist="$SYNAPSE_ALLOW_COMMANDS"
    if [ -z "$allowlist" ]; then
        allowlist="$SYNAPSE_DEFAULT_ALLOW_COMMANDS"
    fi

    # 1) Reject shell metacharacters / chaining unless the operator opted into
    #    a fully-open gate ("*"). This stops "cd / && rm -rf ." style bypasses
    #    where the first token is harmless but a denied command is chained on.
    if [ "$allowlist" != "*" ]; then
        case "$cmd" in
            *';'*|*'|'*|*'&'*|*'$('*|*'`'*|*'>'*|*'<'*|*$'\n'*)
                return 1
                ;;
        esac
    fi

    # 2) Always-denied binaries / patterns (cannot be re-enabled by allowlist).
    if [ -n "$SYNAPSE_DENY_COMMANDS" ]; then
        # Hard-coded dangerous forms that must never pass, regardless of config.
        case "$cmd" in
            "rm "*|"rm")
                return 1
                ;;
            "sudo "*|"su "*|"sudo"|"su")
                return 1
                ;;
            *":(){ :|:& };:"*)
                return 1
                ;;
        esac

        local OLD_IFS="$IFS"
        IFS=','
        for denied in $SYNAPSE_DENY_COMMANDS; do
            IFS="$OLD_IFS"
            denied=$(echo "$denied" | xargs)  # trim whitespace
            [ -z "$denied" ] && continue
            # Match denied binary names against the parsed first token,
            # and also reject if the raw denied pattern appears literally
            # (covers patterns like "curl|sh").
            if [ "$first_token" = "$denied" ] || [[ "$cmd" == *"$denied"* ]]; then
                return 1
            fi
        done
        IFS="$OLD_IFS"
    fi

    # 3) Fully-open gate: operator explicitly set "*". Denylist above still applies.
    if [ "$allowlist" = "*" ]; then
        return 0
    fi

    # 4) Allowlist check against the parsed first token (binary name).
    local OLD_IFS="$IFS"
    IFS=','
    for allowed in $allowlist; do
        IFS="$OLD_IFS"
        allowed=$(echo "$allowed" | xargs)
        [ -z "$allowed" ] && continue
        # Allowlist entries may be a bare binary name or a glob like "npm *".
        # Match on the parsed first token, or on a glob applied to the full cmd.
        local allowed_bin="${allowed%% *}"
        if [ "$first_token" = "$allowed_bin" ]; then
            return 0
        fi
        if [[ "$cmd" == $allowed ]]; then
            return 0
        fi
    done
    IFS="$OLD_IFS"

    return 1  # Not in allow list → deny by default
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

    # Check if old_string exists and is unique.
    # SECURITY: path/old_string/new_string are passed as DATA (argv), never
    # interpolated into the program text, so quotes, ''' , slashes and regex
    # metacharacters can never break out into executable code.
    local count
    if command -v python3 &>/dev/null; then
        count=$(python3 - "$path" "$old_string" <<'PY'
import sys
path, old = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()
print(content.count(old))
PY
)
    else
        # Fallback: grep -F counts matching lines (approximate for multiline).
        count=$(grep -F -c -- "$old_string" "$path" 2>/dev/null || echo "0")
    fi

    if [ "$count" -eq 0 ]; then
        echo "ERROR: String not found in file. Make sure old_string matches exactly."
        echo "--- First 50 lines of $path ---"
        head -50 "$path"
        return 1
    fi

    if [ "$count" -gt 1 ]; then
        echo "ERROR: String found $count times in file. old_string must be unique."
        echo "Add more context to make it unique."
        return 1
    fi

    # Perform the replacement.
    # SECURITY: path/old/new are passed as argv DATA, never spliced into code.
    # The replace is a literal string replace (not a regex), so regex
    # metacharacters and quote sequences in the strings are inert.
    local edit_ok=0
    if command -v python3 &>/dev/null; then
        if python3 - "$path" "$old_string" "$new_string" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r') as f:
    content = f.read()
content = content.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(content)
PY
        then
            edit_ok=1
        fi
    else
        # Fallback: perl with strings passed via environment variables and a
        # literal (\Q...\E quoted) match — no interpolation into the program.
        if OLD="$old_string" NEW="$new_string" \
            perl -0777 -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$path" 2>/dev/null
        then
            edit_ok=1
        fi
    fi

    if [ "$edit_ok" -ne 1 ]; then
        echo "ERROR: Failed to apply edit to $path"
        return 1
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
        output=$(timeout "$SYNAPSE_TOOL_TIMEOUT" bash -c "$cmd" 2>&1)
        exit_code=$?
    elif command -v gtimeout &>/dev/null; then
        output=$(gtimeout "$SYNAPSE_TOOL_TIMEOUT" bash -c "$cmd" 2>&1)
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

    # Handle patterns like "src/**/*.ts" - extract base path from pattern
    local search_path="$path"
    local file_pattern="$pattern"

    # If pattern contains a path prefix (e.g., src/**/*.ts), extract it
    if [[ "$pattern" == *"/"* ]] && [[ "$pattern" != "**/"* ]]; then
        # Extract the directory part before any wildcards
        local prefix="${pattern%%\**}"
        prefix="${prefix%%\?*}"
        if [[ "$prefix" == *"/" ]]; then
            prefix="${prefix%/}"
            if [ -d "$prefix" ]; then
                search_path="$prefix"
                file_pattern="${pattern#$prefix/}"
            fi
        fi
    fi

    if [ ! -d "$search_path" ]; then
        echo "ERROR: Directory not found: $search_path"
        return 1
    fi

    # Use find with pattern matching
    local results
    local name_pattern

    if [[ "$file_pattern" == "**/"* ]]; then
        # Pattern like **/*.ts - recursive search
        name_pattern="${file_pattern#**/}"
        results=$(find "$search_path" -type f -name "$name_pattern" 2>/dev/null | sort | head -200)
    elif [[ "$file_pattern" == *"**"* ]]; then
        # Pattern with ** somewhere - use find recursively
        name_pattern="${file_pattern//\*\*\//}"
        name_pattern="${name_pattern//\*\*/}"
        results=$(find "$search_path" -type f -name "$name_pattern" 2>/dev/null | sort | head -200)
    else
        # Simple pattern - use find with maxdepth
        results=$(find "$search_path" -maxdepth 5 -type f -name "$file_pattern" 2>/dev/null | sort | head -200)
    fi

    if [ -z "$results" ]; then
        echo "No files found matching '$pattern' in $search_path"
    else
        local count
        count=$(echo "$results" | wc -l)
        echo "Found $count files matching '$pattern':"
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

# SSRF guard: return 0 (true) if a host targets a private/loopback/link-local
# address that must never be fetched (cloud metadata, internal services, etc).
is_private_host() {
    local host="$1"
    # Strip brackets from IPv6 literals.
    host="${host#[}"
    host="${host%]}"
    # Lowercase for hostname comparisons.
    host=$(echo "$host" | tr '[:upper:]' '[:lower:]')

    case "$host" in
        localhost|localhost.*|*.localhost) return 0 ;;
        # IPv4 loopback 127.0.0.0/8
        127.*) return 0 ;;
        # RFC1918 private ranges
        10.*) return 0 ;;
        192.168.*) return 0 ;;
        # Cloud metadata / link-local 169.254.0.0/16 (incl. 169.254.169.254)
        169.254.*) return 0 ;;
        # IPv6 loopback / unspecified
        ::1|::) return 0 ;;
        # IPv6 unique-local (fc00::/7) and link-local (fe80::/10)
        fc*:*|fd*:*|fe8*:*|fe9*:*|fea*:*|feb*:*) return 0 ;;
        0.0.0.0) return 0 ;;
    esac

    # 172.16.0.0 – 172.31.0.0 (172.16/12)
    if [[ "$host" =~ ^172\.([0-9]+)\. ]]; then
        local octet="${BASH_REMATCH[1]}"
        if [ "$octet" -ge 16 ] && [ "$octet" -le 31 ]; then
            return 0
        fi
    fi

    return 1
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

    # SSRF protection: extract the host and block private/loopback/link-local
    # targets BEFORE making any request.
    local host
    host="${url#*://}"          # strip scheme
    host="${host%%/*}"          # strip path
    host="${host##*@}"          # strip userinfo
    host="${host%%\?*}"         # strip query
    # Strip port (but keep IPv6 brackets intact).
    if [[ "$host" == \[*\]* ]]; then
        host="${host%%]*}]"     # keep up to closing bracket
    else
        host="${host%%:*}"
    fi

    if is_private_host "$host"; then
        echo "ERROR: Refusing to fetch private/loopback/link-local address: $host"
        return 1
    fi

    echo "🌐 Fetching: $url"

    # Use curl with timeout, user agent and a capped redirect count.
    # --max-redirs 3 bounds redirects (avoids redirect-based SSRF bypass)
    # instead of following an unbounded redirect chain with bare -L.
    local content exit_code
    content=$(curl -s -L --max-redirs 3 --max-time 30 \
        -H "User-Agent: Mozilla/5.0 (compatible; Synapse/1.0)" \
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
        -H "User-Agent: Mozilla/5.0 (compatible; Synapse/1.0)" \
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
SYNAPSE_TODO_LIST=""
SYNAPSE_TODO_COUNT=0

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
                    ((SYNAPSE_TODO_COUNT++))
                    SYNAPSE_TODO_LIST="${SYNAPSE_TODO_LIST}${SYNAPSE_TODO_COUNT}. [ ] ${item}\n"
                done < <(echo "$items" | jq -r '.[]')
            else
                # Single item
                ((SYNAPSE_TODO_COUNT++))
                SYNAPSE_TODO_LIST="${SYNAPSE_TODO_LIST}${SYNAPSE_TODO_COUNT}. [ ] ${items}\n"
            fi
            echo "✓ Added to todo list"
            printf "%b" "$SYNAPSE_TODO_LIST"
            ;;

        list)
            if [ -z "$SYNAPSE_TODO_LIST" ]; then
                echo "📋 Todo list is empty"
            else
                echo "📋 Todo list:"
                printf "%b" "$SYNAPSE_TODO_LIST"
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
                SYNAPSE_TODO_LIST=$(printf "%b" "$SYNAPSE_TODO_LIST" | \
                    sed "s/^${items}\. \[ \]/\n${items}. [x]/")
            else
                # By text match
                SYNAPSE_TODO_LIST=$(printf "%b" "$SYNAPSE_TODO_LIST" | \
                    sed "s/\[ \] .*${items}.*/[x] &/")
            fi
            echo "✓ Marked complete"
            printf "%b" "$SYNAPSE_TODO_LIST"
            ;;

        clear)
            SYNAPSE_TODO_LIST=""
            SYNAPSE_TODO_COUNT=0
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

    # Get the directory where synapse is located
    local synapse_dir
    synapse_dir=$(dirname "${BASH_SOURCE[0]}")/..
    synapse_dir=$(cd "$synapse_dir" && pwd)

    # Run in background and capture PID
    local output_file
    output_file=$(mktemp)

    echo "   Output: $output_file"

    # Build the argv as an array so each element is a distinct argument.
    # SECURITY: invoke synapse.sh as a direct argv array — no string building,
    # no eval. The task and model are arguments, never shell-parsed, so a task
    # containing quotes/semicolons/$(...) cannot inject commands.
    local cmd_args=("$synapse_dir/synapse.sh")
    if [ -n "$model" ]; then
        cmd_args+=(--model "$model")
    fi
    cmd_args+=("$task")

    # Start the sub-agent in background.
    (
        "${cmd_args[@]}" > "$output_file" 2>&1
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

# Load scope configuration from .synapserc file
load_scope_config() {
    local config_file="${1:-.synapserc}"

    if [ ! -f "$config_file" ]; then
        return 0  # Use defaults
    fi

    # Load scope paths
    local scope_paths
    scope_paths=$(jq -r '.scope.paths // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$scope_paths" ] && [ "$scope_paths" != "" ]; then
        SYNAPSE_SCOPE_PATHS="$scope_paths"
    fi

    # Load denied paths
    local deny_paths
    deny_paths=$(jq -r '.scope.deny_paths // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$deny_paths" ] && [ "$deny_paths" != "" ]; then
        SYNAPSE_DENY_PATHS="$deny_paths"
    fi

    # Load allowed commands
    local allow_cmds
    allow_cmds=$(jq -r '.scope.allow_commands // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$allow_cmds" ] && [ "$allow_cmds" != "" ]; then
        SYNAPSE_ALLOW_COMMANDS="$allow_cmds"
    fi

    # Load denied commands
    local deny_cmds
    deny_cmds=$(jq -r '.scope.deny_commands // [] | join(",")' "$config_file" 2>/dev/null)
    if [ -n "$deny_cmds" ] && [ "$deny_cmds" != "" ]; then
        SYNAPSE_DENY_COMMANDS="$deny_cmds"
    fi
}
