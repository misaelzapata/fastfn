# Chapter 8 - Session, Context, and Basic Memory

Goal: pass user context and keep minimal conversational memory.

## Context via `/_fn/invoke`

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST -H 'content-type: application/json' \
  --data '{
    "name":"request_inspector",
    "method":"GET",
    "context":{"trace_id":"abc-123","tenant":"demo"}
  }' | jq .
```

The function receives this in `event.context.user`.

## Basic memory pattern

- Use a stable key (`chat_id`, `user_id`, session id)
- Store last N turns
- Apply TTL (for example 24h)

This pattern is already used by `telegram_ai_reply`.
