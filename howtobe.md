# HowToBe — Bugseeker Tutorial

A complete guide to running, configuring, and deploying **Bugseeker** — an
AI code review bot (Elixir/Phoenix + Oban + PostgreSQL + DeepSeek) that
automatically reviews every GitHub Pull Request.

Table of contents:

1. [Prerequisites](#1-prerequisites)
2. [Running Locally](#2-running-locally)
3. [Testing Webhooks Locally](#3-testing-webhooks-locally)
4. [Configuration](#4-configuration)
   - [Environment variables](#environment-variables)
   - [Per-repo agent routing (.bugseeker.yml)](#per-repo-agent-routing-bugseekeryml)
   - [Service-side configuration](#service-side-configuration)
   - [Writing / editing agents](#writing--editing-agents)
5. [Deployment](#5-deployment)
6. [Operations & Troubleshooting](#6-operations--troubleshooting)

---

## 1. Prerequisites

| Requirement | Version | Purpose |
|---|---|---|
| Elixir | >= 1.18 (OTP 27) | compile & run |
| PostgreSQL | >= 14 | Oban queue + review runs |
| GitHub App | — | receive webhooks & post reviews |
| DeepSeek API key | — | LLM review |

### Creating the GitHub App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New**:
   - **Webhook URL**: `https://<your-host>/webhook/github`
   - **Webhook secret**: generate with `openssl rand -hex 32`
   - **Permissions** (Repository):
     - Pull requests: **Read & write** (post reviews)
     - Issues: **Read & write** (reply to `/bugseeker` commands)
     - Contents: **Read-only** (read diffs, guidelines, `.bugseeker.yml`)
   - **Subscribe to events**: `pull_request`, `issue_comment`
2. **Generate a private key** (a `.pem` file) and store it safely.
3. Note the **App ID** from the app page.
4. **Install** the app on the org/repos you want reviewed.

---

## 2. Running Locally

```bash
# 1. Install dependencies
mix deps.get

# 2. Set up the database
mix ecto.create && mix ecto.migrate

# 3. Configure the environment
cp .env.example .env
#    fill in: GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY_PATH, GITHUB_WEBHOOK_SECRET,
#             DEEPSEEK_API_KEY, DATABASE_URL

# 4. Run the tests (optional but recommended — 100 tests, Mox + DB sandbox)
mix test

# 5. Start the server (default port 4000)
mix phx.server
```

Verify the server is up:

```bash
curl http://localhost:4000/healthz   # -> ok
mix bugseeker.stats                 # runtime counters (optional)
```

---

## 3. Testing Webhooks Locally

GitHub must be able to reach your machine. The easiest way is Tailscale:

```bash
tailscale funnel --bg 4000
```

Then set the GitHub App webhook URL to:

```
https://<machine>.<tailnet>.ts.net/webhook/github
```

Open a PR in a repo where the app is installed, then watch the
`mix phx.server` log — you will see `FetchDiffJob` → `AgentJob` × N →
`AggregateReviewJob`, and the review appears on the PR.

---

## 4. Configuration

### Environment variables

All read in `config/runtime.exs`:

| Variable | Required | Default | Description |
|---|---|---|---|
| `DATABASE_URL` | prod | `postgres://localhost:5432/bugseeker_dev` | Oban queue + review runs |
| `GITHUB_APP_ID` | prod | — | GitHub App ID |
| `GITHUB_APP_PRIVATE_KEY_PATH` | prod | — | Path to the `.pem` file |
| `GITHUB_WEBHOOK_SECRET` | prod | — | Webhook secret (HMAC) |
| `DEEPSEEK_API_KEY` | yes | — | DeepSeek API key |
| `DEEPSEEK_API_URL` | no | `https://api.deepseek.com` | API endpoint |
| `DEEPSEEK_MODEL` | no | `deepseek-chat` | LLM model |
| `PORT` | no | `4000` | HTTP port |
| `PHX_SERVER` | no | — | Set `true` to enable the endpoint |

In dev, values come from `.env` (via Dotenv). In prod they **must** come
from the environment — the app raises at boot if any are missing.

### Per-repo agent routing (`.bugseeker.yml`)

The primary way to control which agents review a given repo: **a file inside
that repo itself**. Each team manages its own repo — no service restart
required.

Place `.bugseeker.yml` (or `.bugseeker.yaml`) at the target repo's root:

```yaml
# Framework bundle: a name without "_" expands to all "<name>_*" agents.
agents:
  - nestjs          # -> nestjs_architecture, nestjs_code_quality, nestjs_performance, nestjs_security, nestjs_testing
  - typescript      # -> all typescript_*

# Or name individual agents:
# agents:
#   - nestjs_security
#   - react_js_testing

# Issues at or above this severity become inline comments; the rest go to
# the summary.
min_inline_severity: HIGH
```

Key behaviors:

- The file is fetched once per review run at the PR's **head sha** — changes
  take effect on the next PR with no restart of anything.
- Unknown agent names are **ignored**; a repo can never end up with zero
  agents because of a typo.
- Without this file, the service-side config below applies.

Available agents (auto-loaded from `priv/agents/**/*.md` at boot):

| Bundle | Agents |
|---|---|
| `react_js` | architecture, code_quality, performance, security, testing |
| `next_js` | architecture, code_quality, performance, security, testing |
| `nestjs` | architecture, code_quality, performance, security, testing |
| `typescript` | architecture, code_quality, performance, security, testing |

### Service-side configuration

`config/config.exs`:

```elixir
# Per-repo overrides (used when the repo has NO .bugseeker.yml)
config :bugseeker, :repos, %{
  "acme-internal/web-frontend" => %{
    agents: ["next_js", "typescript"],
    min_inline_severity: "HIGH"
  },
  "acme-internal/legacy-api" => %{enabled: false}
}

# Default inline threshold (CRITICAL > HIGH > MEDIUM > LOW > INFO)
config :bugseeker, :min_inline_severity, "HIGH"

# Hard cap on reviewed files per PR
config :bugseeker, :max_files_per_pr, 30

# Team guidelines file fetched per PR and appended to prompts
config :bugseeker, :guidelines_path, "docs/engineering-guidelines.md"
```

Runtime configuration via PR comments (**lost on restart** — persist in
`config :repos`):

| Command | Effect |
|---|---|
| `/bugseeker status` | Show bot state for the repo |
| `/bugseeker enable-agent <name>` | Enable an agent |
| `/bugseeker disable-agent <name>` | Disable an agent |

### Writing / editing agents

An agent is a markdown file under `priv/agents/`. Layout:

```
priv/agents/<framework>/<dimension>.md   -> agent "<framework>_<dimension>"
```

Two optional sections are parsed as metadata (not sent to the LLM):

```markdown
## File Types
- .ts
- .tsx
```

→ the agent only runs when the PR touches a file with one of those
extensions.

```markdown
## Severity
- sql-injection: CRITICAL
- missing-validation: MEDIUM
```

→ issues whose message contains a key are raised to that severity.

Everything else (persona, `## Rules`, `## False Positives`, ...) is sent
verbatim as the review instructions. **Edit a file → restart → live.** Use
the existing `priv/agents/react_js/` files as the structural template.

---

## 5. Deployment

Deploy artifacts live in `deploy/`: `Dockerfile`, `entrypoint.sh`,
`deploy.sh` (push over Tailscale SSH), `systemd/bugseeker.service`, and
`bugseeker.env.example`.

### VPS checklist (systemd)

1. **PostgreSQL**: provision on the VPS, create the database + user:

   ```sql
   CREATE DATABASE bugseeker_prod;
   CREATE USER bugseeker WITH PASSWORD '...';
   GRANT ALL PRIVILEGES ON DATABASE bugseeker_prod TO bugseeker;
   ```

2. **Env file**:

   ```bash
   sudo cp deploy/bugseeker.env.example /etc/bugseeker.env
   sudo chmod 600 /etc/bugseeker.env
   # fill in DATABASE_URL, GITHUB_*, DEEPSEEK_API_KEY, etc.
   # also copy the private key: /etc/bugseeker-app.pem
   ```

3. **Build & deploy the release**:

   ```bash
   MIX_ENV=prod mix release
   deploy/deploy.sh <vps-host>
   ```

   `deploy.sh` automatically: tars the release → scp → extracts to
   `/opt/bugseeker` → runs `bin/bugseeker eval "Bugseeker.Release.migrate()"`
   → restarts `bugseeker.service` → checks `/healthz`.

4. **systemd unit** (first deploy only):

   ```bash
   sudo cp deploy/systemd/bugseeker.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now bugseeker
   ```

5. **Expose the webhook** (pick one):

   ```bash
   tailscale funnel --bg 4000        # simplest
   # or a reverse proxy (nginx/caddy) with TLS
   ```

6. **Point the GitHub App** webhook URL at `https://<host>/webhook/github`,
   then re-deliver the `ping` event — confirm it appears in the log:

   ```bash
   journalctl -u bugseeker -f
   ```

### Docker (alternative)

```bash
docker build -f deploy/Dockerfile -t bugseeker .
docker run --env-file /etc/bugseeker.env -p 4000:4000 bugseeker
```

`entrypoint.sh` runs migrations automatically before starting the server.

### Important deploy notes

- **Migrations must run** before traffic: the Oban tables + `pr_reviews`
  (including the latest `min_inline_severity` column migration).
- CI/CD: `.github/workflows/` contains lint+test CI and tag-triggered CD
  that pushes the release over Tailscale SSH.

---

## 6. Operations & Troubleshooting

### Monitoring the queue and results

```bash
mix bugseeker.stats          # runtime counters
```

Oban stores every job in PostgreSQL — a restart loses nothing; failed jobs
retry with backoff (max 5 attempts for `FetchDiffJob`/`AgentJob`, 3 for
`AggregateReviewJob`).

### Common issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Webhook 401 | `GITHUB_WEBHOOK_SECRET` mismatch | Match it to the GitHub App secret |
| No review appears | Repo disabled / agents filtered out by file types | `/bugseeker status` on the PR; check the agent's `## File Types` |
| Duplicate reviews | — | Not possible: runs are keyed by unique `(repo, PR, head_sha)`; redeliveries are discarded |
| LLM rate limit | Too many concurrent calls | Lower the `review` queue `limit` (default 30) in the Oban config |
| Inline comments missing | Invalid line (GitHub 422) | Automatically demoted to the summary — expected behavior |
| Wrong framework agents firing | Repo has no routing configured | Add a `.bugseeker.yml` to the target repo |
| Config change not taking effect | `.bugseeker.yml` on the wrong branch | The file is read from the **PR head sha**, not the default branch |

### Scale

- The `review` queue with `limit: 30` is the **global ceiling** on concurrent
  DeepSeek calls across all PRs. Hundreds of PRs can be accepted at once
  without rate-limit storms; only raise the limit if your DeepSeek quota
  allows it.
- `:max_files_per_pr` (default 30) plus the lockfile/large-file exclusion
  rules keep prompt sizes reasonable.

### Known limitations

- `/bugseeker` toggles are in-memory — persist them in `config :repos` or
  `.bugseeker.yml`.
- `/bugseeker` commands can be triggered by anyone who can comment on a PR
  (internal single-org design).
- False positives are controlled via severity thresholds + the agent files;
  review them periodically (PRD §3 recommends every 2 weeks).
