# Development Guide

How to set up, run, and deploy the backup app.

---

## Prerequisites

| Tool | Version | Why |
|------|---------|-----|
| [Bun](https://bun.sh) | 1.x | JavaScript runtime + package manager (faster than Node) |
| [Docker](https://docker.com) + Compose | Latest | Dev container for React hot-reload |
| [Terraform](https://terraform.io) | >= 1.6 | Infrastructure as Code (or [OpenTofu](https://opentofu.org) 1.6+) |
| [Supabase CLI](https://supabase.com/docs/guides/cli) | Latest | Local Edge Function dev + deployment |
| [Go](https://go.dev) | >= 1.22 | Building the bundler Lambda |
| [AWS CLI](https://aws.amazon.com/cli/) | Latest | Manual S3 debugging |
| Node.js | >= 20 | Fallback if not using Bun |

Verify everything:

```bash
bun --version   # 1.x
docker --version
tofu version       # or terraform version
supabase --version
go version
```

---

## Project Setup

Clone and install:

```bash
git clone git@github.com:SETA1609/my-backup-app.git
cd my-backup-app
bun install
```

This installs all frontend dependencies (React, Tailwind, TanStack Query, Supabase client, etc).

---

## Local Development

### Option A: Docker (recommended for consistent environment)

The dev container uses Bun with hot reload:

```bash
docker compose up
```

- React app at `http://localhost:5173`
- Source files are mounted — changes trigger instant HMR
- `node_modules` lives inside the container (not on your host)

To run commands inside the container:

```bash
docker compose exec app bun run test
docker compose exec app sh
```

### Option B: Direct (no Docker)

```bash
bun run dev
```

This uses your host machine's Bun. Same URL: `http://localhost:5173`.

### Environment Variables

The React app needs these at build time:

```env
# .env.local (never committed)
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

Copy the example if it exists:

```bash
cp .env.local.example .env.local  # if available
```

The app reads these at build time. In development, Vite serves them to the browser. In production, GitHub Actions injects them as secrets.

---

## Terraform Workflow

All infrastructure lives in `infra/` and is managed with Terraform (or OpenTofu).

### Setup

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your real values:
#   aws_region, bucket_name, supabase_project_id, etc.
```

### Commands

```bash
# Initialize (download providers, set up backend)
tofu init

# Preview changes
tofu plan

# Apply changes
tofu apply

# Destroy everything (careful!)
tofu destroy
```

### What Terraform manages

See `infra/` — each `.tf` file covers one domain:

| File | Resources |
|------|-----------|
| `main.tf` | S3 bucket, Intelligent-Tiering config, CORS, encryption, public access block |
| `bundler.tf` | Go Bundler Lambda + EventBridge Scheduler cron rule |
| `notifications.tf` | SNS topic, SES template, notification Lambda |
| `iam.tf` | IAM roles for Edge Functions, bundler Lambda, notification Lambda |
| `providers.tf` | AWS provider config |
| `variables.tf` | All input variables |
| `outputs.tf` | Useful outputs (bucket ARN, Lambda ARNs, etc.) |

### Secrets & Credentials

- **Never commit** `terraform.tfvars`, `*.tfstate`, `.terraform/`, or any file containing real keys
- `terraform.tfvars.example` is the committed template — fill in local values and keep them local
- AWS keys for Supabase Edge Functions are stored as **Supabase Secrets** (Settings → Edge Functions → Secrets), never in this repo
- State can be stored locally (for PoC) or in an encrypted S3 backend

### Important: No Lifecycle Transition to Glacier

The Terraform config must **not** include a lifecycle rule that transitions `hot/` objects to Glacier Deep Archive. Objects in `hot/` use only S3 Intelligent-Tiering (no minimum duration). The Go Bundler Lambda uploads bundled ZIPs **directly** to Glacier Deep Archive with `StorageClass: "DEEP_ARCHIVE"`.

---

## Supabase Development

### Local Edge Function Development

```bash
# Start Supabase local stack (Docker-based)
supabase start

# List running services
supabase status

# Create a new Edge Function
supabase functions new request-restore

# Serve functions locally with hot reload
supabase functions serve --env-file ./supabase/.env.local
```

Functions are served at `http://localhost:54321/functions/v1/`.

### Local Environment Variables

```bash
# supabase/.env.local (never committed)
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
AWS_REGION=eu-central-1
BUCKET_NAME=your-backup-bucket
```

### Deploy Edge Functions

```bash
# Deploy a single function
supabase functions deploy request-restore

# Deploy all functions
supabase functions deploy --project-ref your-project-ref list-prefixes
supabase functions deploy --project-ref your-project-ref request-restore
supabase functions deploy --project-ref your-project-ref get-download-urls
supabase functions deploy --project-ref your-project-ref upload-file
supabase functions deploy --project-ref your-project-ref delete-files
```

### Set Supabase Secrets (AWS credentials)

```bash
# These must be set once — the Edge Functions use them to call S3
supabase secrets set --project-ref your-project-ref \
  AWS_ACCESS_KEY_ID=your-key \
  AWS_SECRET_ACCESS_KEY=your-secret \
  AWS_REGION=eu-central-1 \
  BUCKET_NAME=your-backup-bucket
```

### Enable Magic Link Auth

1. Go to your Supabase dashboard → Authentication → Providers
2. Enable "Email" and turn on "Magic Link"
3. Optionally disable password-based login (we only use magic links)

### Test an Edge Function

```bash
# With the local server running:
curl -X POST http://localhost:54321/functions/v1/list-prefixes \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json"

# Or use the Supabase CLI:
supabase functions serve --env-file ./supabase/.env.local &
# Then call from another terminal
curl http://localhost:54321/functions/v1/list-prefixes
```

---

## Go Bundler Lambda

### Directory Structure

```
lambda/go-bundler/
├── main.go          # Entry point: scan hot/, group by month, ZIP, upload, verify, delete
├── splitter.go      # Multi-part splitting logic (> 10 GB months)
├── go.mod
└── Makefile         # build → test → package for Lambda
```

### Local Development

```bash
cd lambda/go-bundler

# Run tests
go test ./...

# Build for Lambda
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go splitter.go
zip function.zip bootstrap

# Test locally with sample data
go run main.go -dry-run -bucket your-bucket -prefix photos/hot/
```

### What the Bundler Does

1. Lists objects under `photos/hot/` older than 3 months
2. Groups them by `YYYY-MM`
3. Streams each group into a ZIP archive using `archive/zip`
4. If total size > `MAX_PART_SIZE` (default 10 GB), splits into `name.part1.zip`, `name.part2.zip`, etc.
5. Uploads each part to `photos/archive/YYYY/` with `StorageClass: "DEEP_ARCHIVE"`
6. Verifies checksums against S3 ETags
7. Deletes original files from `photos/hot/` (Intelligent-Tiering — no early deletion fee)
8. Logs everything to CloudWatch

### IAM Permissions (Terraform-managed)

The bundler Lambda gets least-privilege access:

- `s3:ListBucket` on the backup bucket
- `s3:GetObject` on `photos/hot/*`
- `s3:PutObject` on `photos/archive/*` (uploads with `DEEP_ARCHIVE`)
- `s3:DeleteObject` on `photos/hot/*` (only after checksum verification)
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

### Testing the Bundler Locally

```bash
# Simulate what the Lambda does, without touching S3
cd lambda/go-bundler
mkdir -p /tmp/test-hot/2026/01 /tmp/test-hot/2026/02
echo "test file" > /tmp/test-hot/2026/01/photo1.jpg
echo "test file 2" > /tmp/test-hot/2026/02/photo2.jpg

# Run the bundler in dry-run mode (log what it would do)
go run main.go -source /tmp/test-hot -dry-run

# Or test with an actual S3 bucket (needs AWS credentials)
AWS_PROFILE=my-backup go run main.go -bucket your-backup-bucket
```

### Deploying the Bundler

The bundler is deployed via Terraform. After building the ZIP:

```bash
cd lambda/go-bundler
make build    # creates function.zip

# Then from infra/:
cd ../../infra
tofu apply    # Terraform picks up the new ZIP and deploys the Lambda
```

The EventBridge Scheduler cron triggers it automatically on the 1st of each month at 3:00 AM UTC.

---

## React App (Frontend)

### Directory Structure

```
src/
├── components/      # Reusable UI (.tsx files with Tailwind only)
│   ├── AlbumCard.tsx
│   ├── RestoreButton.tsx
│   ├── StatusBadge.tsx
│   ├── PartList.tsx
│   ├── SizeGuardBanner.tsx
│   └── DownloadList.tsx
├── hooks/           # Custom React hooks
│   ├── useAlbums.ts
│   ├── useRestoreStatus.ts
│   ├── useRestoreSizeGuard.ts
│   └── useSupabase.ts
├── lib/             # Non-React utilities
│   ├── styles.ts    # Reusable Tailwind class patterns
│   ├── supabase.ts  # Supabase client
│   └── types.ts     # Shared TypeScript types
├── pages/           # Route-level pages
│   ├── Login.tsx
│   ├── Albums.tsx
│   └── ActiveRestores.tsx
├── App.tsx
└── main.tsx
```

### Styling Rules

- **All styling** in Tailwind utility classes inside `.tsx` files — no raw CSS
- No `<style>` tags in components
- Reusable class patterns go in `src/lib/styles.ts`
- Use the `cn()` helper (`clsx` + `tailwind-merge`) for conditional classes
- The only CSS file is `src/index.css` with the three Tailwind directives

### Key Hooks

| Hook | Purpose |
|------|---------|
| `useAlbums()` | Fetches merged hot + archive album list via `list-prefixes` Edge Function |
| `useRestoreStatus(albumId)` | Polls restore status for an album (all parts) |
| `useRestoreSizeGuard(sizeBytes)` | Checks if album size exceeds 100 GB monthly free egress |
| `useSupabase()` | Returns the Supabase client |

### Frontend Guard (100 GB Monthly Egress)

Before restoring, the app warns if:

- **< 10%** of monthly limit: No warning
- **10–80%**: Yellow banner — "This album is 25 GB (25% of your monthly free limit)"
- **> 80%**: Red banner + confirmation dialog
- **> 100%**: Restore button disabled — "Contact the technical user to plan a staggered restore"

A running total of restored size this month is stored in `localStorage`.

---

## Testing

### Unit & Integration (Vitest)

```bash
bun run test           # single run
bun run test:watch     # watch mode
```

Tests are co-located or in `src/__tests__/`. They mock Edge Functions and test hooks/components in isolation.

### End-to-End (Playwright)

```bash
bun run test:e2e          # headless
bun run test:e2e:ui       # with Playwright UI
```

E2E tests cover:
- Magic link login flow
- Album listing (hot + archive merged)
- Multi-part album display
- Restore trigger + status polling
- Download buttons for restored parts
- Upload flow

### Testing Restore Flows Manually

1. Open the app and log in via magic link
2. Navigate to an archive album (older than 3 months)
3. Click "Restore" — the frontend guard shows a warning if > 10 GB
4. Confirm — the Edge Function calls `RestoreObjectCommand` with Bulk tier
5. Watch status polling: "Restoring… 1 of 3 parts ready" → "Ready"
6. Download each part (or "Download All")
7. Extract `part1.zip` — the OS automatically combines all parts

To speed up testing, you can use Expedited tier instead of Bulk during development (change the Tier parameter in `request-restore`).

### Testing Multi-Part Albums

1. Upload enough files to exceed 10 GB in a month (or simulate with the bundler's `-max-part-size` flag)
2. Trigger the bundler: `go run main.go -source /tmp/test-hot -max-part-size 10485760` (10 MB for testing)
3. Verify the archive prefix has `.part1.zip`, `.part2.zip`, etc.
4. In the app, verify the album shows "(3 parts)" with individual download buttons
5. Test the extraction instructions: download part1 only → verify it prompts for part2

---

## Deployment

### Frontend (GitHub Pages)

Pushed automatically by the GitHub Actions workflow in `.github/workflows/deploy.yml` on every push to `main`.

The workflow:
1. Checks out the repo
2. Sets `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` from GitHub Secrets
3. Runs `bun install && bun run build`
4. Deploys `dist/` to GitHub Pages

### Edge Functions

```bash
# Deploy after testing locally
supabase functions deploy list-prefixes --project-ref your-project-ref
supabase functions deploy request-restore --project-ref your-project-ref
supabase functions deploy get-download-urls --project-ref your-project-ref
supabase functions deploy upload-file --project-ref your-project-ref
supabase functions deploy delete-files --project-ref your-project-ref
```

### Go Bundler Lambda

Deployed via Terraform. After changes:

```bash
cd lambda/go-bundler
make build
cd ../../infra
tofu apply
```

### Notifications Lambda

```bash
cd lambda/go-notification
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go
zip function.zip bootstrap
# Terraform picks this up during apply
cd ../../infra
tofu apply
```

---

## Common Commands

```bash
# ── Frontend ──
bun install              # Install dependencies
bun run dev              # Start Vite dev server
bun run build            # Production build
bun run preview          # Preview production build
bun run test             # Vitest (unit + integration)
bun run test:watch       # Vitest watch mode
bun run test:e2e         # Playwright E2E

# ── Docker ──
docker compose up        # Start dev container (Bun + hot reload)
docker compose exec app bun add some-package   # Install a package inside container
docker compose down      # Stop container

# ── Terraform ──
cd infra
tofu init                # Initialize providers
tofu plan                # Preview changes
tofu apply               # Apply changes
tofu destroy             # Destroy everything (careful!)
cd ..

# ── Supabase ──
supabase start           # Start local Supabase
supabase status          # Check local services
supabase functions new list-prefixes   # Create a new Edge Function
supabase functions serve --env-file ./supabase/.env.local  # Serve locally
supabase functions deploy list-prefixes --project-ref your-project-ref
supabase secrets set AWS_ACCESS_KEY_ID=... --project-ref your-project-ref

# ── Go Bundler Lambda ──
cd lambda/go-bundler
go mod tidy              # Tidy dependencies
go test ./...            # Run tests
go run main.go -dry-run  # Dry run (log only, no S3 mutations)
make build               # Build + ZIP for Lambda
cd ../..

# ── Git ──
git checkout planning    # Switch to planning branch
git log --oneline -10    # Recent commits
git diff PLANNING.md     # Uncommitted changes
```

---

## Troubleshooting

### "VITE_SUPABASE_URL is not defined"

Create a `.env.local` file with the required variables:

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

### Edge Function returns 401

The JWT is missing or expired. Make sure you're passing a valid Supabase anon key or user JWT in the `Authorization` header.

### CORS errors in the browser

The S3 bucket's CORS config must allow the GitHub Pages origin. For local development, allow `http://localhost:5173`. Update in `infra/main.tf`:

```hcl
allowed_origins = ["http://localhost:5173", "https://yourusername.github.io"]
```

Then `tofu apply`.

### Bundler Lambda times out

Large months (> 10 GB) may need increased Lambda timeout and memory. Adjust in `infra/bundler.tf`:

```hcl
timeout = 300   # 5 minutes
memory_size = 1024  # 1 GB
```

### "Go build" fails on Lambda ZIP

Make sure you're cross-compiling for Linux:

```bash
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go
```

The binary must be named `bootstrap` for the Lambda custom runtime to find it.

### Docker container exits immediately

The `node_modules` volume mount might be stale. Rebuild:

```bash
docker compose down -v
docker compose up --build
```

### Multi-part extraction doesn't work on macOS

macOS Archive Utility can handle split ZIPs, but some third-party tools (The Unarchiver, Keka) work better. The UI instructs users to extract `part1.zip` — the OS should prompt for subsequent parts automatically.

---

## Architecture at a Glance

```
User (browser)
  │
  ▼
React SPA (GitHub Pages)  ─── Supabase Auth (magic link)
  │                              │
  ▼                              ▼
Supabase Edge Functions ─── AWS S3
  │                              │
  │                   ┌──────────┴──────────┐
  │                   ▼                     ▼
  │            hot/ (Intelligent-Tiering)  archive/ (Glacier Deep Archive)
  │                   │                     ▲
  │                   │     Go Bundler      │
  │                   └───── Lambda ────────┘
  │                     (monthly cron)
  │
  ▼
Download ZIP(s) ← presigned URLs from Edge Functions
```

For the full architecture, data flow, and rationale, see `PLANNING.md` and `docs/architecture.md`. For React conventions and testing strategy, see `docs/react-style.md`.
