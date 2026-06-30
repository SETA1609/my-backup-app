# Architecture Decision Records

Lightweight ADRs for the family backup app.

---

## 1. Supabase Edge Functions over API Gateway + Lambda

**Date**: 2026-06

**Context**: We needed a secure backend to proxy AWS S3 operations from the browser. The options were: (a) API Gateway + Lambda (classic serverless), or (b) Supabase Edge Functions (Deno-based, integrated with Supabase Auth). We have only 2 users and a handful of endpoints.

**Decision**: Use Supabase Edge Functions.

**Consequences**:
- (+) **Free tier**: 500k invocations/month — we will use < 0.1% of that
- (+) **Zero extra auth code**: Supabase Auth (magic links) + JWT validation is built-in; every function automatically receives the authenticated user context
- (+) **Fast cold starts**: Deno-based functions start in single-digit milliseconds vs Lambda's ~50–200ms
- (+) **Deploy from CLI**: `supabase functions deploy` — no CloudFormation or CDK needed
- (+) **Secrets management built-in**: AWS keys stored as Supabase Secrets, never in the repo
- (-) **Locked to Supabase ecosystem**: harder to migrate away compared to Lambda + API Gateway
- (-) **Less familiar ecosystem**: Deno APIs differ from Node (URL imports, no npm in functions)

---

## 2. Go for the Monthly Bundler Lambda

**Date**: 2026-06

**Context**: The monthly bundler Lambda reads files from S3, creates ZIP archives (with optional splitting), uploads them to Glacier Deep Archive, verifies checksums, and deletes originals. This runs once per month and needs to handle large data volumes efficiently.

**Decision**: Write the bundler Lambda in Go.

**Consequences**:
- (+) **Fast cold starts**: Go compiles to a native binary — Lambda cold starts are ~50ms vs Python's ~200ms or Node's ~100ms
- (+) **Streaming ZIP creation**: Go's `archive/zip` supports streaming writes natively. Large months (50+ GB) can be streamed without buffering to disk, keeping Lambda memory usage low
- (+) **Single binary deployment**: No runtime dependencies, no `pip install` or `node_modules` — just upload a 5 MB ZIP
- (+) **Familiar language**: The developer is comfortable with Go, reducing debugging time
- (+) **Excellent AWS SDK**: `aws-sdk-go-v2` is well-maintained and ergonomic
- (-) **Longer to write than Python**: Simple scripting tasks take more lines of Go
- (-) **No built-in Lambda runtime for Go**: Must compile to `bootstrap` binary with custom runtime

---

## 3. 24 Months of Hot Storage Before Bundling

**Date**: 2026-06

**Context**: Data in `photos/hot/` is stored as individual files in S3 Intelligent-Tiering — fast to browse, restore, and download without waiting for Glacier Bulk restoration. We needed to decide how long data stays here before the Go Bundler Lambda archives it into monthly ZIPs in Glacier Deep Archive.

**Decision**: Keep data in `photos/hot/` for 24 months before bundling.

**Consequences**:
- (+) **Wife-friendly**: Most family photos are accessed within the first 1–2 years. 24 months of instant-access data means 90%+ of restores never hit Glacier delays.
- (+) **No early deletion fee risk**: After 24 months in Intelligent-Tiering, the bundler is not time-critical. If the Lambda fails one month, there are plenty of previous months ready to bundle.
- (+) **Simple mental model**: "Everything from the last 2 years is instant — everything older takes a day."
- (-) **Higher hot storage cost**: 24 months at ~$0.023/GB/month vs $0.00099/GB/month for Glacier — roughly 23× more expensive for the hot portion. For 500 GB of active data, that's ~$11.50/month vs ~$0.50/month.
- (-) **More API requests**: Individual files accumulate over 24 months, increasing LIST/GET request costs vs bundling sooner.

---

## 4. Bulk Retrieval Tier + 7-Day Restore Window

**Date**: 2026-06

**Context**: Glacier Deep Archive offers three retrieval tiers: Expedited (1–5 min, expensive), Standard (3–5 hours, moderate), and Bulk (5–12 hours, cheapest). Restored objects are temporary copies that expire after a configurable number of days.

**Decision**: Use Bulk retrieval tier with a 7-day restore window.

