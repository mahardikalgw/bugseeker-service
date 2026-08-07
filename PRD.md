# PRD: AI Code Review Bot (Elixir)
**Internal tool — GitHub PR Automated Review**

| | |
|---|---|
| Status | Draft |
| Owner | Otongs (Muhammad Kharisma Mahardika) |
| Target user | Tim engineering internal kantor |
| Versi | 0.1 |
| Tanggal | 8 Agustus 2026 |

---

## 1. Latar Belakang

Setiap PR yang masuk saat ini direview manual oleh reviewer, yang memakan waktu dan rawan miss pada hal-hal berulang (bug pola umum, isu keamanan dasar, style, transaksi DB yang tidak dibungkus, dsb). Kita ingin bot otomatis yang menempel di GitHub App/webhook, membaca diff PR, dan memberi review awal — bukan menggantikan reviewer manusia, tapi menyaring isu-isu yang jelas sebelum manusia turun tangan.

Elixir dipilih karena karakteristik beban kerja bot ini didominasi I/O (panggilan GitHub API + LLM API) dan butuh concurrency + fault tolerance saat banyak PR datang bersamaan — bukan beban CPU berat. BEAM/OTP (Supervisor, Task, GenServer) + Oban sebagai job queue cocok untuk pola ini.

## 2. Tujuan (Goals)

1. Setiap PR baru/update otomatis mendapat komentar review dalam < 2 menit untuk PR berukuran wajar (< 500 baris diff).
2. Mengurangi jumlah bug/isu dasar (security, transaksi DB, null-check, dsb) yang lolos ke review manusia.
3. Reviewer manusia fokus ke isu arsitektural/bisnis, bukan isu-isu mekanis yang bisa dideteksi otomatis.
4. Bot tidak "berisik" — hanya isu severity CRITICAL/HIGH yang otomatis dikomentari inline, sisanya masuk ringkasan.
5. Kualitas review bisa disesuaikan per bahasa pemrograman lewat **skill** yang bisa diaktifkan/nonaktifkan per repo — bot tidak memakai satu prompt generik untuk semua bahasa, tapi "tahu" konvensi dan kerawanan spesifik tiap bahasa (mis. Go: goroutine leak/error handling; PHP: SQL injection/type juggling; JS/TS: promise handling/XSS).

### Non-Goals (di luar scope V1)
- Bot tidak melakukan auto-fix / auto-commit.
- Bot tidak menggantikan approval reviewer manusia.
- Tidak multi-tenant/SaaS — ini tool internal single-org.

## 3. Metrik Keberhasilan

| Metrik | Target |
|---|---|
| Waktu dari PR opened → komentar pertama | < 2 menit |
| False positive rate (isu yang dikomentari tapi tidak relevan) | < 20% (dievaluasi manual tiap 2 minggu di awal) |
| Uptime job processing | > 99% (retry otomatis via Oban) |
| Adopsi | Dipakai di ≥ 1 repo aktif dalam 4 minggu pertama |

## 4. Arsitektur Sistem

```
GitHub PR (opened/synchronize)
        │
        │ webhook (signed, HMAC-SHA256)
        ▼
Phoenix Endpoint (WebhookController)
        │
        ├── Verifikasi signature
        ├── Filter event (pr opened/synchronize saja)
        ▼
Oban Job: FetchDiffJob
        │
        ├── Ambil diff via GitHub API
        ├── Pecah per file
        ▼
Oban Job: ReviewFileJob (dispatch per file, max_concurrency terbatas)
        │
        ├── Deteksi bahasa dari ekstensi file (.go, .php, .ts, dst)
        ├── Skill Registry → pilih skill aktif untuk repo + bahasa itu
        │       (system prompt + rules + severity bias khusus bahasa)
        ├── Task.async_stream → panggil DeepSeek API per file (prompt = skill terpilih)
        ▼
Aggregator (GenServer/context module)
        │
        ├── Kumpulkan semua hasil review per file dalam 1 PR
        ├── Filter severity (CRITICAL/HIGH → inline comment, MEDIUM/LOW/INFO → summary)
        ▼
GitHub API — Post Review
        │
        └── Inline comments + summary comment di PR
```

### Komponen

