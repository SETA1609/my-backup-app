# Security Overview

Security model for the family backup app. Covers credentials, auth, IAM, encryption, deletion, and incident response.

---

## Principles

1. **Zero secrets in the repository** — No AWS keys, Supabase service role keys, or Terraform state with secrets are ever committed.
2. **Zero AWS credentials in the browser** — Every S3/Glacier call happens server-side inside Supabase Edge Functions. The browser never sees an AWS key.
3. **Least privilege everywhere** — Each component (Edge Function, Lambda) gets only the permissions it needs, scoped to specific prefixes.
4. **Everything as code** — IAM policies, CORS, encryption, and public access blocks are all defined in Terraform and version-controlled.

---

## Secrets & Credentials

| Secret | Where It Lives | How It's Set | Never In |
|--------|---------------|-------------|----------|
| AWS access key | Supabase Secrets (Settings → Edge Functions) | `supabase secrets set` | Git, `.env`, code |
| AWS secret key | Supabase Secrets | `supabase secrets set` | Git, `.env`, code |
| Supabase service role key | Local `.env.local` only | Copied from Supabase dashboard | Git |
| Supabase anon key | GitHub Actions secrets + local `.env.local` | `gh secret set` | Git |
| Terraform state | Local filesystem (or encrypted S3 backend) | `tofu apply` generates it | Git (`*.tfstate` in `.gitignore`) |

### Rotation Plan

If a secret leaks:

1. **AWS key**: Revoke the compromised key in IAM → generate a new one → update Supabase Secrets → restart Edge Functions
2. **Supabase service role key**: Regenerate in Supabase dashboard → update any services using it
3. **GitHub token / deploy key**: Revoke in GitHub Settings → generate new → update workflows

No code changes needed — secrets are never hardcoded. Rotation takes < 5 minutes.

---

## Authentication & Authorization

```
User → Magic Link Email → Supabase Auth → JWT → Edge Function
                                                    │
                                          JWT validated before
                                          any AWS SDK call
```

- **Authentication**: Supabase Email Magic Links — no password to remember or leak
- **Session**: JWT stored in browser, sent with every Edge Function call via `Authorization: Bearer <token>`
- **Authorization**: Every Edge Function validates the JWT before executing. Functions use `supabase-auth-go` pattern (Deno middleware that checks `req.headers.get("Authorization")`)
- **No API keys in URLs**: All authenticated requests go through Supabase's HTTPS endpoint

---

## IAM Policies (Least Privilege)

### Edge Functions IAM Role

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:ListBucket",
    "s3:GetObject",
    "s3:PutObject",
    "s3:RestoreObject"
  ],
  "Resource": [
    "arn:aws:s3:::family-backup-bucket",
    "arn:aws:s3:::family-backup-bucket/photos/*"
  ]
}
```

- **No** `s3:DeleteObject` — Edge Functions cannot delete anything
- **No** `s3:PutObjectAcl` — permissions cannot be changed
- **No** `s3:GetBucketPolicy` — bucket policy is read-only from Terraform

### Go Bundler Lambda IAM Role

```json
{
  "Effect": "Allow",
  "Action": ["s3:ListBucket"],
  "Resource": ["arn:aws:s3:::family-backup-bucket"]
},
{
  "Effect": "Allow",
  "Action": ["s3:GetObject"],
  "Resource": ["arn:aws:s3:::family-backup-bucket/photos/hot/*"]
},
{
  "Effect": "Allow",
  "Action": ["s3:PutObject"],
  "Resource": ["arn:aws:s3:::family-backup-bucket/photos/archive/*"]
},
{
  "Effect": "Allow",
  "Action": ["s3:DeleteObject"],
  "Resource": ["arn:aws:s3:::family-backup-bucket/photos/hot/*"]
}
```

- `s3:DeleteObject` only on `hot/` — the bundler can only delete the original files it just archived
- **No** access to `archive/` for delete — bundled ZIPs are permanent once uploaded
- `s3:PutObject` only on `archive/` — the bundler cannot write to `hot/`
- Bundler has **no** access to Supabase, SES, SNS, or any other AWS service

### Notification Lambda IAM Role

- `sns:Receive` on the restore-notification topic
- `ses:SendTemplatedEmail` from the verified sending address
- CloudWatch logs only

---

## Data Protection

### Encryption

| Layer | Method | Managed By |
|-------|--------|-----------|
| At rest (S3) | SSE-KMS (AES-256) | AWS KMS |
| In transit | TLS 1.3 | AWS + GitHub Pages |
| Browser → Supabase | HTTPS | Supabase |
| Edge Function → S3 | TLS + AWS SigV4 | AWS SDK |

### S3 Hardening (all in Terraform)

- **Public access blocked**: `aws_s3_bucket_public_access_block` block all four settings
- **Versioning enabled**: Every object version is preserved — accidental overwrites/deletes are recoverable
- **SSE-KMS**: Default encryption with AWS managed KMS key
- **No ACLs**: Bucket owner enforced, ACLs disabled

### Versioning & Delete Markers

```
Normal DeleteObject → Delete Marker created → Object hidden from list
                                                ↓
                                    Still billed (version stored)
                                                ↓
                          Lifecycle rule expires marker after 30 days
