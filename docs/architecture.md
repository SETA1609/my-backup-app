# Architecture

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
│  • Hot data in Intelligent-Tiering → bundler uploads ZIPs   │
│  •   directly to Glacier Deep Archive (no lifecycle rule)    │
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
│  • Scans photos/hot/ for data older than 3 months           │
│  • Groups by YYYY-MM, creates monthly ZIP archives          │
│  • Auto-splits: if ZIP > MAX_PART_SIZE (10 GB default),     │
│    splits into name.part1.zip, name.part2.zip, ...          │
│  • Uploads part(s) to photos/archive/YYYY/                  │
│  • Verifies checksums, then deletes original files          │
│  • Logs results to CloudWatch                               │
│  • Source in lambda/go-bundler/                              │
└─────────────────────────────────────────────────────────────┘
```

## Data Flow

1. User logs in via Supabase magic link → JWT issued
2. App calls `list-prefixes` — merges `hot/` folders + `archive/` monthly ZIPs (including multi-part) into a unified album view
3. Frontend guard checks estimated restore size vs 100 GB monthly free egress → warns if approaching limit
4. User clicks **"Restore Summer 2025 Photos (Free, ~48 hours)"**
5. Edge Function calls `s3.restoreObject({ Tier: "Bulk" })` on each part of the album
6. App polls `get-download-urls` every 30–60s until all parts show `ongoing-request="false"`
7. Presigned `GET` URLs returned per part — download one at a time or all at once
8. Multi-part albums show: *"This album has 3 parts. Download all parts and unzip the first one."*
9. Hot data: individual files restored and downloaded selectively
10. Uploads → presigned POST to `photos/hot/` → Intelligent-Tiering (no Glacier transition). Bundler later archives to Glacier Deep Archive directly.
11. Go Bundler Lambda runs monthly via EventBridge cron, bundling data older than 3 months into ZIPs with automatic splitting

## Tech Stack

| Layer                  | Technology                          |
|------------------------|-------------------------------------|
| Frontend               | Vite + React 19 + TypeScript + TSX  |
| Styling                | Tailwind CSS (utility classes in TSX) |
| UI Components          | shadcn/ui (Radix + Tailwind)        |
| State                  | TanStack Query (React Query)        |
| Auth & Backend         | Supabase (Auth + Edge Functions)    |
| Hosting                | GitHub Pages + GitHub Actions       |
| Infrastructure         | Terraform                           |
| Storage                | S3 Glacier Deep Archive             |
| AWS SDK                | @aws-sdk/client-s3                  |
| Automated Bundling     | Go Lambda + EventBridge Scheduler   |
| ZIP Splitting          | Go + archive/zip                    |
| Notifications          | Go Lambda + Amazon SES              |
| Frontend Guard         | React hook (useRestoreSizeGuard)    |

## S3 Prefix Strategy

| Prefix                  | Purpose                                    |
|-------------------------|--------------------------------------------|
| `photos/hot/YYYY/MM/`  | Recent data (last 3 months), individual files |
| `photos/archive/YYYY/`  | Bundled monthly ZIPs, possibly split into `.partN.zip` |
| `photos/_bundled/`      | Temporary safety copy after bundling (30-day lifecycle) |

## Key Principles

- Everything defined as code (Terraform + TSX components)
- Zero credentials in the repository
- All UI in `.tsx` files with Tailwind — no raw CSS
- AWS credentials never reach the browser
- Least-privilege IAM per component
- Non-technical user-friendly UX with clear instructions and size warnings
