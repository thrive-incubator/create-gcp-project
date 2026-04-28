# create-gcp-project

`create-gcp-project.sh` scaffolds a complete full-stack GCP Cloud Run project
in one command. It creates the GCP project, enables required APIs, sets IAM,
provisions Firestore + Artifact Registry + Secret Manager + a Cloud Run runner
service account, and generates a working FastAPI + React/Vite/TS/Tailwind
codebase with `deploy.sh`, `run-local.sh`, `fix_permissions.sh`, optional
staging deploy script, optional GitHub repo, and a clean initial git commit.

The script supports two modes:

- **Interactive (default).** `read -p` / `read -sp` prompts for every
  answer. This is the path humans use.
- **Non-interactive (`--non-interactive`).** Every answer comes from a flag.
  Designed to be driven by automation (CI, an orchestrator agent, a Makefile
  in another repo). No prompts, no surprises — missing required flags exit 2
  with a clear message before any side effects fire.

## What it produces

```
<target-dir>/
├── backend/                FastAPI + Python 3.11 + Firestore
│   ├── Dockerfile          Multi-stage; EXPOSE matches --backend-port
│   ├── app/
│   │   ├── main.py         FastAPI app + /health endpoint
│   │   └── core/config.py  Pydantic Settings, env-driven
│   ├── requirements.txt
│   └── .env.example        Pre-filled with the right CORS / port
├── frontend/               React 19 + TS + Vite + Tailwind v3
│   ├── Dockerfile          nginx-served static build
│   ├── vite.config.ts      Proxies /api + /health to --backend-port
│   ├── package.json
│   └── src/                Hello-world Home page wired to /health
├── deploy.sh               One-shot prod deploy (backend + frontend + CORS)
├── deploy-staging.sh       Optional, only with --staging
├── run-local.sh            Local dev w/ optional cloudflared tunnel
├── fix_permissions.sh      Idempotent IAM repair script
├── CLAUDE.md               Generated for downstream Claude Code use
├── README.md               Per-project README
└── .gitignore
```

## Prerequisites

- `gcloud` CLI, authenticated. `gcloud auth login` once if you haven't.
- `git`.
- `gh` CLI is optional and only required if you pass `--create-github`.
- `bash` (works with macOS bash 3.2; no associative arrays, no `${var,,}`).

## Interactive usage

The default path. Run with no flags and follow the prompts:

```bash
./create-gcp-project.sh
```

Every prompt has a sensible default. `--skip-gcp` lets you generate the file
scaffold without touching GCP — useful for local-only dev or testing the
scaffolder.

```bash
./create-gcp-project.sh --skip-gcp
```

## Non-interactive usage

Pass `--non-interactive` plus every required flag:

```bash
./create-gcp-project.sh --non-interactive \
  --slug my-cool-app \
  --display-name "My Cool App" \
  --billing ABCD12-3456EF-789012 \
  --region us-central1 \
  --services openai,gemini \
  --staging \
  --create-github \
  --master-secrets-dir ~/.gcp-master-secrets \
  --backend-port 8080 \
  --frontend-port 5173
```

Run `./create-gcp-project.sh --help` for the full flag reference.

### Required flags in non-interactive mode

| Flag | Required? |
|---|---|
| `--slug <slug>` | always |
| `--display-name "<name>"` | always |
| `--billing <ID>` | unless `--skip-gcp` is also set |

### Optional flags

| Flag | Default | Notes |
|---|---|---|
| `--region <region>` | `us-central1` | |
| `--services <list>` | (none) | Comma-separated: `openai`, `openai-realtime`, `gemini`, `anthropic`, `resend`, `storage`. `openai-realtime` implies `openai`. |
| `--staging` / `--no-staging` | `--no-staging` | |
| `--create-github` / `--skip-github` | `--skip-github` | Requires `gh` on PATH. |
| `--master-secrets-dir <path>` | none | See below. |
| `--backend-port <int>` | `8080` | Used in `Dockerfile`, `run-local.sh`, vite proxy, `.env`s. |
| `--frontend-port <int>` | `5173` | Used in `run-local.sh`, vite, CORS defaults. |
| `--target-dir <path>` | `$PWD/<slug>` | |
| `--download-sa-key` / `--no-download-sa-key` | `--download-sa-key` (in non-interactive mode) | Replaces the existing "Download SA key now? (y/N)" prompt. |

## Master-secrets-dir convention

When `--master-secrets-dir <path>` is set, the script reads each needed API key
from a file under that directory instead of prompting via `read -sp`. The
mapping is:

| Service flag set | File the script reads |
|---|---|
| `--services openai` (or `openai-realtime`) | `<path>/openai-api-key` |
| `--services gemini` | `<path>/gemini-api-key` |
| `--services anthropic` | `<path>/anthropic-api-key` |
| `--services resend` | `<path>/resend-api-key` |

Each file should contain the raw API key, no quotes, no trailing newline
required. The script invokes:

```bash
gcloud secrets create <secret-name> \
  --data-file="<master-secrets-dir>/<secret-name>" \
  --replication-policy=automatic
```

If a needed key file is missing, the script exits 2 with a clear stderr
message — it refuses to half-provision the project.

In interactive mode the existing behavior is unchanged: `--master-secrets-dir`
just provides an alternative to typing keys at the `read -sp` prompt.

## Examples

### One-line non-interactive (production)

```bash
./create-gcp-project.sh --non-interactive \
  --slug acme-prism \
  --display-name "Acme Prism" \
  --billing ABCD12-3456EF-789012 \
  --services openai,resend,storage \
  --master-secrets-dir ~/.gcp-master-secrets \
  --staging --create-github
```

### File-only (no GCP, good for tests)

```bash
./create-gcp-project.sh --non-interactive \
  --slug demo-scaffold \
  --display-name "Demo Scaffold" \
  --billing FAKE \
  --skip-gcp \
  --target-dir /tmp/demo-scaffold \
  --skip-github --no-staging
```

## Idempotency

Re-running with the same flags is safe. Every `gcloud * create` call has an
"already exists" branch. The Artifact Registry creation has a built-in retry
loop because the API takes a few seconds to propagate after `services enable`.

## Testing

`test/smoke.sh` runs flag-parsing and file-generation smoke tests:

```bash
./test/smoke.sh
```

Coverage:

1. `--help` exits 0 and lists the flags.
2. `--non-interactive` alone exits non-zero with a "requires" error.
3. Invalid slug exits non-zero with a slug-validation error.
4. Full `--skip-gcp` file generation produces all expected files
   (`backend/`, `frontend/`, `run-local.sh`, etc.).
5. `--master-secrets-dir` + `--services` parses cleanly and scaffolds.
6. Empty `--master-secrets-dir` + `--services openai` exits 2 with a
   "missing key file" error (uses a stubbed `gcloud` so no real GCP calls
   fire).
7. Populated `--master-secrets-dir` invokes `gcloud secrets create` with
   `--data-file=<file>` (verified via the stub's invocation log).

The smoke tests clean up `/tmp/cgp-*` test dirs at the start of the run.
There's no Python framework — everything is plain bash assertions.
