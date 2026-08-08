# Codeseeker — AI Code Review Bot

> Internal tool: GitHub PR automated review powered by DeepSeek, written in Elixir (Phoenix + PostgreSQL + Oban).

Every `pull_request` `opened`/`synchronize` webhook triggers a review pipeline:
fetch diff → filter files → **fan out to review agents** (Bug, Security, Performance, ...) → aggregate all issues into a GitHub review (CRITICAL/HIGH as inline comments, the rest in a summary).

## Architecture at a glance

- **PR Analyzer** (`FetchDiffJob`) fetches the diff, filters files, stores the kept files + repo guidelines, and enqueues one `AgentJob` per review agent.
- **Review agents** (`AgentJob` × N, `review` queue): each agent reviews the **whole PR diff** with its own focused prompt (persona + rules + severity bias from `agents/*.md`). Agents are cross-language dimensions, applied per PR rather than per file — so a PR gets Bug, Security, Performance, Code Quality, Architecture, Maintainability, Testing, Dependency, and API/Contract coverage.
- **Durable queue (Oban + PostgreSQL)**: webhooks are enqueued and processed reliably. Nothing is lost on restart — the whole 500-PR backlog survives a restart.
- **Idempotency**: a review run is keyed by `(github_repo_id, pr_number, head_sha)` with a DB unique constraint, so GitHub webhook redelivery never duplicates work.
- **Rate limiting for scale**: the `review` queue is capped at `limit: 30` — that is the **global ceiling on concurrent DeepSeek calls** across all agents and PRs. Hundreds of PRs can be accepted at once; agent jobs run 30-at-a-time without rate-limit storms.
- **Aggregator** (`AggregateReviewJob`): runs when the last agent finishes (row-locked completion counter), splits issues inline vs summary, and posts the GitHub review.

## Local development

### Requirements

- Elixir >= 1.18 (Erlang/OTP 27) and a running PostgreSQL.
- A GitHub App (see below) and a DeepSeek API key for real end-to-end runs. All tests run against Mox mocks + the local Postgres.

### Setup

```bash
mix deps.get
mix ecto.create && mix ecto.migrate
cp .env.example .env        # fill in values for e2e
mix test                    # 84 tests (DB sandbox + mocks)
mix codeseeker.stats        # runtime counters
mix phx.server              # runs on PORT (default 4000)
```

### Webhook testing locally

GitHub must reach your machine. With Tailscale:

```bash
tailscale funnel --bg 4000
```

Then set the GitHub App webhook URL to `https://<machine>.<tailnet>.ts.net/webhook/github`
and open a test PR — watch `mix phx.server` logs for `fetch_diff enqueued review` and `all files reviewed — enqueueing aggregate`.

## GitHub App setup

1. Create an app at https://github.com/settings/apps/new:
   - Permissions: `pull_requests: write`, `contents: read`, `metadata: read`.
   - Webhook events: `pull_request`, `issue_comment`.
   - Webhook secret: `openssl rand -hex 32`.
   - Generate a private key (PEM).
2. Install the app on your org/repo(s).
3. Configure the environment (see `.env.example`):
   - `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY_PATH`, `GITHUB_WEBHOOK_SECRET`, `DEEPSEEK_API_KEY`.

## Review agents (README-style)

Each review agent lives in `agents/<name>.md` and is a focused reviewer persona
(Bug, Security, Performance, Code Quality, Architecture, Maintainability,
Testing, Dependency, API/Contract). The bot includes the agent's content
verbatim in the prompt. Optional `## Severity` section:

```markdown
## Severity
- sql injection: CRITICAL
```

raises reported issues whose message matches the key to that severity.

**Adding an agent**: add `agents/<name>.md`, restart. Every PR is reviewed by
all configured agents (`config :codeseeker, :agents_dir`).

Agents are cross-language and review the whole PR diff. A separate language
`skills/` system (per-file) is also bundled and can be enabled later; agents
are the active path.

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
| `:guidelines_path` | `docs/engineering-guidelines.md` | Repo file fetched per PR and appended to prompts |

**Oban queues** (the 500-PR scale levers):

| Queue | `limit` | Meaning |
|---|---|---|
| `webhook` | 4 | Concurrent GitHub payload intake jobs |
| `review` | **30** | **Global cap on concurrent DeepSeek calls** — raise/lower to trade throughput vs rate-limit risk |

## Deployment

See `deploy/` for the Dockerfile, systemd unit and `deploy.sh`, and `.github/workflows/`
for CI (lint + test) and CD (tag-triggered release push over Tailscale SSH).

Checklist:

1. Provision PostgreSQL on the VPS and create `codeseeker_prod` (plus a user + password).
2. `deploy/codeseeker.env.example` → `/etc/codeseeker.env` (chmod 600) with real secrets, including `DATABASE_URL`.
3. Build the release, extract to `/opt/codeseeker`, run `bin/codeseeker eval "Ecto.Migrator.run(Codeseeker.Repo, ...)"` (or `mix ecto.migrate`) to create the Oban + review tables, then enable `codeseeker.service`.
4. Expose the webhook publicly (`tailscale funnel --bg 4000` on the VPS, or a reverse proxy).
5. Point the GitHub App webhook URL at `https://<host>/webhook/github` and confirm a `ping` event in the logs.

## Known limitations

- Per-repo runtime toggles (`/codeseeker`) are in-memory and reset on restart — persist them in `config :codeseeker, :repos`.
- `/codeseeker` commands can be triggered by anyone who can comment on a PR (internal single-org tool).
- False positives are controlled by severity thresholds and the skill files; review them every 2 weeks (PRD §3).
