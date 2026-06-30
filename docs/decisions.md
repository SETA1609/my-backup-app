# Architecture Decision Records

Lightweight ADRs for the backup app.

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

## 3. 3 Months of Hot Storage Before Bundling (Option B)

**Date**: 2026-06

**Context**: Data in `photos/hot/` is stored as individual files in S3 Intelligent-Tiering — fast to browse, restore, and download without waiting for Glacier Bulk restoration. We needed to decide how long data stays here before the Go Bundler Lambda archives it into monthly ZIPs in Glacier Deep Archive. The key constraint: we must avoid early deletion fees (Glacier Deep Archive has a 180-day minimum).

**Decision**: Keep data in `photos/hot/` for only 3 months. The bundler uploads ZIPs **directly** to Glacier Deep Archive with `StorageClass: "DEEP_ARCHIVE"`, then deletes the original files from Intelligent-Tiering (which has no minimum duration). There is **no lifecycle rule** transitioning `hot/` objects to Glacier — this is the core of Option B.

**Consequences**:
- (+) **Zero early deletion fees**: Original files are deleted from Intelligent-Tiering (no minimum), never from Glacier. Only bundled ZIPs enter Glacier — and they stay for years, well past the 180-day minimum.
- (+) **Lowest hot storage cost**: Only 3 months at Intelligent-Tiering pricing (~$0.023/GB/month) vs 24 months. For 500 GB, that's ~$1.15/month vs ~$11.50/month.
- (+) **Dramatic object count reduction**: ~90–99% fewer objects in S3 after bundling, reducing LIST/GET API costs.
- (+) **Simple cost model**: No lifecycle transition to manage, no early deletion fee math — the Glacier Deep Archive is write-only from the project.
- (-) **Higher restore frequency**: Data from 4+ months ago requires a Bulk restore (12–48h wait). Non-technical users cannot instantly browse photos from last year.
- (-) **UX trade-off**: Clear onboarding messaging and the frontend guard help, but the 12–48h wait for semi-recent photos is the main compromise.
- (-) **No safety buffer**: If the bundler Lambda fails one month, eligible data sits in `hot/` for another month — but the bundler is idempotent and retries next cycle.

---

## 4. Bulk Retrieval Tier + 7-Day Restore Window

**Date**: 2026-06

**Context**: Glacier Deep Archive offers three retrieval tiers: Expedited (1–5 min, expensive), Standard (3–5 hours, moderate), and Bulk (5–12 hours, cheapest). Restored objects are temporary copies that expire after a configurable number of days.

**Decision**: Use Bulk retrieval tier with a 7-day restore window.

**Consequences**:
- (+) **Cheapest retrieval**: Bulk tier costs $0.0025/GB vs Expedited at $0.03/GB — a 12× cost difference
- (+) **7 days is generous**: Even if a user waits until the weekend to download, the files are still available
- (+) **Good enough for personal use**: Photos from 2+ years ago are nostalgic, not urgent — waiting 5–12 hours is acceptable
- (-) **Bulk can take 5–48 hours**: AWS says "within 48 hours" for Bulk — occasionally it takes the full 2 days
- (-) **No partial restore**: The entire album (all ZIP parts) must be restored — you can't pick individual photos from within a ZIP without downloading it all

---

## 5. ZIP Format with Automatic Part Splitting

**Date**: 2026-06

**Context**: The monthly bundler needs to choose an archive format and decide how to handle months that exceed 10 GB. Options considered: single ZIP, ZIP split into parts, tar.zst (Zstandard compression), and 7z. The format must be openable on any device (Windows, macOS, phone) without installing extra software.

**Decision**: Use ZIP format with automatic splitting into `.partN.zip` files when a month exceeds 10 GB.

**Consequences**:
- (+) **Universal compatibility**: Every OS can extract ZIP files natively — no software to install for non-technical users
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
- (+) **Simplicity**: Non-technical users see one list of albums sorted by date — no need to understand the underlying storage tier
- (+) **Clear visual cues**: Archive albums show a ZIP icon and "Restore (~48h)" button; hot albums show a folder icon and "Browse" button. Multi-part albums show "(3 parts)".
- (+) **Natural browsing**: Scrolling chronologically from current month backwards works seamlessly — the transition from hot to archive is invisible
- (+) **Frontend guard still works**: The `useRestoreSizeGuard` hook checks size regardless of storage tier, so warnings are consistent
- (-) **More complex Edge Function**: `list-prefixes` must query both prefixes, merge results, and detect multi-part groupings. Slightly more code than two separate endpoints.
- (-) **Hot/archive distinction can confuse**: If a non-technical user doesn't notice the ZIP icon, they might wonder why some albums take 48 hours. Clear labels mitigate this.
