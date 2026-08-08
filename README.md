# Codeseeker — AI Code Review Bot

> Internal tool: GitHub PR automated review powered by DeepSeek, written in Elixir (Phoenix + PostgreSQL + Oban).

Every `pull_request` `opened`/`synchronize` webhook triggers a review pipeline:
fetch diff → filter files → per-file DeepSeek review using **README-style skill files** (`skills/*/README.md`) → CRITICAL/HIGH issues as inline comments, the rest in a summary review.

## Architecture at a glance

- **Durable queue (Oban + PostgreSQL)**: webhooks are enqueued and processed reliably. Nothing is lost on restart — the whole 500-PR backlog survives a restart.
- **Idempotency**: a review run is keyed by `(github_repo_id, pr_number, head_sha)` with a DB unique constraint, so GitHub webhook redelivery never duplicates work.
- **Rate limiting for scale**: Oban's `review` queue is capped at `limit: 30` — that is the **global ceiling on concurrent DeepSeek calls**. Hundreds of PRs can be accepted at once; files are processed 30-at-a-time without rate-limit storms.
- **Pipeline**: `FetchDiffJob` (intake) → `ReviewFileJob` × N (one per file) → `AggregateReviewJob` (posts the review when the last file finishes, via a row-locked completion counter).
- **Skills**: Markdown files in `skills/` that the bot reads and tells the LLM to follow. Extension → skill mapping in `config/config.exs` (`:skills_manifest`).

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
