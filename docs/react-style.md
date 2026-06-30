# React Style Guide

## Principles

- All UI is declared in `.tsx` files — no raw HTML outside components
- All styling via Tailwind utility classes — no raw CSS files beyond `src/index.css` with the three `@tailwind` directives
- No `<style>` tags in components
- Every component is typed with TypeScript
- State management via TanStack Query for server state, `useState`/`useReducer` for local UI state
- Components are reusable by default — declare once, use many. If a pattern appears twice, extract it into a shared component.

## Directory Structure

```
src/
├── components/          # Reusable UI components
│   ├── AlbumCard.tsx
│   ├── RestoreButton.tsx
│   ├── StatusBadge.tsx
│   ├── PartList.tsx
│   ├── SizeGuardBanner.tsx
│   └── DownloadList.tsx
├── hooks/               # Custom React hooks
│   ├── useAlbums.ts
│   ├── useRestoreStatus.ts
│   ├── useRestoreSizeGuard.ts
│   └── useSupabase.ts
├── lib/                 # Non-React utilities and clients
│   ├── styles.ts         # Reusable Tailwind class patterns (button styles, card variants, badges)
│   ├── supabase.ts       # Supabase client
│   └── types.ts          # Shared TypeScript types
├── pages/               # Route-level page components
│   ├── Login.tsx
│   ├── Albums.tsx
│   └── ActiveRestores.tsx
├── App.tsx
└── main.tsx
```

## Component Conventions

### Structure

```tsx
// AlbumCard.tsx — one component per file, named export
export function AlbumCard({ album }: AlbumCardProps) {
  return (
    <div className="rounded-lg border p-4">
      <h2 className="text-lg font-semibold">{album.name}</h2>
    </div>
  )
}

interface AlbumCardProps {
  album: Album
}
```

- Default export: never. Only named exports.
- Props interface: same name as component + `Props` suffix, defined above or below component.
- One component per file.
- File name matches component name (PascalCase).
- Extract any UI pattern used more than once into a shared component in `src/components/`. Compound components (e.g. `AlbumCard.Image`, `AlbumCard.Meta`) are encouraged for related variants.

### Tailwind Usage

```tsx
// Correct — all styling in className strings
<div className="flex items-center gap-2 rounded-md bg-blue-50 p-3 text-sm text-blue-700">

// Incorrect — no raw style tags or separate CSS
<div style={{ display: 'flex' }}>   // never
```

- Use Tailwind class composition with `cn()` helper (from `clsx` + `tailwind-merge`).
- Reusable class patterns (button styles, card variants, badge colors, layout wrappers) go in `src/lib/styles.ts` as exported const strings or `cn()` calls. Import them in TSX files instead of duplicating class strings.
- Repeated inline class combinations should be extracted to a named const — either in the component file for single-use or in `styles.ts` for shared use.

### Conditional Classes

```tsx
<div className={cn(
  "rounded-lg border p-4 transition-colors",
  isReady && "border-green-300 bg-green-50",
  isRestoring && "border-yellow-300 bg-yellow-50",
)}>
```

## Hook Conventions

```tsx
// useRestoreSizeGuard.ts
export function useRestoreSizeGuard(albumTotalSizeBytes: number) {
  const MONTHLY_FREE_EGRESS = 100 * 1024 * 1024 * 1024
  const usagePercent = (albumTotalSizeBytes / MONTHLY_FREE_EGRESS) * 100

  return {
    canRestore: usagePercent <= 100,
    usagePercent,
    warning: usagePercent > 10
      ? `This restore is ${formatSize(albumTotalSizeBytes)} (${usagePercent.toFixed(0)}% of your 100 GB monthly free limit).`
      : null,
    criticalWarning: usagePercent > 80
      ? `This restore exceeds 80% of your monthly free egress. Remaining budget: ${formatSize(MONTHLY_FREE_EGRESS - albumTotalSizeBytes)}.`
      : null,
  }
}
```

- Prefix with `use` (convention).
- Colocate hooks with their domain.
- Return plain objects, not JSX.
- Hooks call TanStack Query (`useQuery`, `useMutation`) for all server-state.

## TanStack Query Patterns

```tsx
// useAlbums.ts
export function useAlbums() {
  return useQuery({
    queryKey: ["albums"],
    queryFn: async () => {
      const { data, error } = await supabase.functions.invoke("list-prefixes")
      if (error) throw error
      return data as Album[]
    },
    staleTime: 1000 * 60 * 5,  // 5 min cache
  })
}
```

- All Edge Function calls go through custom hooks.
- Use `staleTime` generously — album listings change infrequently.
- Mutations (restore, delete, upload) use `useMutation` with `onSuccess` invalidation.

## TypeScript Types

```tsx
// lib/types.ts
export interface Album {
  id: string
  name: string
  type: "hot" | "archive"
  totalSize: string
  parts?: AlbumPart[]
}

export interface AlbumPart {
  fileName: string
  size: string
  partNumber: number
}

export interface RestoreStatus {
  albumId: string
  state: "pending" | "restoring" | "ready" | "expired"
  partsReady: number
  totalParts: number
}
```

