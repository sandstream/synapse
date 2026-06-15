# Synapse - Decisions & Insights

## 2025-01-23: LiteLLM Integration - No

**Decision:** Keep `lib/llm.sh`, do not integrate LiteLLM.

**Context:**
LiteLLM is a Universal API Gateway that provides:
- Passthrough to 100+ LLM providers
- Passthrough to MCP servers
- Passthrough to A2A agents
- Cost tracking, rate limiting, load balancing, fallback/retry, auth

**Analysis:**

| Feature | Need for Synapse? | Why |
|---------|-------------------|-----|
| Cost tracking | No | CLI tool, not SaaS. User sees cost in provider dashboard |
| Rate limiting | No | Single user, single agent. No abuse risk |
| Load balancing | No | One request at a time. Task router handles model selection |
| Fallback/retry | Maybe | Nice if API fails, but curl retry is simple |
| Auth/API keys | No | User sets `ANTHROPIC_API_KEY` etc directly |

**LiteLLM is built for:**
- Multi-tenant SaaS
- Teams with budget control
- High volume, many users

**Synapse is:**
- Single-user CLI
- Local agent
- One task at a time

**The only value** LiteLLM would provide:
1. Skip maintaining provider code in `lib/llm.sh`
2. Get new providers "for free"

**But it costs:**
- Python dependency, OR
- Proxy server that must be running

**Conclusion:** Not worth the complexity. Keep bash-native `lib/llm.sh` with our 7 providers.

---

## 2025-01-23: A2A Protocol - Backlog

**Decision:** Add to backlog, not implementing now.

**Context:**
Google's Agent-to-Agent (A2A) protocol enables agents to communicate with each other.

**Current state:**
Our `spawn_agent` tool spawns local Synapse processes only.

**With A2A:**
Could spawn remote agents (Vertex AI, Azure AI, LangGraph, etc.)

**Why not now:**
- Overkill for local CLI usage
- Adds complexity (JSON-RPC, Agent Cards)
- Python SDK or custom bash implementation needed

**When to revisit:**
When users need to delegate to specialized external agents.

---
