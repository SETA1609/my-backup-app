# my-backup-app

> Low-cost, self-hosted backup: browse, restore, and download archived photos and documents from S3 Glacier Deep Archive — all from a simple web app.

![Status: Planning](https://img.shields.io/badge/status-planning-yellow)
![Stack: React + Supabase + S3](https://img.shields.io/badge/stack-React%20%7C%20Supabase%20%7C%20S3%20Glacier-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

---

## What It Is

A fully open-source backup solution that combines the **cheapest AWS storage** (S3 Glacier Deep Archive at ~$1/TB/month) with a **simple web interface** that anyone in your household can use.

Just bring your own Supabase project and S3 bucket — everything else is configured via environment variables and Terraform.

---

## Key Features

- **Cheap cold storage**: ~$1/TB/month for long-term archival. Total monthly cost beyond storage is **under $2**.
- **Simple for non-technical users**: Magic-link login, big buttons, clear status messages, and multi-part ZIP download instructions.
- **Automatic monthly bundling**: A Go Lambda (triggered by EventBridge Scheduler) bundles files older than 3 months into ZIP archives and uploads them directly to Glacier Deep Archive. No manual work after setup.
- **No early deletion fees**: Original files are deleted from S3 Intelligent-Tiering (no minimum duration) — they never transition through Glacier. Only bundled ZIPs enter Deep Archive.
- **Frontend egress guard**: Warns before restoring if the album would consume a large portion of the 100 GB/month free AWS egress limit.
- **Everything as code**: Infrastructure (Terraform), backend (Supabase Edge Functions), and frontend (React + TypeScript) are all defined in the repository.
- **Secure by design**: AWS credentials never reach the browser. All S3 operations are proxied through Supabase Edge Functions. Least-privilege IAM per component.

---

## Architecture

```
Upload → hot/ (Intelligent-Tiering) ── after 3 months ──→ Go Bundler Lambda
                                                              ↓
User opens app ← React SPA ← Supabase Edge Functions ← archive/ (Glacier Deep Archive)
                                                              ↓
                                              Download ZIP(s) via presigned URLs
```

- **Last 3 months** of data stored as individual files in S3 Intelligent-Tiering — instant access
- **Older data** automatically bundled into monthly ZIPs stored directly in Glacier Deep Archive
- **Restoring** an album takes 12–48 hours (Bulk retrieval tier) — the cheapest option
- **Multi-part ZIPs** are auto-split for months > 10 GB, with clear extraction instructions
- **Frontend guard** warns before exceeding 100 GB/month free egress

---

## Tech Stack

| Layer | Choice |
|-------|--------|
| Frontend | React 19 + TypeScript + Tailwind (Vite) |
| Hosting | GitHub Pages (free) |
| Auth & Backend | Supabase — magic links + Edge Functions (Deno) |
| Storage | AWS S3 Intelligent-Tiering + Glacier Deep Archive |
| Infrastructure | Terraform (everything as code) |
| Automation | Go Lambda + EventBridge Scheduler (monthly cron) |
| Notifications | Go Lambda + Amazon SES |

---

## Current Status

**Planning / Pre-Implementation.** The architecture is fully documented. Next step: write the Terraform files and create the S3 bucket.

- [x] Architecture decisions documented (7 ADRs)
- [x] Security model documented
- [x] Development guide written
- [x] PoC roadmap with phases and milestones
- [ ] Terraform `infra/` files
- [ ] Supabase project + Edge Functions
- [ ] React app
- [ ] Go Bundler Lambda

---

## Documentation

| Document | What It Covers |
|----------|---------------|
| [`PLANNING.md`](./PLANNING.md) | Full architecture, cost analysis, data lifecycle, risks |
| [`BACKLOG.md`](./BACKLOG.md) | Actionable tasks organized by area, checkbox-ready |
| [`docs/architecture.md`](./docs/architecture.md) | Architecture diagram and data flow |
| [`docs/development.md`](./docs/development.md) | Local dev setup, Terraform, Supabase, Go Lambda workflows |
| [`docs/decisions.md`](./docs/decisions.md) | Technology choices and rationale (lightweight ADRs) |
| [`docs/security.md`](./docs/security.md) | Credentials, IAM policies, encryption, threat model |
| [`docs/roadmap.md`](./docs/roadmap.md) | Phased PoC timeline with milestones and success criteria |
| [`docs/react-style.md`](./docs/react-style.md) | React conventions, Tailwind patterns, testing strategy |

---

## Getting Started

```bash
git clone git@github.com:SETA1609/my-backup-app.git
cd my-backup-app
```

You will need:
1. An AWS account with an S3 bucket (Terraform creates it for you)
2. A Supabase project with magic-link auth enabled
3. Your AWS access key stored as a Supabase Secret

See [`docs/development.md`](./docs/development.md) for the full local setup guide.

For the prioritized task list, see [`BACKLOG.md`](./BACKLOG.md).

---

## License

MIT