| Komponen | Teknologi | Peran |
|---|---|---|
| Web/webhook | Phoenix | Terima & validasi webhook GitHub |
| Job queue | Oban (+ PostgreSQL) | Antrian & retry job async, tanpa Redis di awal |
| DB | PostgreSQL | Job storage (Oban), log review, konfigurasi repo |
| GitHub client | Req + GitHub REST/GraphQL API | Ambil diff, post comment/review |
| Skill Registry | Modul Elixir (behaviour) + config DB | Pilih & rakit system prompt sesuai bahasa/repo |
| LLM | DeepSeek API | Reasoning/analisis code |
| Auth ke GitHub | GitHub App (bukan PAT) | Least-privilege, scoped ke repo yang diaktifkan |
| Observability | Telemetry + Logger (OpenTelemetry opsional belakangan) | Tracing job & error |
| Deployment | VPS (existing punya Otongs) via Tailscale + GitHub Actions CI/CD | Konsisten dengan setup infra yang sudah ada |

### Alur Data Detail (V1)

1. GitHub kirim webhook `pull_request` (action: `opened` / `synchronize`) → Phoenix endpoint.
2. Verifikasi `X-Hub-Signature-256`. Tolak jika tidak valid.
3. Enqueue `Oban.Job` (`FetchDiffJob`) dengan payload `{repo, pr_number, installation_id}`.
4. `FetchDiffJob` ambil diff via GitHub API (`GET /repos/{owner}/{repo}/pulls/{pr}/files`), simpan daftar file+patch.
5. Untuk tiap file (exclude file besar/binary/lockfile), enqueue `ReviewFileJob` — atau proses sekaligus dalam satu job pakai `Task.async_stream/3` dengan `max_concurrency: 5-10` supaya tidak menabrak rate limit DeepSeek.
6. Tiap `ReviewFileJob` panggil DeepSeek dengan prompt berisi: diff file, sedikit context sekitar (opsional V2), guideline singkat.
7. Response LLM di-parse jadi struktur `%Issue{file, line, severity, message, recommendation}` (structured output / JSON mode).
8. Setelah semua file selesai (tracked pakai Oban batch atau counter di DB), aggregator kumpulkan semua `Issue`, filter berdasarkan severity untuk menentukan mana yang jadi inline comment vs masuk summary.
9. Post ke GitHub: `POST /repos/{owner}/{repo}/pulls/{pr}/reviews` — inline comments untuk CRITICAL/HIGH, body markdown untuk summary MEDIUM/LOW/INFO.

### 4.1 Sistem Skill Per Bahasa

Alih-alih satu system prompt generik untuk semua file, tiap bahasa punya **skill**: paket berisi system prompt, daftar rules/checklist, dan bias severity yang spesifik untuk bahasa itu. Skill diaktifkan per repo, jadi repo Go hanya pakai skill Go, repo yang campur Go+TS memakai keduanya sekaligus (dipilih otomatis per file berdasarkan ekstensi).

```
File masuk (*.go)
      │
      ▼
Deteksi bahasa (ekstensi / heuristik sederhana)
      │
      ▼
Skill Registry
      │
      ├── Skill aktif untuk repo ini? (cek repo_skills)
      │       tidak aktif → skip / fallback ke skill generic
      │       aktif       → ambil skill go
      ▼
Rakit prompt final = base_prompt + skill.rules + skill.severity_bias
      │
      ▼
Kirim ke DeepSeek
```

**Struktur skill (behaviour Elixir):**

```elixir
defmodule ReviewBot.Skill do
  @callback language() :: String.t()
  @callback file_extensions() :: [String.t()]
  @callback system_prompt() :: String.t()
  @callback rules() :: [String.t()]
  @callback severity_bias() :: map()  # override severity default per kategori
end

defmodule ReviewBot.Skills.Go do
  @behaviour ReviewBot.Skill

  def language, do: "go"
  def file_extensions, do: [".go"]

  def system_prompt do
    """
    Kamu reviewer senior Go. Fokus pada: error handling eksplisit,
    goroutine leak, race condition, penggunaan context yang tepat,
    dan idiomatic Go (hindari over-engineering).
    """
  end

  def rules do
    [
      "Cek apakah error selalu di-handle, bukan diabaikan (_ = err)",
      "Cek goroutine yang dibuat tanpa mekanisme cancel/wait",
      "Cek penggunaan panic/recover yang tidak perlu di luar boundary",
      "Cek slice/map yang di-share antar goroutine tanpa sinkronisasi"
    ]
  end

  def severity_bias, do: %{"race_condition" => "CRITICAL", "unused_error" => "HIGH"}
end
```

