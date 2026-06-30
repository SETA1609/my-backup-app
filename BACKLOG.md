# Backlog

Actionable tasks extracted from `PLANNING.md`. Prioritized to unblock downstream work.

---

## High Priority / Next Steps

The fastest path to something working end-to-end. Do these first.

- [ ] **Create `infra/providers.tf`** — AWS provider, region eu-central-1, required version
- [ ] **Create `infra/main.tf`** — S3 bucket, Intelligent-Tiering, CORS, SSE-KMS, public access block
- [ ] **Create `infra/iam.tf`** — IAM roles for Edge Functions (list/get/put/restore on hot/ + archive/)
- [ ] **Create `infra/variables.tf`**, `outputs.tf`, `terraform.tfvars.example`
- [ ] **Run `tofu init && tofu plan`** — verify no errors, no Glacier lifecycle rule on hot/
- [ ] **Create Supabase project** — enable magic links, invite 2 users (Sebastian + Mariangela)
- [ ] **Store AWS keys as Supabase Secrets** — AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, BUCKET_NAME

---

## Infrastructure (Terraform)

All files in `infra/`. Apply in order.

- [ ] `providers.tf` — AWS provider
- [ ] `main.tf` — S3 bucket, CORS, encryption, versioning, public access block
- [ ] `iam.tf` — Edge Function IAM role (list, get, put, restore on photos/*)
- [ ] `bundler.tf` — Go Bundler Lambda + EventBridge Scheduler cron rule + IAM role
- [ ] `notifications.tf` — SNS topic, SES template, notification Lambda + IAM role
- [ ] `variables.tf` — region, bucket name, project name, etc.
- [ ] `outputs.tf` — bucket ARN, function names, SNS topic ARN
- [ ] `terraform.tfvars.example` — committed template with placeholder values
- [ ] `infra/.gitignore` — *.tfstate, terraform.tfvars, .terraform/
- [ ] **Verify**: `tofu plan` shows correct resources, **no** lifecycle transition rule for hot/ → Glacier

---

## Backend (Supabase Edge Functions)

All functions in `supabase/functions/`. Each needs `index.ts` + `deno.json`.

- [ ] **`list-prefixes`** — list CommonPrefixes under hot/ + archive/, merge into unified album list, detect multi-part ZIPs (group by .partN)
- [ ] **`request-restore`** — accept album key, discover all parts, issue RestoreObjectCommand per part with Bulk tier, 7-day window
- [ ] **`get-download-urls`** — check x-amz-restore header per part, return presigned GET URLs for restored objects
- [ ] **`upload-file`** — JWT validation, presigned POST/PUT URL to photos/hot/YYYY/MM/
- [ ] **`delete-files`** — delete marker (soft) + version delete (permanent), warn for multi-part albums
- [ ] **Deploy all functions** — `supabase functions deploy` each one
- [ ] **Test each function** — curl with anon key, verify responses

---

## Frontend (React)

All UI in `src/` as `.tsx` files with Tailwind. No raw CSS.

- [ ] **Scaffold project** — `npm create vite@latest . -- --template react-ts`, install Tailwind, shadcn/ui, TanStack Query, Supabase client
- [ ] **`Login.tsx`** — email input, "Send magic link" button, "Check your email" state
- [ ] **`lib/supabase.ts`** — client init from VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY
- [ ] **`App.tsx`** — router setup, auth guard (redirect to login if no session)
- [ ] **`useAlbums.ts`** — TanStack Query hook calling list-prefixes Edge Function
- [ ] **`AlbumCard.tsx`** — display album name, date, size, hot/archive badge, multi-part "(3 parts)" label
- [ ] **`Albums.tsx`** — merged chronological album list with loading/error states
- [ ] **`PartList.tsx`** — expandable part list for multi-part albums with extraction instructions
- [ ] **`StatusBadge.tsx`** — "Restoring (12–48h)" → "Ready until July 7" → "Expired"
- [ ] **`useRestoreStatus.ts`** — poll get-download-urls every 30s until all parts restored
- [ ] **`RestoreButton.tsx`** — trigger restore with confirmation, show per-part progress
- [ ] **`DownloadList.tsx`** — per-part download buttons + "Download All"
- [ ] **`useRestoreSizeGuard.ts`** — estimate album size vs 100 GB monthly free egress
- [ ] **`SizeGuardBanner.tsx`** — yellow/red banner before restore, block if > 100 GB
- [ ] **`ActiveRestores.tsx`** — page showing in-progress and recently completed restores
- [ ] **Upload UI** — file picker, progress indicator, success toast
- [ ] **Delete UI** — confirmation modal with multi-part warning
- [ ] **Responsive design** — test on phone viewport, big touch targets

---

## Go Bundler Lambda

All code in `lambda/go-bundler/`. Runs monthly via EventBridge cron.

- [ ] **`main.go`** — list hot/ objects, filter older than 3 months, group by YYYY-MM
- [ ] **`splitter.go`** — streaming ZIP creation with multi-part splitting at MAX_PART_SIZE (default 10 GB)
- [ ] **Upload with DEEP_ARCHIVE** — PutObject with StorageClass: "DEEP_ARCHIVE" to archive/YYYY/
- [ ] **Checksum verification** — compare S3 ETag against local hash, abort if mismatch
- [ ] **Safe deletion** — delete originals from hot/ only after all parts verified
- [ ] **`go.mod`** + dependency tidy
- [ ] **`Makefile`** — build, test, package (GOOS=linux GOARCH=amd64 go build → zip function.zip)
- [ ] **Unit tests** — splitter logic, date filtering, dry-run mode
- [ ] **Local dry-run test** — `go run main.go -dry-run` with sample data

---

## Nice to Have / Later

Post-PoC enhancements. Not needed for the initial working app.

- [ ] Folder upload via webkitdirectory
- [ ] Background upload progress + resumable uploads
- [ ] Email notification when restore completes (SNS → Go Lambda → SES)
- [ ] Client-side encryption option (rclone crypt or Web Crypto)
- [ ] Dark mode + extra-large touch buttons
- [ ] Settings page (restore days, default tier, max part size)
- [ ] "Recently Restored" sidebar section
- [ ] Per-user egress tracking in Supabase (instead of localStorage)
- [ ] Expo/React Native mobile app for better upload experience
- [ ] Go notification Lambda with SES HTML template (replace plain SNS email)
- [ ] ZIP password protection for monthly archives
