# my-backup-app

Zero-cost, open-source backup solution using Supabase Auth + Edge Functions and Amazon S3 Glacier Deep Archive.

Browse, restore, and download cold-stored backups from a simple web interface — all infrastructure defined as code.

## Tech Stack

- **Frontend**: React + TypeScript + Tailwind (Vite)
- **Backend**: Supabase Auth + Edge Functions (Deno/TypeScript)
- **Storage**: Amazon S3 Glacier Deep Archive
- **Infrastructure**: Terraform
- **Notifications**: Go Lambda + Amazon SES
- **Hosting**: GitHub Pages (free)

## Repo Structure

```
├── docs/                            # Vision & Mission
├── infra/                           # Terraform (S3, IAM, lifecycle, CORS)
├── supabase/functions/              # Edge Functions
├── lambda/go-notification/          # Go Lambda for restore notifications
├── src/                             # React SPA
└── .github/workflows/               # CI/CD
```