**Consequences**:
- (+) **Cheapest retrieval**: Bulk tier costs $0.0025/GB vs Expedited at $0.03/GB — a 12× cost difference
- (+) **7 days is generous**: Even if the wife waits until the weekend to download, the files are still available
- (+) **Good enough for family use**: Photos from 2+ years ago are nostalgic, not urgent — waiting 5–12 hours is acceptable
- (-) **Bulk can take 5–48 hours**: AWS says "within 48 hours" for Bulk — occasionally it takes the full 2 days
- (-) **No partial restore**: The entire album (all ZIP parts) must be restored — you can't pick individual photos from within a ZIP without downloading it all

---

## 5. ZIP Format with Automatic Part Splitting

**Date**: 2026-06

**Context**: The monthly bundler needs to choose an archive format and decide how to handle months that exceed 10 GB. Options considered: single ZIP, ZIP split into parts, tar.zst (Zstandard compression), and 7z. The format must be openable on any device (Windows, macOS, phone) without installing extra software.

**Decision**: Use ZIP format with automatic splitting into `.partN.zip` files when a month exceeds 10 GB.

**Consequences**:
- (+) **Universal compatibility**: Every OS can extract ZIP files natively — no software to install for the wife
- (+) **Multi-part is transparent**: Extract `part1.zip` — the OS automatically finds and combines subsequent parts
- (+) **Go standard library**: `archive/zip` is built-in, no external dependencies
- (+) **Streaming**: ZIP supports progressive download and extraction
- (+) **10 GB is a safe part size**: Fits on common filesystems (FAT32 has a 4 GB limit, so exFAT/NTFS at 10 GB is fine for modern devices)
- (+) **No compression overhead**: Photos/videos are already compressed — ZIP's "store" mode (no compression) is fastest and free
- (-) **No compression savings**: tar.zst would save 2–5% on already-compressed media, but the complexity isn't worth it
- (-) **Larger total file count**: A 50 GB month produces 5 parts instead of 1 — more files to manage

---

## 6. GitHub Pages + Vite React over Next.js / Vercel

**Date**: 2026-06

**Context**: The frontend is a simple SPA: login, browse albums, trigger restores, download files. No SSR, no SEO, no dynamic routes. We needed a hosting platform and framework that costs $0 for our scale (2 users).

**Decision**: Use Vite + React hosted on GitHub Pages.

**Consequences**:
- (+) **Truly free**: GitHub Pages has unlimited free hosting for public repos (or $4/month if private). Vercel/Netlify have generous free tiers but require more configuration for this use case.
- (+) **Simple build pipeline**: `bun run build` produces a static `dist/` folder — deploy with a basic GitHub Actions workflow
- (+) **No SSR needed**: All dynamic data comes from Supabase Edge Functions after the page loads. No SEO needed for a private backup app.
- (+) **Vite is fast**: Sub-second HMR in development, optimized production builds with code splitting
- (-) **No server-side logic**: All API calls must go through Supabase Edge Functions — no Next.js API routes
- (-) **GitHub Pages has no server-side redirects**: SPA routing requires a 404.html workaround or hash-based routing
- (-) **No edge middleware**: Unlike Vercel, we can't run middleware at the edge before the page loads

---

## 7. Merged Hot/Archive View Instead of Separate Tabs

**Date**: 2026-06

**Context**: The app shows two types of data: `hot/` (individual files, instant access) and `archive/` (bundled ZIPs in Glacier, requires 12–48h restore). We needed to decide whether to show these as separate tabs/views or merge them into one unified album list.

**Decision**: Merge both views into a single chronological album list, with visual indicators for type (hot vs archive) and multi-part status.

**Consequences**:
- (+) **Simplicity**: The wife sees one list of albums sorted by date — no need to understand the underlying storage tier
- (+) **Clear visual cues**: Archive albums show a ZIP icon and "Restore (~48h)" button; hot albums show a folder icon and "Browse" button. Multi-part albums show "(3 parts)".
- (+) **Natural browsing**: Scrolling chronologically from current month backwards works seamlessly — the transition from hot to archive is invisible
- (+) **Frontend guard still works**: The `useRestoreSizeGuard` hook checks size regardless of storage tier, so warnings are consistent
- (-) **More complex Edge Function**: `list-prefixes` must query both prefixes, merge results, and detect multi-part groupings. Slightly more code than two separate endpoints.
- (-) **Hot/archive distinction can confuse**: If the wife doesn't notice the ZIP icon, she might wonder why some albums take 48 hours. Clear labels mitigate this.
