# Synapse - Backlog

## Future Enhancements

### A2A Protocol Support
**Priority:** Medium
**Complexity:** High

Add support for Google's Agent-to-Agent (A2A) protocol to enable:
- Spawning remote agents (Vertex AI, Azure AI, LangGraph, etc.)
- Exposing Synapse as an A2A-compatible agent
- Agent discovery via Agent Cards
- Task status streaming/push notifications

**Current state:** `spawn_agent` only spawns local Synapse processes.

**With A2A:**
```json
{"tool": "spawn_agent", "params": {
  "task": "Research auth patterns",
  "agent": "vertex://research-agent"
}}
```

**Resources:**
- [A2A Spec](https://a2a-protocol.org/latest/)
- [A2A GitHub](https://github.com/a2aproject/A2A)
- [Google Announcement](https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/)

---

### LiteLLM Integration
**Priority:** Low
**Complexity:** Medium

Replace `lib/llm.sh` with LiteLLM proxy for:
- 100+ providers out-of-box
- Built-in tool-use translation
- Cost tracking, rate limiting
- Fallback/retry logic

**Options:**
1. LiteLLM as proxy server (keep bash)
2. Rewrite Synapse in Python with LiteLLM SDK

---
