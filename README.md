# my-backup-app

> Zero-cost family backup: browse, restore, and download photos from Amazon S3 Glacier Deep Archive — all from a simple web app.

![Status: Planning](https://img.shields.io/badge/status-planning-yellow)
![Stack: React + Supabase + S3](https://img.shields.io/badge/stack-React%20%7C%20Supabase%20%7C%20S3%20Glacier-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

---

## Why This Exists

Cloud storage is cheap. Retrieving it shouldn't be expensive or complicated.

This app stores family photos and documents in **S3 Glacier Deep Archive** (~$1/TB/month) and provides a wife-friendly web interface to browse albums, request restores, and download ZIPs. A monthly Go Lambda automatically bundles old data into archives — no manual work after setup.

The total monthly cost beyond storage is **under $2**.

---

## How It Works

```
Upload → hot/ (Intelligent-Tiering) ── after 3 months ──→ Go Bundler Lambda
                                                              ↓
Wife opens app ← React SPA ← Supabase Edge Functions ← archive/ (Glacier Deep Archive)
                                                              ↓
                                              Download ZIP(s) via presigned URLs
```

- **Last 3 months** of photos are stored as individual files — instant access
- **Older data** is bundled into monthly ZIPs stored directly in Glacier Deep Archive
- **Restoring** an album takes 12–48 hours (Bulk tier) — cheapest retrieval option
- **Multi-part ZIPs** are auto-split for months > 10 GB, with clear instructions
- **Frontend guard** warns before exceeding the 100 GB/month free AWS egress limit

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

**Planning / Pre-Implementation.** The architecture is fully documented. Next step: write Terraform files and create the S3 bucket.

- [x] Architecture decisions documented (7 ADRs)
- [x] Security model documented
- [x] Development guide written
- [x] PoC roadmap with phases and milestones
- [ ] Terraform `infra/` files
- [ ] Supabase project + Edge Functions
- [ ] React app
- [ ] Go Bundler Lambda

---

## Key Documents

| Document | What It Covers |
|----------|---------------|
| [`PLANNING.md`](./PLANNING.md) | Master planning document — full architecture, cost analysis, data lifecycle, risks |
| [`BACKLOG.md`](./BACKLOG.md) | Actionable tasks, organized by area, checkbox-ready |
| [`docs/architecture.md`](./docs/architecture.md) | Architecture diagram and data flow |
| [`docs/development.md`](./docs/development.md) | Local dev setup, Terraform, Supabase, Go Lambda workflows |
| [`docs/decisions.md`](./docs/decisions.md) | Why we chose each technology (lightweight ADRs) |
| [`docs/security.md`](./docs/security.md) | Credentials, IAM policies, encryption, threat model |
| [`docs/roadmap.md`](./docs/roadmap.md) | Phased PoC timeline with milestones and success criteria |
| [`docs/react-style.md`](./docs/react-style.md) | React conventions, Tailwind patterns, testing strategy |

---

## Getting Started

```bash
git clone git@github.com:SETA1609/my-backup-app.git
cd my-backup-app
```

See [`docs/development.md`](./docs/development.md) for the full local setup guide (Docker, Terraform, Supabase, Go).

For the implementation backlog with prioritized tasks, see [`BACKLOG.md`](./BACKLOG.md).

---

## License

MIT
