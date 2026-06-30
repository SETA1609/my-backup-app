# Proof of Concept (PoC): Family Backup App
## React + GitHub Pages + Supabase + S3 Glacier (Terraform-managed)

**Project Goal**: Build a minimal-cost, secure, wife-friendly web application to browse, restore (Bulk tier), and download photos/documents from Amazon S3 **Glacier Deep Archive** (the cheapest storage class). The app must be completely free to host and operate within generous free tiers while keeping monthly retrieval costs near zero. Restores take longer (~12–48 hours with Bulk) — this is an accepted trade-off for the lowest possible storage cost.

**Date**: June 2026  
**Status**: PoC Planning / Ready to implement  
**Target Users**: Sebastian (technical) + Mariangela (non-technical)

**Key Principles**:
- Everything is defined in code (Infrastructure as Code + components in TSX)
- **Zero credentials or secrets committed to the repository**
- All UI declared in `.tsx` / `.ts` files (Tailwind utility classes inside components)
- No raw `<style>` tags or separate raw CSS files beyond minimal Tailwind directives

---

## 1. Executive Summary

We will create a **React single-page application** hosted for **free on GitHub Pages** that allows easy access to cold backups stored in **S3 Glacier Deep Archive** (the absolute cheapest long-term storage class). Restores use the Bulk tier and typically become available in 12–48 hours.

All sensitive AWS operations are proxied through **Supabase Edge Functions** (free tier) so that:
- No AWS credentials ever reach the browser
- Supabase Auth (magic links) provides simple, passwordless login for both users
- The app works on any modern browser (phone, tablet, laptop)

**Hybrid Data Lifecycle**: Recent data (current year + previous year) stays as individual files in a `hot/` prefix for easy browsing and selective restore. Older data is **automatically bundled** by a **Go Lambda** triggered by **EventBridge Scheduler** (cron) into **monthly ZIP archives** stored in an `archive/` prefix. If a month's data exceeds a configurable part size (recommended 10 GB), the Lambda **auto-splits** it into numbered parts (`.part1.zip`, `.part2.zip`, etc.). A **frontend guard** in the React app warns before restoring if the album would consume a large portion of the 100 GB monthly free egress limit. No manual intervention needed once deployed.

**Key Wins**:
- Hosting cost: **$0**
- Backend cost: **$0** (Supabase free tier easily covers 2 users)
- Retrieval cost: **~$0–2/month** for up to 100 GB Bulk restores (Deep Archive)
- Storage: **~$0.00099/GB/month** (~$1/TB/month) — the cheapest AWS offers
- UX: Simple, big-button interface designed for non-technical use. Old albums restore as **ZIP download(s)** — split into reasonable parts, with clear instructions
- Object count reduction: **~90–99% fewer objects** after bundling, drastically reducing API request costs and metadata overhead
- Fully automated: EventBridge cron runs the Go Bundler Lambda once per month — zero manual work after initial setup
- Frontend guard: Users are warned before exceeding the 100 GB monthly free egress threshold

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Pages (Free)                      │
│  ┌─────────────────────────────────────────────────────┐    │
│  │         React SPA (Vite + TypeScript + TSX)         │    │
│  │  • All UI declared in .tsx files (Tailwind only)    │    │
│  │  • Magic-link login (Supabase)                      │    │
│  │  • Album browser (hot/ + archive/ merged)           │    │
│  │  • "Restore Album (Bulk, ~48h)" buttons             │    │
│  │  • Status polling + ready downloads (ZIP parts)     │    │
│  │  • Frontend guard: warns if restore > 100 GB limit  │    │
│  │  • Multi-part album: "3 of 3 parts" + instructions  │    │
│  │  • Simple file/folder upload                        │    │
│  └──────────────────────┬──────────────────────────────┘    │
└─────────────────────────┼───────────────────────────────────┘
                          │ HTTPS + Supabase JWT
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                     Supabase (Free Tier)                    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Auth (Email Magic Links + JWT)                     │    │
│  │  Edge Functions (TypeScript / Deno)                 │    │
│  │    ├── request-restore.ts      (Bulk tier)          │    │
│  │    ├── get-download-urls.ts    (presigned URLs)     │    │
│  │    ├── list-prefixes.ts        (albums from both    │
│  │    │                   hot/ + archive/, incl. parts)│    │
│  │    ├── upload-file.ts          (presigned POST)     │    │
│  │    └── delete-files.ts   (Delete Marker + permanent)│    │
│  │  Secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  │    │
│  │            (never in Git repo)                      │    │
│  └──────────────────────┬──────────────────────────────┘    │
└─────────────────────────┼───────────────────────────────────┘
                          │ AWS SDK calls (server-side only)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│         AWS S3 + IAM (eu-central-1) — Terraform managed     │
│  • Bucket with Glacier Deep Archive lifecycle               │
│  • Prefix strategy: photos/hot/  +  photos/archive/YYYY/    │
│  • Versioning + SSE-KMS encryption                          │
│  • Public access blocked                                    │
│  • CORS locked to GitHub Pages origin                       │
│  • Least-privilege IAM user/role for Edge Functions only    │
│  • All resources defined in infra/ (no manual console work) │
└──────────┬──────────────────────────────────────────────────┘
           │
           │  Automated (EventBridge Scheduler cron)
           ▼
