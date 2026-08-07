# Engineering Guidelines (example)

This file is fetched per PR (if present) and appended to the review prompts as
team context. Keep it short — it is truncated to 8KB.

## General

- Prefer small, focused PRs.
- No secrets in code or logs.

## Backend

- Wrap database mutations in transactions.
- Validate all user input; never trust the client.

## Frontend

- Never render user input via innerHTML; use framework-safe rendering.
- Always clean up intervals and event listeners.