Skill baru = tambah 1 modul yang implement behaviour ini, lalu register di `ReviewBot.Skills.Registry`. Tidak perlu ubah kode orchestrator/job — cukup plug-in.

**Skill bawaan yang direncanakan (bisa nambah kapan saja):**

| Skill | Bahasa | Fokus utama |
|---|---|---|
| `go` | Go | error handling, goroutine/race, context |
| `php` | PHP | SQL injection, type juggling, N+1 query |
| `typescript` | TS/JS | promise handling, XSS, `any` berlebihan |
| `elixir` | Elixir | pattern match exhaustiveness, proses tanpa supervisi |
| `generic` | fallback | isu umum lintas bahasa (naming, duplikasi, komentar) |

**Konfigurasi per repo:** tabel `repo_skills` menentukan skill mana yang aktif untuk repo tertentu (lihat skema di bawah). Bisa diaktifkan lewat command sederhana (mis. comment `/enable-skill go` di PR, atau lewat seed config awal — UI pengaturan bisa menyusul di fase belakang).

## 5. Skema Data (Draft Awal)

```
repos
  id, github_repo_id, owner, name, installation_id, enabled, inserted_at

repo_skills
  id, repo_id, skill_name (fk logis ke module skill, mis. "go", "php"),
  enabled, inserted_at
  -- unique(repo_id, skill_name)

pr_reviews
  id, repo_id, pr_number, head_sha, status (pending/processing/completed/failed),
  started_at, completed_at

review_issues
  id, pr_review_id, file_path, line, severity, category (security/perf/bug/style/arch),
  skill_used (mis. "go", "generic"),
  message, recommendation, posted (bool)

oban_jobs   -- generated otomatis oleh Oban
```

Catatan: daftar skill itu sendiri (`system_prompt`, `rules`, `severity_bias`) hidup sebagai **kode Elixir** (behaviour + modul), bukan data di DB — supaya versioning-nya ikut Git dan gampang direview lewat PR juga. Tabel `repo_skills` hanya menyimpan *toggle* mana yang aktif per repo, bukan isi skill-nya.

## 6. Prompt & Output Contract (DeepSeek)

- System prompt final = `base_prompt` (instruksi umum + format output) + `skill.system_prompt()` + `skill.rules()` untuk bahasa file tersebut. Kalau tidak ada skill yang cocok/aktif, fallback ke skill `generic`.
- Instruksi format tetap wajib di `base_prompt`: "kamu adalah code reviewer senior, output HANYA JSON, tanpa markdown fence."
- Format output per file:
```json
{
  "issues": [
    {
      "line": 84,
      "severity": "HIGH",
      "category": "security",
      "message": "...",
      "recommendation": "..."
    }
  ]
}
```
- Severity enum tetap: `CRITICAL | HIGH | MEDIUM | LOW | INFO`.
- Jika tidak ada isu → `{"issues": []}`.

## 7. Fase Eksekusi (Roadmap)

### Fase 0 — Persiapan (Minggu 0)
- [ ] Setup GitHub App (permissions: `pull_requests: write`, `contents: read`), generate private key.
- [ ] Setup project Phoenix baru + Oban + Ecto/Postgres.
- [ ] Provisioning DB di VPS existing, siapkan `.env`/config runtime (`DEEPSEEK_API_KEY`, `GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY`, `GITHUB_WEBHOOK_SECRET`).

### Fase 1 — V1 Basic (Minggu 1)
**Target: PR → diff → LLM → 1 comment, end-to-end jalan di 1 repo test.**
- [ ] `WebhookController` + signature verification.
- [ ] `FetchDiffJob` (ambil diff dari GitHub API).
- [ ] Definisikan `ReviewBot.Skill` behaviour + implementasi skill `generic` (dipakai sebagai default/fallback).
- [ ] `ReviewFileJob` + `Task.async_stream` ke DeepSeek (prompt masih pakai skill `generic` untuk semua file dulu).
- [ ] Parser JSON output DeepSeek → struct `Issue`.
- [ ] Post review sederhana (semua isu jadi 1 summary comment dulu, belum inline).
- [ ] Deploy ke VPS, test di 1 repo internal kecil.