┌─────────────────────────────────────────────────────────────┐
│   Go Bundler Lambda (EventBridge Scheduler cron)            │
│  • Trigger: cron(0 3 1 * ? *) — 1st of each month at 3 AM  │
│  • Scans photos/hot/ for data older than 24 months          │
│  • Groups by YYYY-MM, creates monthly ZIP archives          │
│  • Auto-splits: if ZIP > MAX_PART_SIZE (10 GB default),     │
│    splits into name.part1.zip, name.part2.zip, ...          │
│  • Uploads part(s) to photos/archive/YYYY/                  │
│  • Verifies checksums, then deletes original files          │
│  • Logs results to CloudWatch                               │
│  • Source in lambda/go-bundler/                              │
└─────────────────────────────────────────────────────────────┘
```

**Data Flow Highlights**:
1. Wife clicks magic link → instantly logged in via Supabase Auth
2. App calls Edge Function `list-prefixes` → merges `hot/` folders + `archive/` monthly ZIPs (including multi-part) into a unified album view
3. Before restoring, frontend guard checks estimated size vs 100 GB monthly free egress → shows warning if approaching limit
4. She clicks **"Restore Summer 2025 Photos (Free, ~48 hours)"**
5. For archive data: Edge Function calls `s3.restoreObject({ Tier: "Bulk" })` on **each part** of the album
6. App polls `get-download-urls` every 30–60s until all parts show `ongoing-request="false"`
7. Presigned `GET` URLs are returned for each part — user downloads **one part at a time** or all at once
8. Multi-part albums show clear instructions: "This album has 3 parts. Download all parts and unzip the first one to extract the full album."
9. For hot data: individual files can be restored and downloaded selectively
10. Uploads go through Edge Function → presigned POST to S3 (`photos/hot/` prefix → lifecycle transitions to Glacier)
11. Go Bundler Lambda runs on a cron schedule, automatically bundling old data into monthly ZIPs and splitting large months — no manual action required

---

## 2.1 Infrastructure as Code (Terraform)

All AWS resources are defined in the `infra/` directory using Terraform. This guarantees:

- Reproducible, version-controlled infrastructure
- No manual clicks in the AWS Console
- Easy teardown or recreation
- Clear documentation of what exists

**What Terraform manages**:
- S3 bucket + versioning + encryption + public access block
- Lifecycle policy (Standard/Intelligent-Tiering → Glacier Deep Archive)
- CORS configuration (locked to GitHub Pages origin)
- IAM user + policy (least privilege — only for Supabase Edge Functions)
- **Go Bundler Lambda + EventBridge Scheduler rule** (cron trigger)
- Notification Lambda + SNS topic + SES resources
- Optional: S3 Inventory or EventBridge rules later

**Secrets & Credentials Policy (Strict)**:
- **Never commit** `terraform.tfvars`, `*.tfstate`, or any file containing keys
- Use `infra/terraform.tfvars.example` (committed) + local `terraform.tfvars` (gitignored)
- AWS access keys for Edge Functions live **only** in Supabase Secrets
- GitHub Actions uses OIDC or short-lived role assumption (recommended) or GitHub Secrets (never in code)
- Terraform state can be stored locally for PoC or in an S3 backend (encrypted)

**Recommended structure**:
```
infra/
├── main.tf                    # S3 bucket, lifecycle, CORS, public access block
├── bundler.tf                 # Go Bundler Lambda + EventBridge Scheduler rule
├── notifications.tf           # SNS, SES, notification Lambda
├── iam.tf                     # IAM roles & policies (Edge Functions + Lambdas)
├── variables.tf
├── outputs.tf
├── providers.tf
├── terraform.tfvars.example
└── .gitignore                 # *.tfstate, terraform.tfvars, .terraform/
```

This approach keeps the entire project (app + infra) fully defined in code and auditable.

## 3. Technology Stack (Chosen for Speed + Maintainability)

| Layer                  | Technology                                      | Reason |
|------------------------|--------------------------------------------------|--------|
| Frontend               | Vite + React 19 + TypeScript + TSX              | All UI declared in `.tsx` files. No raw HTML/CSS outside components |
| Styling                | Tailwind CSS (utility classes inside TSX)       | Co-located styling, no separate raw `.css` files |
| UI Components          | shadcn/ui (or Radix + Tailwind)                 | Accessible, beautiful, fully typed in TSX |
| State                  | TanStack Query (React Query)                    | Excellent caching + polling for restore status across multiple parts |
| Auth & Backend         | Supabase (Auth + Edge Functions)                | Magic links, free generous tier, great DX |
| Hosting                | GitHub Pages + GitHub Actions                   | Completely free, automatic deploys |
| Infrastructure         | Terraform (in `infra/` directory)               | S3 bucket, IAM, CORS, lifecycle — everything as code |
| AWS                    | S3 + Glacier Deep Archive                       | Absolute cheapest cold storage (Bulk restores ~12–48h) |
| AWS SDK                | `@aws-sdk/client-s3` (in Edge Functions only)   | Server-side only, never in browser |
| File Handling          | Web File API + presigned URLs                   | Works in all modern browsers |
| Automated Bundling     | Go Lambda + EventBridge Scheduler cron          | Fully automated, zero-touch monthly ZIP creation |
| ZIP Splitting          | Go + `archive/zip` (streaming, multi-part)      | Built-in, no external deps; splits at configurable max part size |
| Cron Schedule          | EventBridge Scheduler (rate-based or cron)      | Free tier, fully managed, Terraform-managed |
| Frontend Guard         | React hook + `useRestoreSizeGuard`              | Estimates album size vs 100 GB monthly free egress before restore |

**Why not Next.js / Vercel?**  
GitHub Pages is truly free with zero limits for this use case. We keep the backend 100% in Supabase Edge Functions.

---

## 4. Core Features (MVP Scope for PoC)

### Must Have (PoC Success Criteria)
- [ ] Supabase project with Auth (magic links enabled) + 2 test users
- [ ] 3–4 Edge Functions deployed and working
- [ ] React app with magic-link login + session persistence
- [ ] Browse S3 prefixes presented as nice "Albums" (e.g. `photos/2025/06-summer-trip`)
- [ ] One-click **Bulk Restore** request for an album/prefix (clearly shows "~48 hours / up to 2 days")
- [ ] Live status: "Restoring… (est. 12–48 hours)" → "Ready until July 7"
- [ ] Download — **ZIP file(s) per album**; multi-part albums show numbered parts
- [ ] Frontend guard: size estimation + warning before restore if approaching 100 GB monthly free egress limit
- [ ] Multi-part album UI: clear "Part X of Y" labels + instructions
- [ ] Basic upload of new photos/documents from browser (lands in `hot/` prefix)
- [ ] Responsive design that works well on phone
- [ ] Deployed on GitHub Pages (public repo or private with Pro)
- [ ] End-to-end test: upload → lifecycle to Glacier → restore via UI → download
- [ ] Go Bundler Lambda deployed + EventBridge Scheduler cron rule created via Terraform
- [ ] `list-prefixes` Edge Function merges both `hot/` and `archive/` into one unified album view

### Nice to Have (Post-PoC)
- Folder upload (webkitdirectory)
- Background upload progress + resumable uploads
- Email notification when restore completes (via SNS + Edge Function)
- Client-side encryption option (rclone crypt or Web Crypto)
- Dark mode + very large touch-friendly buttons for wife
- Simple settings page (restore days, default tier, max part size config)

---

## 5. Security Model (Non-Negotiable)

1. **Zero credentials or secrets in the Git repository** — No AWS keys, Supabase service role keys, or Terraform state with secrets are ever committed.
2. **Zero AWS credentials in browser** — All S3/Glacier calls happen **only** inside Supabase Edge Functions. AWS keys live exclusively as Supabase Secrets.
3. **JWT validation on every request** — Every Edge Function verifies the Supabase JWT before performing any AWS action.
4. **Least-privilege IAM (Terraform-managed)** — Each AWS component gets its own scoped IAM role:
   - **Edge Functions IAM**: `s3:ListBucket`, `s3:GetObject`, `s3:RestoreObject`, `s3:PutObject` on allowed paths only. No delete, no admin.
   - **Go Bundler Lambda IAM**: `s3:ListBucket`, `s3:GetObject` on `hot/` prefix, `s3:PutObject` on `archive/` prefix, `s3:DeleteObject` on `hot/` prefix only (after checksum verification). No access to any other bucket.
   - **Notification Lambda IAM**: `sns:Receive`, `ses:SendTemplatedEmail`, CloudWatch logs only.
5. **Short-lived presigned URLs** — Downloads expire in 15–60 minutes.
6. **HTTPS + modern TLS** everywhere.
7. **S3 hardening (defined in Terraform)**:
   - Block all public access
   - Versioning enabled
   - Default encryption (SSE-KMS)
   - Lifecycle policy (Standard → Glacier Deep Archive after 90 days)
8. **CORS** strictly limited to the GitHub Pages origin (+ localhost for development).
9. **Bundler Lambda runs with limited permissions** — The Go Bundler Lambda has no access to Edge Function secrets, Supabase, or any other AWS service beyond S3 and CloudWatch logs.

---

## 6. Cost Analysis (Deep Archive — Cheapest Option)

With monthly ZIP bundling, the number of objects in Glacier Deep Archive drops by **~90–99%**. This has a dramatic impact on API request costs and metadata overhead. Size-based splitting does not increase costs meaningfully — one extra `RestoreObjectCommand` per part is negligible.

| Item                                   | Estimated Monthly Cost          | Notes |
|----------------------------------------|---------------------------------|-------|
| GitHub Pages                           | **$0**                          | Public repo (or $4 if private) |
| Supabase (Auth + Edge Functions)       | **$0**                          | 2 users, < 10k invocations/mo easily inside free tier |
| S3 Storage (Glacier Deep Archive)      | **~$0.00099/GB**                | e.g. 1 TB = ~$0.99/mo |
| Bulk Retrieval (100 GB)                | **~$0.25**                      | $0.0025/GB for Deep Archive Bulk |
| Temporary restored objects (7 days)    | ~$0.023/GB × 100 GB × 7/30      | ~$0.50–0.80 |
| S3 API requests (LIST/GET/PUT)         | **~$0.01–0.05**                 | Negligible thanks to bundled objects |
| Go Bundler Lambda (1 invocation/mo)    | **$0**                          | Inside Lambda free tier (1M requests) |
| EventBridge Scheduler (1 rule)         | **$0**                          | Inside free tier (14 free rules) |
| **Total extra cost beyond storage**    | **Under $2**                    | Even with monthly restores |

**First 100 GB egress per month is free** across AWS → downloads are essentially free. The frontend guard helps users stay within this limit.

**Yearly storage prognosis with bundling (steady state)**:
- 100 GB → **≈ $1.20 / year**
- 500 GB → **≈ $6 / year**
- 1 TB   → **≈ $12 / year**

**Cost comparison: unbundled vs bundled (1 TB, 500,000 small files)**:
- Without bundling: ~$5–10/year in LIST/GET request costs alone + metadata overhead
- With monthly ZIP bundling: ~$0.50–1/year in request costs + same storage cost
- **Savings**: ~$5–9/year in API costs (grows with object count)

**Splitting overhead**: A 50 GB month split into 5 parts = 5 `RestoreObjectCommand` calls instead of 1. At $0.0025/GB for Bulk, the cost difference is ~$0.0003 — effectively zero.

This is the lowest possible cost on AWS for long-term archival. The only trade-off is restore time (Bulk = typically 12–48 hours).

---

## 7. Recommended S3 Bucket Configuration (Cheapest Path)

- **Region**: `eu-central-1` (Frankfurt) — lowest latency from Hamburg + GDPR friendly
- **Bucket name**: `family-backup-sebastian-2026` (or similar)
- **Prefix strategy**:
  - `photos/hot/` — Recent data (current year + previous year). Files stored individually for easy browsing and selective restore. Default upload target. The Go Bundler Lambda scans this prefix.
  - `photos/archive/YYYY/` — Bundled monthly ZIPs for data older than ~24 months. Single ZIP or multi-part: `2024-03-March.part1.zip`, `2024-03-March.part2.zip`, etc.
  - `photos/_bundled/` — Temporary safety copy of original files after bundling (optional, lifecycle-managed).
  - Rationale: Clear separation makes lifecycle rules, IAM policies, and the bundler Lambda simpler and more secure.
- **Naming convention for split archives**:
  - Single ZIP: `YYYY-MM-name.zip` (e.g. `2024-03-March.zip`)
  - Multi-part: `YYYY-MM-name.part1.zip`, `YYYY-MM-name.part2.zip`, etc.
  - The Lambda uses a configurable `max_part_size` (default 10 GB) as the threshold.
- **Lifecycle rule** (Terraform-managed):
  - Objects in `photos/hot/` → S3 Intelligent-Tiering (Frequent Access) immediately
  - After 90 days → Transition to **Glacier Deep Archive** (cheapest class)
  - Objects in `photos/archive/` → Transition directly to Glacier Deep Archive on upload (already bundled)
  - Objects in `photos/_bundled/` → Expire after 30 days (safety net, then auto-cleanup)
  - Or use Intelligent-Tiering with **Deep Archive Access** tier enabled (recommended "set & forget" option)
- **Versioning**: Enabled (protects against accidental deletes)
- **Encryption**: SSE-KMS (AWS managed key is fine)
- **Public access**: Blocked
- **CORS**: Allow `GET`, `PUT`, `POST` from your GitHub Pages domain + `localhost:5173`

---

## 8. Edge Functions Specification (What We Need to Build)

All functions live in `supabase/functions/` and are called via `supabase.functions.invoke()`.

### `list-prefixes`
- Lists common prefixes under both `photos/hot/` and `photos/archive/YYYY/`
- Returns a merged view of albums with metadata:
  - For hot data: folder name, file count, total size, type: `"hot"`
  - For archive data: album name, total size (sum of all parts), type: `"archive"`, `parts: [{ fileName, size, partNumber }]`
- Supports depth filtering (year → month → album)
- Detects multi-part albums by grouping `.partN.zip` files under a common base name

```typescript
// Merged response with multi-part support
[
  { id: "hot/2026",       name: "2026",          type: "hot",     fileCount: 342,  totalSize: "1.2 GB" },
  { id: "archive/2024",   name: "March 2024",    type: "archive", totalSize: "28.5 GB", parts: [
    { fileName: "2024-03-March.part1.zip", size: "10 GB", partNumber: 1 },
    { fileName: "2024-03-March.part2.zip", size: "10 GB", partNumber: 2 },
    { fileName: "2024-03-March.part3.zip", size: "8.5 GB", partNumber: 3 },
  ]},
]
```

### `request-restore`
```ts
// Input: { albumKey: "photos/archive/2024/2024-03-March" }
// The Edge Function discovers all parts matching albumKey.part*.zip
// and issues RestoreObjectCommand for each part
const parts = await discoverParts(albumKey);
for (const part of parts) {
  await s3.send(new RestoreObjectCommand({
    Bucket: BUCKET,
    Key: part.Key,
    RestoreRequest: { Days: 7, GlacierJobParameters: { Tier: "Bulk" } }
  }));
}
```

### `get-download-urls`
- Checks `x-amz-restore` header on each part of the album
- Returns array of `{ key, url, size, lastModified, partNumber, totalParts }` with short-lived presigned GET URLs
- For archive data: returns one entry per part
- For hot data: returns individual file entries
- Only returns objects that are currently restored; marks album as "ready" only when ALL parts are restored

### `upload-file`
- Validates JWT, generates presigned POST fields or a presigned PUT URL
- All uploads land in `photos/hot/` prefix by default
- Returns the S3 key and ETag

### `delete-files`
- Validates Supabase JWT
- Accepts `{ keys: string[], versionId?: string }`
- For multi-part albums: warns that all parts will be deleted
- Calls `DeleteObject` (creates Delete Marker) or `DeleteObjectVersion` (permanent)
- Returns clear result: "Delete marker created" or "Permanently deleted version X"
- Supports batch delete for efficiency

---

## 9. Data Lifecycle, Bundling & Splitting Strategy

### What Gets Bundled and When

| Data Age                | Location              | Format                          | Bundled? |
|-------------------------|-----------------------|---------------------------------|----------|
| Current year            | `photos/hot/YYYY/`    | Individual files                | No       |
| Previous year           | `photos/hot/YYYY/`    | Individual files                | No       |
| Older than ~24 months   | `photos/archive/YYYY/`| Monthly ZIP(s), possibly split | Yes      |

The bundling window is intentionally conservative. Two full years of hot data gives plenty of time for easy browsing, selective restores, and uploads before files are automatically bundled into monthly archives.

### How the Go Bundler Lambda + EventBridge Cron Works

**Trigger**: EventBridge Scheduler rule with cron expression `cron(0 3 1 * ? *)` — runs on the 1st of each month at 3:00 AM UTC. This is well inside the AWS free tier (14 free schedules).

**Go Bundler Lambda logic** (`lambda/go-bundler/main.go`):

1. **List** all objects under `photos/hot/` with a delimiter of `/` to discover year/month folders
2. **Filter** folders whose name is older than 24 months (e.g. in July 2026, folders from 2024 and earlier are eligible)
3. **Group** the eligible files by `YYYY-MM` prefix (files may already be in subfolders)
4. **For each group, stream files into ZIP archive(s)**:
   - Uses Go's `archive/zip` — streaming writes, no local disk buffering for large files
   - Preserves original folder structure and filenames inside ZIP
   - **If total size ≤ MAX_PART_SIZE (default 10 GB)**: Creates a single `YYYY-MM-name.zip`
   - **If total size > MAX_PART_SIZE**: Splits into `YYYY-MM-name.part1.zip`, `.part2.zip`, etc.
     - Each part is filled up to MAX_PART_SIZE before starting the next
     - Files are NOT split across parts — each file goes entirely into one part
     - Naming: `{base}.part{number}.zip` starting from 1
5. **Upload** part(s) to `photos/archive/YYYY/`
6. **Verify** — Compare the uploaded ZIP's S3 ETag against the local checksum for each part
7. **On success**: Delete the original individual files from `hot/` (creates Delete Markers)
8. **On failure**: Log error to CloudWatch, do NOT delete originals. Next month's run will retry.
9. **Log** results: number of files bundled, total size, part count, each part's name/size/checksum, any errors

### Terraform Resources for the Bundler

Defined in `infra/bundler.tf`:

- `aws_lambda_function` — Go Bundler Lambda (provided.al2023 runtime or custom runtime for Go)
- `aws_iam_role` + `aws_iam_role_policy_attachment` — Minimal IAM role for the bundler:
  - `s3:ListBucket` on the backup bucket
  - `s3:GetObject` on `photos/hot/*`
  - `s3:PutObject` on `photos/archive/*`
  - `s3:DeleteObject` on `photos/hot/*` (only after checksum verification)
  - `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- `aws_scheduler_schedule` — EventBridge Scheduler rule with cron expression
- `aws_scheduler_schedule_group` (optional, for organization)
- `data.archive_file` or `terraform_data` — Build + package the Go binary as a ZIP for Lambda deployment
- **Environment variable**: `MAX_PART_SIZE` (default `10737418240` = 10 GB), configurable via Terraform

### Recommended Format: ZIP (Not tar.zst or 7z)

- **Universally supported**: Every OS (Windows, macOS, Linux, Android, iOS) can open ZIP natively or with built-in tools
- **No additional software required** for the wife to extract files
- **Streaming support**: ZIP allows progressive download and extraction
- **Go standard library**: `archive/zip` is built-in, no external dependencies
- **Familiar UX**: Everyone knows what a ZIP file is
- **Multi-part support**: Standard ZIP tools can open each part individually; extracting part1 automatically references subsequent parts

### Frontend Guard: Size Estimation + Warning

Before the user triggers a restore, the React app must estimate the total download size and warn if it would consume a significant portion of the 100 GB monthly free egress limit.

**Implementation** (`src/hooks/useRestoreSizeGuard.ts`):

```typescript
function useRestoreSizeGuard(albumTotalSizeBytes: number) {
  const MONTHLY_FREE_EGRESS = 100 * 1024 * 1024 * 1024; // 100 GB
  const usagePercent = (albumTotalSizeBytes / MONTHLY_FREE_EGRESS) * 100;

  return {
    canRestore: usagePercent <= 100,
    usagePercent,
    warning: usagePercent > 10 // warn if > 10 GB
      ? `This restore is ${formatSize(albumTotalSizeBytes)} (${usagePercent.toFixed(0)}% of your 100 GB monthly free limit).`
      : null,
    criticalWarning: usagePercent > 80
      ? `⚠️ This restore exceeds 80% of your monthly free egress. Remaining budget: ${formatSize(MONTHLY_FREE_EGRESS - albumTotalSizeBytes)}.`
      : null,
  };
}
```

**UI behavior**:
- **< 10%**: No warning, proceed normally
- **10–80%**: Yellow banner above the Restore button: *"This album is 25 GB. That's 25% of your monthly free download limit."*
- **> 80%**: Red banner + confirmation dialog: *"This restore is 95 GB (95% of your monthly limit). You will have very little free egress left this month. Are you sure?"*
- **> 100%**: Restore button disabled with explanation: *"This album exceeds the 100 GB monthly free limit. Contact Sebastian to plan a staggered restore."*
- The guard stores a running total of this month's already-restored size in localStorage so cumulative usage is tracked across sessions.

### How the React App Should Present Bundled vs Non-Bundled Albums

The `list-prefixes` Edge Function returns metadata that the UI renders differently based on type and part count:

```typescript
// Merged response with multi-part support
[
  { id: "hot/2026",       name: "2026",          type: "hot",     fileCount: 342,  totalSize: "1.2 GB" },
  { id: "archive/2024",   name: "March 2024",    type: "archive", totalSize: "28.5 GB", parts: [
    { fileName: "2024-03-March.part1.zip", size: "10 GB", partNumber: 1 },
    { fileName: "2024-03-March.part2.zip", size: "10 GB", partNumber: 2 },
    { fileName: "2024-03-March.part3.zip", size: "8.5 GB", partNumber: 3 },
  ]},
]
```

**UI indications**:
- Hot albums: Show folder icon, file count, "Browse files" option
- Archive albums (single part): Show ZIP icon, single file size, "Restore album" → downloads one ZIP
- Archive albums (multi-part): Show stacked ZIP icon, total size with "(3 parts)" label, part list toggle, "Restore album" → restores all parts
- Both show the same "Restore" button and status polling flow
- Archive albums display a subtle "📦 Bundled" badge

**Multi-part album detail view**:
```
┌─────────────────────────────────────────────┐
│  📦 March 2024                   28.5 GB     │
│  ─────────────────────────────────────────── │
│  ⚠️ This album has 3 parts. You need to      │
│  download all parts to unzip the full album. │
│                                              │
│  [✅ Restored]  Available until July 7       │
│                                              │
│  Parts:                                      │
│  ☐ Part 1 (10 GB)    [Download]             │
│  ☐ Part 2 (10 GB)    [Download]             │
│  ☐ Part 3 (8.5 GB)   [Download]             │
│                                              │
│  [Download All 3 Parts]                      │
└─────────────────────────────────────────────┘
```

### Impact on Restore Flow and Notifications

- **Restore**: Issues one `RestoreObjectCommand` per part. The UI polls ALL parts and shows overall progress (e.g. "Restoring… 2 of 3 parts ready").
- **Notification email**: Refers to the album name, mentions part count if > 1.
  ```
  Good news! Your "March 2024 Photos" (3 parts) are ready to download.
  Open the app to download each part.
  ```
- **Download**: One presigned URL per part, plus a "Download all" button that triggers parallel downloads.
- **Instructions in UI**: "Extract part1.zip — your operating system will automatically combine all parts."

### Safe Deletion of Original Files After Bundling

The Go Bundler Lambda follows a strict safe-deletion protocol:

1. **Create ZIP part(s)** from original files in `photos/hot/` → stream to `photos/archive/YYYY/`
2. **Verify** — Compare S3 ETag against local checksum for each part. All must match.
3. **Optional safety copy** — Copy original files to `photos/_bundled/YYYY-MM/` as a temporary safety net (lifecycle: expire after 30 days)
4. **Delete originals** — Only if ALL parts passed verification. Creates Delete Markers (soft delete).
5. **Terraform-managed lifecycle rules**:
   - Expire Delete Markers after 30 days (frees storage for soft-deleted objects)
   - Expire `_bundled/` objects after 30 days (safety net auto-cleanup)
6. **Rollback** — If ANY part's verification fails, the Lambda logs the error and exits without deleting anything. The next month's cron run will retry. Manual intervention can fix the issue (e.g. delete partially uploaded parts, retry).

This ensures no data loss: ALL ZIP checksums must match before any deletion occurs.

---

## 10. Notifications & Email Alerts (Go Lambda + Amazon SES Templates)

### Why We Chose This Approach
After a Bulk restore from Glacier Deep Archive finishes (~12–48 hours), we want to notify you and your wife with **one clean, branded HTML email per album** (not one email per individual file or per part). We also want nice buttons, consistent styling, and grouping logic.

**Chosen architecture** (minimal cost, fully as code):
```
S3 (ObjectRestore:Completed event)
        ↓
SNS Topic (family-backup-restore-notifications)
        ↓
Go Lambda (triggered by SNS, groups files by common prefix/album)
        ↓
Amazon SES SendTemplatedEmail (using pre-defined HTML template)
        ↓
HTML email to you + Mariangela
```

This keeps everything cheap, maintainable, and gives a much better experience than plain SNS emails.

### Cost (Still Practically $0)
- **Lambda**: AWS Lambda free tier (1M requests + 400,000 GB-seconds/month) → we will be at <0.1% usage.
- **SES**: $0.10 per 1,000 emails after free tier. With normal family use you stay well inside free limits.
- **SNS**: Negligible.
- **Total expected yearly cost**: **<$0.50** even with moderate usage.

### Go Lambda Responsibilities (Minimal)
The Go Lambda is intentionally small and focused:
1. Receive SNS message containing one or more `s3:ObjectRestore:Completed` records.
2. Group the restored keys by their common prefix (album/ZIP base name, aggregating all parts).
3. For each unique album, collect basic stats (total size, number of parts).
4. Call `ses.SendTemplatedEmail` with the SES template name + variables above.
5. Log success/failure (CloudWatch).

**Why Go?**
- Fast cold starts
- Small deployment package
- You are comfortable with it
- Excellent AWS SDK v2 support

The Lambda source lives in `lambda/go-notification/` directory.

**Recommended Subject (single part):**
```
Your Summer 2025 Photos are ready to download
```

**Recommended Subject (multi-part):**
```
Your March 2024 Photos (3 parts) are ready to download
```

**Recommended Body:**
```
Hi,

Good news! The restore of "March 2024 Photos" has finished.

This album has 3 parts. Open the Family Backup App to download each part:

→ Open App & Download: https://yourusername.github.io/family-backup-app/?restored=photos/archive/2024/2024-03-March

Download all parts and extract the first one — your computer will combine them automatically.

The files will be available to download for the next 7 days.

If you have any problems or need help, just reply to this email.

— Family Backup App
```

**Must-have elements in every email**:
- Clear name of what was restored (use the folder/album prefix)
- Part count if multi-part, with simple extraction instructions
- One big, obvious link back to the web app with `?restored=prefix` URL parameter
- How long the restored copy remains available
- Simple, non-technical language
- Offer of help

**Do NOT put raw S3 presigned download links directly in the email**:
- They are long and ugly
- They expire (we generate fresh ones inside the app)
- For multi-part albums it becomes overwhelming
- Much better UX and security to open the authenticated app and let it generate short-lived presigned URLs on demand

### How the Frontend (React) Should React

When the user clicks the link in the email and opens the app:

1. The app reads the URL parameter `?restored=photos/archive/2024/2024-03-March`
2. Immediately shows a prominent green success banner at the top of the screen:
   ```
   ✅ March 2024 Photos are ready! (3 parts)
   Available to download until July 10, 2026
   ```
3. Automatically expands/highlights that album in the list and marks it with a "Ready" badge
4. Shows the multi-part UI with individual download buttons + "Download all" option
5. For single-part albums: shows the same single-download flow as before
6. Optional nice-to-have: A small "Recently Restored" section in the sidebar showing completed restores from the last few days

This flow is **significantly better** for your wife than sending direct download links via email.

### What Goes into Terraform (`infra/`)
Add these resources (recommended in `infra/notifications.tf`):

- `aws_sns_topic` + `aws_sns_topic_subscription` (email for you + wife)
- `aws_s3_bucket_notification` filtered to `ObjectRestore:Completed` (with optional prefix filter)
- `aws_lambda_function` (Go runtime, from `lambda/go-notification/`)
- `aws_iam_role` + policy for Lambda (minimal: `sns:Receive`, `ses:SendTemplatedEmail`, logs)
- `aws_ses_template` with the HTML email template
- `aws_ses_email_identity` (verify your sending email/domain once)

All of this is version-controlled and reproducible.

### Implementation Order (Recommended)
1. First implement the simple SNS → plain text email (quick win).
2. Later replace with Go Lambda + SES template for grouped HTML emails (better long-term UX).

This staged approach lets you get notifications working fast while planning the nicer version.

---

## 11. Deletion & Cleanup

### Can We Delete Files from S3 Glacier?

**Yes.** Deletion works the same whether the object is in `GLACIER_FLEXIBLE_RETRIEVAL` or `GLACIER_DEEP_ARCHIVE`.

You can delete via:
- AWS Console (manual, occasional use)
- AWS CLI / SDK (scripts or Edge Function)
- The React app (recommended for this project)
- **Go Bundler Lambda** (automated — deletes originals only after ZIP verification)

**Important with Versioning enabled** (Terraform-managed):
- A normal `DeleteObject` creates a **Delete Marker** (soft delete). The file disappears from listings but **still exists and is billed**.
- To **permanently delete** a file you must delete a **specific version** using its `VersionId`.

### Cost of Deletion

| Cost Type                    | Price (eu-central-1)       | When It Applies                              | Impact for You |
|------------------------------|----------------------------|----------------------------------------------|----------------|
| DELETE API request           | **Free**                   | Every delete                                 | No cost |
| Early Deletion Fee           | Pro-rated storage cost     | Object younger than min. duration            | Main cost to watch |
| Delete Marker storage        | Same as object storage     | Until marker is cleaned up                   | Use Lifecycle rule |
| Restored copy (if any)       | Standard storage           | If object was restored before deleting       | Minor (~$0.50 for 100 GB × 7 days) |

**Early Deletion Fees**:
- **Glacier Flexible Retrieval**: Minimum 90 days. If you delete after 40 days → you pay the remaining 50 days at ~$0.0036/GB/month.
- **Glacier Deep Archive**: Minimum 180 days. Much lower penalty because storage rate is ~3.6× cheaper.

**Bottom line**: Deletion is very cheap unless you frequently delete files that are only a few weeks old. For normal family archive cleanup the cost is negligible.

### Recommended Implementation in This Project

**1. Terraform (`infra/`)** — Add three Lifecycle rules:
   - Expire old Delete Markers after 30 days (prevents indefinite billing for soft-deleted files)
   - Expire `_bundled/` objects after 30 days (safety net, auto-cleanup)
   - (Optional) Expire non-current versions after X days/versions for automatic cleanup

**2. New Edge Function** `supabase/functions/delete-files/index.ts`
   - Strict JWT validation
   - Support single file + batch delete
   - Optional `versionId` parameter for permanent deletion
   - **Archive data warning**: "This is a monthly backup ZIP. Deleting it removes the entire month's photos from cold storage."
   - **Multi-part warning**: "This album has 3 parts. All parts will be deleted."
   - Clear, user-friendly response messages

**3. React UI (All in `.tsx` files)**
   - Delete button next to files/albums with confirmation modal
   - Warning shown for recent files: *"This file is only X days old. Early deletion fee may apply."*
   - Distinct warning for archive ZIPs: *"This will delete all photos from March 2024 permanently."*
   - Multi-part warning: *"This will delete all 3 parts of March 2024."*
   - Advanced option (for you): "Permanently delete this specific version"
   - Success toast + refresh of the album view

**4. IAM Policy Update (Terraform)**
   - Add minimal `s3:DeleteObject` and `s3:DeleteObjectVersion` permissions scoped to your allowed prefixes only.
   - Never grant broad delete rights.

This approach keeps deletion **secure, auditable, cheap, and fully controlled** from the same wife-friendly interface.

---

## 12. Project Folder Structure (Everything in Code)

```
family-backup-app/
├── infra/                            # Terraform Infrastructure as Code
│   ├── main.tf                       # S3 bucket, lifecycle, CORS, encryption
│   ├── bundler.tf                    # Go Bundler Lambda + EventBridge Scheduler
│   ├── notifications.tf              # SNS, SES, notification Lambda
│   ├── iam.tf                        # IAM roles for Edge Functions + Lambdas
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── terraform.tfvars.example      # Committed template (no real values)
│   └── .gitignore                    # tfstate, terraform.tfvars, .terraform/
├── supabase/                         # Edge Functions (TypeScript)
│   └── functions/
│       ├── request-restore/
│       ├── get-download-urls/
│       ├── list-prefixes/
│       ├── upload-file/
│       └── delete-files/
├── lambda/                           # Go Lambda functions
│   ├── go-bundler/                   # Monthly ZIP bundling + splitting (EventBridge cron)
│   │   ├── main.go                   # Scan hot/, group by month, ZIP (with splitting),
│   │   │                             # upload to archive/, verify checksums, delete originals
│   │   ├── splitter.go               # Multi-part splitting logic
│   │   ├── go.mod
│   │   └── Makefile                  # build, test, package for Lambda
│   └── go-notification/              # Restore notification emails (SNS → SES)
│       ├── main.go
│       ├── go.mod
│       └── Makefile                  # build + deploy helper
├── src/                              # React App (Vite + TypeScript + TSX)
│   ├── components/                   # All UI declared here in .tsx files
│   │   ├── AlbumCard.tsx             # Album display (single + multi-part)
│   │   ├── RestoreButton.tsx         # Restore trigger with size guard
│   │   ├── StatusBadge.tsx           # Restore status (with per-part progress)
│   │   ├── PartList.tsx              # Multi-part download list
│   │   ├── SizeGuardBanner.tsx       # 100 GB free egress warning banner
│   │   └── DownloadList.tsx
│   ├── hooks/
│   │   ├── useAlbums.ts
│   │   ├── useRestoreStatus.ts
│   │   ├── useRestoreSizeGuard.ts   # Frontend guard logic
│   │   └── useSupabase.ts
│   ├── lib/
│   │   ├── supabase.ts
│   │   └── types.ts
│   ├── pages/
│   │   ├── Login.tsx
│   │   ├── Albums.tsx
│   │   └── ActiveRestores.tsx
│   ├── App.tsx
│   └── main.tsx
├── .github/workflows/
│   └── deploy.yml                    # Build React + deploy to GitHub Pages
├── tailwind.config.js                # Minimal (most styling lives in TSX)
├── postcss.config.js
├── vite.config.ts
├── package.json
└── README.md
```

**Styling Rule**: All visual design is declared inside `.tsx` files using Tailwind utility classes. The only CSS file is a minimal `src/index.css` containing the three Tailwind directives (`@tailwind base/components/utilities`). No raw CSS rules or separate stylesheet files for components.

---

## 13. Implementation Roadmap (PoC)

| Phase | Tasks | Estimated Time | Owner |
|-------|-------|----------------|-------|
| 1     | Initialize Terraform (`infra/`) + create S3 bucket, IAM, CORS, lifecycle via code | 2 hours | Sebastian |
| 2     | Create Supabase project, enable magic links, store AWS keys as Supabase Secrets | 1.5 hours | Sebastian |
| 3     | Create Edge Functions skeleton (`request-restore`, `get-download-urls`, `list-prefixes`, `delete-files`) | 2.5 hours | Sebastian |
| 4     | Build React app (Vite + TS + Tailwind) with magic-link login. All UI in `.tsx` files | 3–4 hours | Sebastian |
| 5     | Implement `list-prefixes` Edge Function (merged hot + archive view, multi-part detection) + album browser UI | 3 hours | Sebastian |
| 6     | Implement `request-restore` (multi-part support) + status polling + UI | 3 hours | Sebastian |
| 7     | Implement `get-download-urls` + download buttons (per-part + Download All) | 2.5 hours | Sebastian |
| 8     | Basic upload flow (presigned URLs to `hot/` prefix) | 2 hours | Sebastian |
| 9     | Build Go Bundler Lambda (`lambda/go-bundler/`) — scan, group, ZIP with splitting, upload, verify, safe delete | 5 hours | Sebastian |
| 10    | Create EventBridge Scheduler rule + bundler IAM role in Terraform (`infra/bundler.tf`) | 1 hour | Sebastian |
| 11    | Build frontend size guard (`useRestoreSizeGuard` + `SizeGuardBanner`) + multi-part UI (`PartList`) | 3 hours | Sebastian |
| 12    | GitHub Actions workflow for deploy to GitHub Pages | 1 hour | Sebastian |
| 13    | Basic SNS → plain text email notification (quick win) | 1.5 hours | Sebastian |
| 14    | Go Lambda + SES Email Template for grouped HTML emails (Phase 2) | 3 hours | Sebastian |
| 15    | End-to-end testing + wife UX feedback + documentation | 3 hours | Both |

**Total PoC effort**: ~36–40 focused hours (can be done over 8–9 evenings or two focused weekends). The extra time includes the splitting logic, frontend guard, and multi-part download UI.

---

## 14. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|----------|
| Restore takes longer than expected | Medium | Medium | Show clear "usually 5–12h" messaging + progress estimate |
| Wife finds UI confusing | Low | High | Big buttons, clear status language, test with her early; multi-part instructions tested separately |
| Wife doesn't understand multi-part extraction | Low | High | Clear instruction: "Download all parts, then extract part1.zip"; can add a short video/gif later |
| Frontend size guard incorrectly estimates | Low | Medium | Use exact size from S3 metadata; add manual override for Sebastian |
| GitHub Pages + Supabase CORS issues | Low | Medium | Document exact CORS config + test localhost vs prod |
| Supabase free tier limits hit | Very Low | Low | 500k Edge invocations + 50k MAU — we will be at <1% |
| Bundler Lambda corrupts a ZIP | Low | High | Verify checksum before deleting originals; safety copy in `_bundled/` for 30 days |
| Bundler Lambda times out on large month | Low | Medium | Increase Lambda timeout/memory; splitting already keeps each part manageable |
| Splitting produces uneven parts | Low | Low | Files are NOT split across parts — one file per part boundary, acceptable size variation |
| EventBridge cron fails to trigger | Very Low | Medium | CloudWatch alarm on no-invocation; manual fallback via AWS Console or re-invoke CLI |
| Large number of small files in hot/ | Medium | Low | Bundling resolves this — only temporary until monthly archive cycle |
| Browser upload reliability on mobile | Medium | Medium | Document that large uploads are better done from computer; or move to Expo later |

---

## 15. Open Decisions / Future Enhancements

- Client-side encryption (rclone crypt overlay) vs trusting S3 + Edge Function proxy?
- Do we want to support selecting multiple albums for restore in one go?
- Notification system when restore finishes (email via Supabase + SNS)?
- Should we add a "Recent uploads" or "My uploads" view?
- ZIP encryption: Password-protect monthly ZIPs before upload?
- Should the Bundler Lambda also handle partial months (mid-month bundling for completed events)?
- Frontend guard: Should we store per-user egress tracking in Supabase instead of localStorage for persistence across devices?
- Long-term: Migrate successful parts to Expo/React Native for better mobile upload experience?

---

## 16. How to Start Building (Copy-Paste Ready)

**Recommended order (Infrastructure first):**

1. **Create the project skeleton + infra/**
   ```bash
   mkdir family-backup-app && cd family-backup-app
   npm create vite@latest . -- --template react-ts
   mkdir -p infra supabase/functions lambda/go-bundler lambda/go-notification
   ```

2. **Initialize Terraform in `infra/`**
   - Create `providers.tf`, `main.tf`, `bundler.tf`, `notifications.tf`, `iam.tf`, `variables.tf`, `outputs.tf`
   - Copy `terraform.tfvars.example` and fill local values (never commit real keys)
   - Run `terraform init && terraform plan && terraform apply`

3. **Create Supabase project**
   ```bash
   npx supabase login
   npx supabase projects create family-backup
   ```
   - Enable Email Magic Links in Auth settings
   - Add your AWS access key + secret as Supabase Secrets (Settings → Edge Functions → Secrets)

4. **Install frontend dependencies**
   ```bash
   npm install @supabase/supabase-js @tanstack/react-query lucide-react date-fns
   npm install -D tailwindcss postcss autoprefixer
   npx tailwindcss init -p
   ```

5. **Write and deploy first Edge Functions**
   ```bash
   supabase functions deploy request-restore --no-verify-jwt
   supabase functions deploy list-prefixes --no-verify-jwt
   ```

6. **Add GitHub Actions deploy workflow** (`.github/workflows/deploy.yml`)

7. **Build the Go Bundler Lambda**
   ```bash
   cd lambda/go-bundler
   go mod init github.com/yourname/family-backup-app/lambda/go-bundler
   go get github.com/aws/aws-sdk-go-v2/service/s3
   # Implement: scan hot/ → group by YYYY-MM → ZIP (with splitting) → upload to archive/ → verify → delete originals
   # Build: GOOS=linux GOARCH=amd64 go build -o bootstrap main.go
   # Package: zip function.zip bootstrap
   ```
   Terraform will reference the built ZIP and deploy it as a Lambda with the EventBridge Scheduler trigger.
   The `MAX_PART_SIZE` environment variable is set in `infra/bundler.tf` and can be tuned without code changes.

---

## 17. Success Criteria for PoC Completion

The PoC is considered successful when:
- All AWS resources (S3 bucket, IAM, CORS, lifecycle) are created via Terraform in `infra/`
- Both users can log in with magic links on phone and laptop
- Wife can see existing albums (both hot and archive) and request a Bulk restore with one tap
- She sees clear status and can download files once ready — **single ZIP or multi-part ZIPs with clear instructions**
- Multi-part albums display part count, individual download buttons, and extraction guidance
- The frontend size guard shows appropriate warnings before restore based on album size vs 100 GB monthly limit
- A new photo uploaded via the app appears in `hot/` and can be restored later
- The Go Bundler Lambda is deployed via Terraform and can create monthly ZIPs (with splitting for large months), upload to `archive/`, verify checksums, and safely delete originals
- The EventBridge Scheduler rule is created via Terraform and triggers the bundler Lambda on schedule
- The bundler IAM role has least-privilege permissions (read `hot/`, write `archive/`, delete `hot/` only after verification)
- **Zero secrets or credentials exist in the Git repository**
- All UI components are written in `.tsx` files using only Tailwind classes (no raw CSS)
- Total monthly running cost (excluding storage) stays under $5
- The app is live on GitHub Pages and feels simple and trustworthy

---

**Next Step**: Tell me which part you want to tackle first and I will generate the ready-to-copy code:

1. Complete `infra/` Terraform files (`main.tf`, `bundler.tf`, `notifications.tf`, `iam.tf`, `variables.tf`, etc.)
2. Go Bundler Lambda (`lambda/go-bundler/main.go` + `splitter.go`) — scan, group, ZIP with splitting, upload, verify, safe delete
3. Supabase Edge Function templates (`request-restore.ts`, `get-download-urls.ts`, `list-prefixes.ts`) with multi-part support
4. React components: `PartList.tsx`, `SizeGuardBanner.tsx`, `useRestoreSizeGuard.ts` — multi-part UI + frontend guard
5. React + Vite + TypeScript project scaffold (with magic link login + Tailwind in TSX)
6. GitHub Actions workflow for Pages deploy
7. Full S3 + IAM policy + CORS configuration (as Terraform + manual checklist)

This architecture keeps the entire project (infrastructure + application) fully defined in code, secure, and extremely low-cost while giving your wife a genuinely simple experience.
