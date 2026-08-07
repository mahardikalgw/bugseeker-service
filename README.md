# Codeseeker — AI Code Review Bot

> Internal tool: GitHub PR automated review powered by DeepSeek, written in Elixir (Phoenix, no database).

Every `pull_request` `opened`/`synchronize` webhook triggers a review pipeline:
fetch diff → filter files → per-file DeepSeek review using **README-style skill files** (`skills/*/README.md`) → CRITICAL/HIGH issues as inline comments, the rest in a summary review.

## Architecture at a glance

- **No database.** Everything is in-memory: de-duplication via an ETS guard (TTL), stats via ETS counters, audit trail via structured logs.
- **Concurrency**: one `Coordinator` GenServer per PR (`DynamicSupervisor`), files reviewed with `Task.async_stream(max_concurrency: 10)`.
- **Retry**: in-process exponential backoff for transient DeepSeek/GitHub errors (does not survive a restart — documented limitation).
- **Skills**: Markdown files in `skills/` that the bot reads and tells the LLM to follow. Extension → skill mapping in `config/config.exs` (`:skills_manifest`).

## Local development

### Requirements

- Elixir >= 1.18 (Erlang/OTP 27), Postgres not required.
- A GitHub App (see below) and a DeepSeek API key for real end-to-end runs. All tests run against Mox mocks — no credentials needed.

### Setup

```bash
mix deps.get
cp .env.example .env        # fill in values for e2e
mix test                    # 80 tests, fully mocked
mix codeseeker.stats        # in-memory counters (after some reviews)
mix phx.server              # runs on PORT (default 4000)
```

### Webhook testing locally

GitHub must reach your machine. With Tailscale:

```bash
tailscale funnel --bg 4000
```

Then set the GitHub App webhook URL to `https://<machine>.<tailnet>.ts.net/webhook/github`
and open a test PR — watch `mix phx.server` logs for `review_finished`.

## GitHub App setup

1. Create an app at https://github.com/settings/apps/new:
   - Permissions: `pull_requests: write`, `contents: read`, `metadata: read`.
   - Webhook events: `pull_request`, `issue_comment`.
   - Webhook secret: `openssl rand -hex 32`.
   - Generate a private key (PEM).
2. Install the app on your org/repo(s).
3. Configure the environment (see `.env.example`):
   - `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY_PATH`, `GITHUB_WEBHOOK_SECRET`, `DEEPSEEK_API_KEY`.

## Skills (README-style)

Skills live in `skills/<name>/README.md`. The bot includes a skill's content verbatim in the prompt
for files matching its extensions. Optional `## Severity` section:

```markdown
## Severity
- xss: CRITICAL
```

raises reported issues whose message matches the key to that severity.

**Adding a skill**: add `skills/<name>/README.md`, add its extensions to `:skills_manifest`, restart.

Available skills: `generic` (fallback), `typescript`, `go`, `php`, `elixir`.

## Per-repo configuration

`config :codeseeker, :repos` in `config/config.exs`:

```elixir
config :codeseeker, :repos, %{
  "acme-internal/web-frontend" => %{enabled: true, skills: ["typescript", "generic"], min_inline_severity: "HIGH"},
  "acme-internal/legacy-api"   => %{enabled: false}
}
```

Runtime changes (lost on restart — persist them in the config above):

| Command | Effect |
|---|---|
| `/codeseeker status` | Show bot state for the repo |
| `/codeseeker enable-skill <name>` | Enable a skill |
| `/codeseeker disable-skill <name>` | Disable a skill |

## Configuration knobs (`config/config.exs`)

| Key | Default | Meaning |
|---|---|---|
| `:min_inline_severity` | `"HIGH"` | Issues ≥ this severity become inline comments; the rest go to the summary |
| `:max_files_per_pr` | `30` | Hard cap of reviewed files per PR |
| `:exclusions` | — | Lockfiles/generated/binary/oversized-file skip rules (`max_patch_bytes: 300_000`, `max_added_lines: 1_500`) |
| `:review_concurrency` | `10` | `Task.async_stream` concurrency (DeepSeek burst control) |
| `:guidelines_path` | `docs/engineering-guidelines.md` | Repo file fetched per PR and appended to prompts |
| `:dedup_ttl_seconds` | `3600` | Window in which the same `(repo, pr, head_sha)` is not re-reviewed |

## Deployment

See `deploy/` for the Dockerfile, systemd unit and `deploy.sh`, and `.github/workflows/`
for CI (lint + test) and CD (tag-triggered release push over Tailscale SSH).

Checklist:

1. `deploy/codeseeker.env.example` → `/etc/codeseeker.env` (chmod 600) with real secrets.
2. Build the release, extract to `/opt/codeseeker`, enable `codeseeker.service`.
3. Expose the webhook publicly (`tailscale funnel --bg 4000` on the VPS, or a reverse proxy).
4. Point the GitHub App webhook URL at `https://<host>/webhook/github` and confirm a `ping` event in the logs.

## Known limitations

- No persistent storage: dedup, stats and per-repo runtime toggles are lost on restart; in-flight reviews are dropped.
- `/codeseeker` commands can be triggered by anyone who can comment on a PR (internal single-org tool).
- False positives are controlled by severity thresholds and the skill files; review them every 2 weeks (PRD §3).