### Fase 2 — V1.5 Inline Review (Minggu 2)
- [ ] Pisahkan CRITICAL/HIGH → inline comment per baris via GitHub Review API.
- [ ] MEDIUM/LOW/INFO → tetap di summary.
- [ ] Simpan hasil review ke tabel `review_issues` (audit trail).
- [ ] Basic retry/backoff kalau DeepSeek timeout (manfaatkan retry bawaan Oban).

### Fase 3 — V2 Context-aware + Multi-skill (Minggu 3-4)
- [ ] Bangun `ReviewBot.Skills.Registry` (deteksi bahasa dari ekstensi file → pilih skill).
- [ ] Implementasi skill bahasa prioritas pertama (mis. `go`, `php`, `typescript` — sesuaikan urutan dengan stack yang paling sering di-PR di kantor).
- [ ] Tabel + context `repo_skills` untuk toggle skill per repo (aktif/nonaktif).
- [ ] Cara aktivasi skill: mulai dari seed config manual (migration/seed), command `/enable-skill <nama>` via PR comment bisa menyusul.
- [ ] Tambahkan file guideline internal (`docs/engineering-guidelines.md`, dsb) sebagai context tambahan — bisa digabung ke `base_prompt` atau jadi bagian dari skill tertentu.
- [ ] Exclude file yang tidak perlu direview (lockfile, generated code, migration snapshot besar).
- [ ] Rate limiting ke DeepSeek (hindari burst saat PR besar).
- [ ] Dashboard/log sederhana (bisa CLI/psql dulu, belum perlu UI).

### Fase 4 — V3 Noise Control (Minggu 5)
- [ ] Tuning severity threshold berdasarkan feedback tim (kalau false positive tinggi, naikkan threshold).
- [ ] Opsi per-repo: aktif/nonaktif bot, custom severity threshold.

### Fase 5 — V4 Static Analysis (Backlog, opsional)
- [ ] Integrasi static analyzer sesuai stack tim (mis. ESLint/PHPStan/Semgrep) berjalan paralel dengan LLM, hasil digabung di aggregator yang sama.

## 8. Risiko & Mitigasi

| Risiko | Mitigasi |
|---|---|
| Rate limit DeepSeek saat PR besar | Batasi `max_concurrency`, chunk per file, retry dengan backoff |
| False positive tinggi → tim ignore bot | Threshold severity ketat di awal (hanya CRITICAL/HIGH inline), evaluasi mingguan |
| Diff sangat besar (>1000 baris) | Skip file yang terlalu besar / hanya review N file teratas + catat "diff terlalu besar, review manual" |
| Webhook secret bocor | Simpan di env/secret manager VPS, rotate berkala |
| GitHub API rate limit (5000/jam per installation) | Cache hasil `GET files` per SHA, hindari re-fetch saat retry job |

## 9. Stack Ringkas

| Layer | Pilihan |
|---|---|
| Bahasa | Elixir |
| Web framework | Phoenix (tanpa LiveView dulu, cukup API) |
| Job queue | Oban |
| DB | PostgreSQL |
| HTTP client | Req |
| LLM | DeepSeek API |
| Auth GitHub | GitHub App + JWT untuk installation token |
| Deploy | VPS existing (Tailscale + GitHub Actions CI/CD, pola yang sudah dipakai sebelumnya) |

## 10. Open Questions
- Nama bot/project final? (kandidat: lanjutkan nama "Kritikus" dari versi Python sebelumnya, atau nama baru?)
- Repo mana yang jadi pilot pertama, dan bahasa apa yang dipakai repo itu (menentukan skill mana yang harus jadi prioritas pertama selain `generic`)?
- Urutan prioritas skill bahasa: Go, PHP, TypeScript — mana dulu yang paling sering muncul di PR kantor?
- Siapa yang approve/curate guideline internal untuk V2 (context-aware)?
- Aktivasi skill per repo: cukup lewat seed/migration manual dulu, atau langsung butuh command `/enable-skill` di PR sejak awal?