---

## Testing Strategy

### Vitest (Unit + Integration)

Test hooks, utility functions, and component rendering in isolation.

**Setup**:
```
npm install -D vitest @testing-library/react @testing-library/jest-dom happy-dom
```

**vitest.config.ts** (or inside `vite.config.ts`):
```ts
test: {
  environment: "happy-dom",
  globals: true,
  setupFiles: ["./src/test/setup.ts"],
}
```

**Hook tests**:
```tsx
// __tests__/useRestoreSizeGuard.test.ts
import { renderHook } from "@testing-library/react"
import { describe, it, expect } from "vitest"
import { useRestoreSizeGuard } from "../hooks/useRestoreSizeGuard"

describe("useRestoreSizeGuard", () => {
  it("returns no warning for small albums", () => {
    const { result } = renderHook(() => useRestoreSizeGuard(1024 * 1024 * 100)) // 100 MB
    expect(result.current.warning).toBeNull()
    expect(result.current.canRestore).toBe(true)
  })

  it("warns when album exceeds 10% of monthly limit", () => {
    const { result } = renderHook(() => useRestoreSizeGuard(15 * 1024 * 1024 * 1024)) // 15 GB
    expect(result.current.warning).toContain("15%")
  })

  it("blocks restore when album exceeds 100 GB", () => {
    const { result } = renderHook(() => useRestoreSizeGuard(120 * 1024 * 1024 * 1024)) // 120 GB
    expect(result.current.canRestore).toBe(false)
  })
})
```

**Component tests**:
```tsx
// __tests__/SizeGuardBanner.test.tsx
import { render, screen } from "@testing-library/react"
import { SizeGuardBanner } from "../components/SizeGuardBanner"

describe("SizeGuardBanner", () => {
  it("shows warning when usage is high", () => {
    render(<SizeGuardBanner usagePercent={85} />)
    expect(screen.getByText(/80%/)).toBeTruthy()
  })
})
```

**File co-location**: Tests live in `src/__tests__/` or next to the file as `Component.test.tsx`.

### Playwright (E2E)

Test full user flows against the real app (local dev server or deployed GitHub Pages).

**Setup**:
```
npm install -D @playwright/test
npx playwright install
```

**playwright.config.ts**:
```ts
import { defineConfig } from "@playwright/test"
export default defineConfig({
  testDir: "./e2e",
  webServer: {
    command: "npm run dev",
    port: 5173,
    reuseExistingServer: true,
  },
})
```

**Login flow**:
```ts
// e2e/login.spec.ts
import { test, expect } from "@playwright/test"

test("user can log in via magic link", async ({ page }) => {
  await page.goto("/")
  await page.fill("[data-testid=email-input]", "test@example.com")
  await page.click("[data-testid=send-magic-link]")
  await expect(page.locator("[data-testid=check-email]")).toBeVisible()
})
```

**Restore flow**:
```ts
test("user can restore an album", async ({ page }) => {
  await page.goto("/")
  // login via Supabase (use API to create session for testing)
  // navigate to album
  await page.click('[data-testid="restore-2024-03-March"]')
  await expect(page.locator("[data-testid=restore-status]")).toContainText("Restoring")
  // poll until ready (or mock the Edge Function response)
})
```

**What to test end-to-end**:
- Magic link login (email sent, link clicked)
- Album list loads and displays hot + archive albums
- Multi-part album shows correct part count
- Restore button shows size guard warning when appropriate
- Restore status polling transitions from "restoring" → "ready"
- Download buttons appear for restored parts
- Upload flow (select file, upload, confirm in listing)

### Running Tests

```bash
# Unit + integration
npm run test              # vitest (single run)
npm run test:watch        # vitest (watch mode)

# E2E
npm run test:e2e          # playwright
npm run test:e2e:ui       # playwright UI mode

# All
npm run test:all
```

**Suggested package.json scripts**:
```json
{
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest",
    "test:e2e": "playwright test",
    "test:e2e:ui": "playwright test --ui",
    "test:all": "vitest run && playwright test"
  }
}
```

## Test Data Strategy

- Use factories or fixtures for album data, not real S3 calls
- Mock Supabase Edge Functions with `vi.mock` in Vitest
- For Playwright, use Playwright route interception to mock Edge Function responses
- Keep a `src/test/fixtures/` directory with sample album/part responses

```ts
// src/test/fixtures/albums.ts
export const mockAlbums: Album[] = [
  {
    id: "archive/2024",
    name: "March 2024",
    type: "archive",
    totalSize: "28.5 GB",
    parts: [
      { fileName: "2024-03-March.part1.zip", size: "10 GB", partNumber: 1 },
      { fileName: "2024-03-March.part2.zip", size: "10 GB", partNumber: 2 },
      { fileName: "2024-03-March.part3.zip", size: "8.5 GB", partNumber: 3 },
    ],
  },
]
```
