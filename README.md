# Inferno CLI

Standalone LLM-powered coding agent. Takes a prompt and generates code.

## Usage

```bash
# Direct prompt
./inferno-cli.sh "Create hello.txt with 'Hello World'"

# From stdin
echo "Add a sum function to math.ts" | ./inferno-cli.sh

# From file
./inferno-cli.sh --prompt-file prompt.txt

# Verbose mode
VERBOSE=true ./inferno-cli.sh "Create a React component"
```

## How it works

1. Takes prompt via argument, stdin, or file
2. Calls LLM API with native tool support
3. Parses JSON response
4. Applies files and runs commands
5. Returns exit code based on success

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
| `MAX_READ_FILES` | `20` | Max file read iterations |
| `VERBOSE` | `false` | Show detailed output |
| `ANTHROPIC_API_KEY` | - | Required for Anthropic |
| `OPENAI_API_KEY` | - | Required for OpenAI |
| `GOOGLE_API_KEY` | - | Required for Google |
| `MISTRAL_API_KEY` | - | Required for Mistral |
| `GROQ_API_KEY` | - | Required for Groq |
| `OPENROUTER_API_KEY` | - | Required for OpenRouter |

## Exit Codes

- `0` - Success (LLM marked done=true and commands succeeded)
- `1` - Error (LLM error, JSON parse error, or commands failed)
- `2` - Not done (LLM did not mark done=true)

## JSON Response Format

The LLM responds with:

```json
{
  "files": [{"path": "file.ts", "content": "..."}],
  "commands": ["npm install", "npm run build"],
  "read_files": ["existing.ts"],
  "done": true,
  "message": "Created component"
}
```

## License

MIT