```

- `DeleteObject` creates a **soft delete** (Delete Marker) — the data still exists and is recoverable
- Permanent deletion requires `DeleteObject` + `VersionId` — only exposed in the app as an advanced option
- Lifecycle rule auto-expires Delete Markers after 30 days to prevent billing for forgotten soft-deletes

### Safe Deletion After Bundling

The Go Bundler Lambda follows this protocol to prevent data loss:

```
1. Create ZIPs from hot/ files
       ↓
2. Upload ZIPs to archive/ with StorageClass: DEEP_ARCHIVE
       ↓
3. Verify — compare S3 ETag against local checksum for EVERY part
       ↓
   ┌─── All match? ───┐
   │ YES              │ NO
   ▼                  ▼
4a. Delete originals   4b. Log error, exit
    from hot/              Do NOT delete anything
    (soft delete)          Next cron run retries
```

- Deletion only happens after **all** checksums pass
- Optional safety copy in `photos/_bundled/` (auto-expires after 30 days) adds an extra layer
- The bundler is **idempotent** — if it fails mid-way, the next month's run handles everything

---

## CORS & Public Access

### CORS Configuration (Terraform-managed)

```hcl
cors_rule {
  allowed_headers = ["*"]
  allowed_methods = ["GET", "PUT", "POST"]
  allowed_origins = [
    "https://yourusername.github.io",
    "http://localhost:5173"           # dev only
  ]
  expose_headers  = ["x-amz-restore", "x-amz-request-id"]
  max_age_seconds = 3600
}
```

- Only the GitHub Pages domain and localhost are allowed
- `x-amz-restore` is exposed so the frontend can check restore status

### What's Blocked

- S3 public access: **all four settings blocked** (new ACLs, public buckets, public policies, ignore public ACLs)
- No unauthenticated `ListObjects` — listing requires valid IAM credentials or presigned URLs
- Direct S3 access from the browser: **impossible** — CORS blocks non‑allowed origins, and the browser never has AWS credentials anyway

---

## Threat Model

| Threat | Likelihood | Impact | Mitigation |
|--------|-----------|--------|-----------|
| AWS key leaked via Supabase | Low | Critical | Rotation plan (< 5 min). Key has no delete permission. |
| GitHub token leaked in CI logs | Low | High | Short-lived tokens, OIDC preferred. Revoke immediately. |
| JWT stolen (XSS) | Low | Medium | Short expiry (1h). No AWS keys in JWT payload. |
| Wife's session hijacked | Very Low | Medium | Magic links + HTTPS-only. No passwords to leak. |
| S3 bucket deleted | Very Low | Critical | Versioning enabled. Terraform can recreate. |
| Bundler Lambda corrupts a ZIP | Low | High | Checksum verification before deletion. Safety copy in _bundled/. |
| Malicious file upload | Low | Low | Uploads go to `hot/` only. No code execution in S3. |
| AWS account compromise | Very Low | Critical | MFA on root account. IAM roles, not users. CloudTrail auditing. |

---

## Incident Response

**If credentials are compromised**:

1. **Revoke** — Delete the compromised IAM key or rotate the Supabase secret immediately
2. **Audit** — Check CloudTrail for `s3:GetObject`, `s3:ListBucket` calls from unusual IPs
3. **Rotate** — Generate new credentials and update Supabase Secrets / GitHub Secrets
4. **Verify** — Confirm old credentials no longer work (`aws sts get-caller-identity` with old key returns AccessDenied)
5. **Learn** — Update security practices to prevent recurrence

**If suspicious S3 activity is detected**:

1. Check CloudTrail for `s3:DeleteObject` or `s3:PutObject` calls from unexpected principals
2. Verify versioning is still enabled (it should be — Terraform enforces it)
3. Restore any deleted objects from previous versions
4. Rotate all credentials as a precaution

---

## Key Takeaways

- **The browser never sees an AWS credential** — all S3 calls go through Supabase Edge Functions
- **The bundler can delete only from `hot/`, never from `archive/`** — bundled ZIPs are permanent
- **Versioning means no data loss from accidental deletion** — soft deletes are recoverable for 30+ days
- **No secrets in Git** — credentials live in Supabase Secrets, GitHub Secrets, or local `.env.local` (all gitignored)
- **Least privilege is enforced by Terraform** — IAM policies are code-reviewed and version-controlled
