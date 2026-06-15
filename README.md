# Synapse

**Universal Agent Proxy** - Turn ANY LLM into a coding agent.

```
┌─────────────────────────────────────────────────────┐
│                    Synapse                       │
│            Universal Agent Proxy                     │
├─────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐ │
│  │ Claude  │  │DeepSeek │  │ Gemini  │  │ Ollama │ │
│  │(native) │  │(proxied)│  │(proxied)│  │(local) │ │
│  └─────────┘  └─────────┘  └─────────┘  └────────┘ │
├─────────────────────────────────────────────────────┤
│              19 Built-in Tools                       │
│   read │ write │ edit │ bash │ git │ search │ ...  │
├─────────────────────────────────────────────────────┤
│              Task Router                             │
│    architect→opus │ codegen→deepseek │ fix→gemini  │
└─────────────────────────────────────────────────────┘
```

## Why Synapse?

- **Bash-first** - The agent loop is plain bash. Core dependencies are `bash`, `curl` and `jq`. A few tools need extra binaries: `edit_file` uses `python3` (with a `perl` fallback), and task routing uses `bc` for confidence scoring. See [Dependencies](#dependencies).
- **Any model** - Works with models that don't have native tool-use (DeepSeek, Llama, Mistral)
- **19 tools** - file ops, git, search, web, sub-agents
- **Task routing** - Auto-select a model per task type from your config
- **Scope control** - Restrict what paths and commands agents can access
- **Loopable** - Designed for agentic loops, returns proper exit codes

## Quick Start

```bash
# Clone
git clone https://github.com/sandstream/synapse.git
cd synapse

# Set API key
export ANTHROPIC_API_KEY="sk-..."

# Run
./synapse.sh "Create a TypeScript function that calculates fibonacci"
```

## Dependencies

| Dependency | Required for | Notes |
|------------|--------------|-------|
| `bash` | core agent loop | bash 4+ |
| `curl` | LLM API calls, `web_fetch`, `web_search` | |
| `jq` | JSON parsing throughout | |
| `python3` | `edit_file` string replacement | falls back to `perl` if missing |
| `perl` | `edit_file` fallback | only used when `python3` is unavailable |
| `bc` | task router confidence scoring | |
| `git` | `git` tool | optional, only if you use git operations |

Synapse does **not** require Node, Go, or a package manager. It is bash-first, but
it is not a pure bash + curl + jq tool — `edit_file` needs `python3`/`perl` and the
router needs `bc`.

## Usage

```bash
# Direct prompt
./synapse.sh "Fix the TypeScript error in src/app.ts"

# Pipe from stdin
echo "Add unit tests for the User class" | ./synapse.sh

# From file
./synapse.sh --prompt-file task.txt

# Dry run (show routing without executing)
./synapse.sh --dry-run "Plan the authentication module"

# Use specific model
./synapse.sh --model deepseek/deepseek-chat "Optimize this function"

# Verbose mode
VERBOSE=true ./synapse.sh "Debug the login flow"
```

## Dual-Mode: Native + JSON Proxy

Synapse works with ANY LLM through two modes:

### Native Mode (Anthropic, OpenAI, Google, Mistral, Groq)
For providers with native tool-use API:
```
Prompt → API with tools → tool_use response → execute → loop
```

### JSON Proxy Mode (DeepSeek, Ollama, etc)
For providers WITHOUT native tool-use:
```
Prompt + JSON instructions → parse response → execute → inject result → loop
```

```bash
# Native mode (automatic)
./synapse.sh "Create hello.ts"

# JSON proxy mode (automatic for non-native models)
LLM_PROVIDER=openrouter LLM_MODEL=deepseek/deepseek-chat \
./synapse.sh "Create hello.ts"

# Force proxy mode
SYNAPSE_MODE=proxy ./synapse.sh "Create hello.ts"
```

## 19 Built-in Tools

| Tool | Description |
|------|-------------|
| **File Operations** | |
| `read_file` | Read file contents |
| `write_file` | Create/overwrite file |
| `edit_file` | Edit with string replacement |
| `multi_edit` | Batch edits in one file |
| `delete_file` | Remove file |
| `move_file` | Move/rename file |
| `mkdir` | Create directory |
| **Search** | |
| `search` | Grep in files |
| `glob` | Find files by pattern |
| `list_files` | List directory |
| **Execution** | |
| `bash` | Run shell command |
| **Git** | |
| `git` | status/diff/add/commit/log/undo/branch/stash |
| **Planning** | |
| `think` | Reason without action |
| `todo` | Internal task list |
| **User Interaction** | |
| `ask_user` | Prompt user for input |
| `done` | Mark task complete |
| **Web** | |
| `web_fetch` | Fetch URL content |
| `web_search` | Search the web |
| **Parallel** | |
| `spawn_agent` | Run sub-agent |

## Task Router

Automatically routes tasks to optimal models:

```bash
# Auto-detected task types:
# - architect → planning, design, system architecture
# - codegen   → creating new code
# - fix       → bugs, errors, debugging
# - review    → code review, audits
# - test      → writing tests
```

Configure in `.synapserc`:
```json
{
  "taskModels": {
    "architect": "claude-opus-4-20250514",
    "codegen": "deepseek/deepseek-chat",
    "fix": "claude-sonnet-4-20250514",
    "review": "claude-sonnet-4-20250514",
    "test": "deepseek/deepseek-coder"
  }
}
```

## Scope & Permissions

Control what the agent can access:

```json
{
  "scope": {
    "paths": ["src/", "tests/", "package.json"],
    "deny_paths": ["node_modules/", ".env", "*.key"],
    "allow_commands": ["npm *", "node *", "tsc *"],
    "deny_commands": ["rm -rf /", "sudo *"]
  }
}
```

The command gate is **deny-by-default**: if no `allow_commands` is configured, only a
conservative built-in allowlist (`ls`, `cat`, `grep`, `git`, `npm`, `node`, …) runs.
Destructive commands (`rm`, `sudo`), chained commands (`&&`, `;`, `|`), and
`curl … | sh` are always blocked and cannot be re-enabled via the allowlist.

```bash
# A command that resolves to `rm -rf ...` is rejected by the gate, e.g.:
# → SCOPE_DENIED: Command 'rm -rf .' is not allowed
```

Secret files (`.env`, `*.key`, `*.pem`, `credentials.*`) are denied for read/write by
default, independent of any configured `deny_paths`.

## Supported Providers

| Provider | Native Tools | Models | API Key |
|----------|--------------|--------|---------|
| **Anthropic** | Yes | Claude 4, Claude 3.5 | `ANTHROPIC_API_KEY` |
| **OpenAI** | Yes | GPT-4o, o1, o3 | `OPENAI_API_KEY` |
| **Google** | Yes | Gemini 2.0, Gemini 1.5 | `GOOGLE_API_KEY` |
| **Mistral** | Yes | Mistral Large, Codestral | `MISTRAL_API_KEY` |
| **Groq** | Yes | Llama 3.3, Mixtral (fast) | `GROQ_API_KEY` |
| **OpenRouter** | Via proxy | 100+ models | `OPENROUTER_API_KEY` |
| **Ollama** | Via proxy | Local models | - |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_PROVIDER` | `anthropic` | Provider: anthropic, openai, google, mistral, groq, openrouter, ollama |
| `LLM_MODEL` | `claude-sonnet-4-20250514` | Model name |
| `LLM_MAX_TOKENS` | `8000` | Max output tokens |
| `LLM_TIMEOUT` | `300` | Request timeout (seconds) |
| `SYNAPSE_MODE` | `auto` | auto, native, proxy |
| `SYNAPSE_AUTO_ROUTE` | `true` | Enable task routing |
| `VERBOSE` | `false` | Show detailed output |
| `ANTHROPIC_API_KEY` | - | Required for Anthropic |
| `OPENAI_API_KEY` | - | Required for OpenAI |
| `GOOGLE_API_KEY` | - | Required for Google |
| `MISTRAL_API_KEY` | - | Required for Mistral |
| `GROQ_API_KEY` | - | Required for Groq |
| `OPENROUTER_API_KEY` | - | Required for OpenRouter |

## Providers

```bash
# Anthropic (default)
export ANTHROPIC_API_KEY="sk-ant-..."
./synapse.sh "Create component"

# OpenRouter (100+ models)
export OPENROUTER_API_KEY="sk-or-..."
LLM_PROVIDER=openrouter LLM_MODEL=deepseek/deepseek-chat \
./synapse.sh "Create component"

# OpenAI
export OPENAI_API_KEY="sk-..."
LLM_PROVIDER=openai LLM_MODEL=gpt-4o \
./synapse.sh "Create component"

# Google
export GOOGLE_API_KEY="..."
LLM_PROVIDER=google LLM_MODEL=gemini-2.0-flash \
./synapse.sh "Create component"

# Mistral
export MISTRAL_API_KEY="..."
LLM_PROVIDER=mistral LLM_MODEL=mistral-large-latest \
./synapse.sh "Create component"

# Groq (fast inference)
export GROQ_API_KEY="..."
LLM_PROVIDER=groq LLM_MODEL=llama-3.3-70b-versatile \
./synapse.sh "Create component"

# Ollama (local)
LLM_PROVIDER=ollama LLM_MODEL=llama3.1 \
./synapse.sh "Create component"
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success - task completed |
| `1` | Error - tool failed or LLM error |
| `2` | Incomplete - max iterations reached |
| `100` | Done signal from agent |

## How Synapse differs

Synapse is a small bash-first tool. Compared to larger agent CLIs it trades polish
for portability and hackability:

- **Language** - Bash agent loop (vs Node/Python/Go projects).
- **Dependencies** - `bash` + `curl` + `jq` for the core loop; `python3`/`perl` for
  `edit_file` and `bc` for routing. No package manager or runtime to install.
- **Any model** - JSON proxy mode runs models without native tool-use (DeepSeek,
  Llama, Mistral, local Ollama), not just one vendor.
- **Task routing** - Map task types to models in `.synapserc`.
- **Scope control** - Deny-by-default command gate plus path scoping.

Feature counts and capabilities of other tools change frequently — check their
own docs for an up-to-date comparison.

## License

MIT

## Contributing

PRs welcome! Keep it simple, keep it bash.
