# tyrum.ai

Public marketing site and installer endpoint for Tyrum.

## Domains

- `tyrum.ai`: marketing site
- `www.tyrum.ai`: redirects to `tyrum.ai`
- `get.tyrum.ai`: serves `/install.sh`
- `docs.tyrum.ai`: documentation site
- `tyrum.com` and `www.tyrum.com`: redirect to `tyrum.ai`
- `docs.tyrum.com`: documentation alias

## Local development

```bash
npm install
npm run dev
```

Build:

```bash
npm run build
```

## Installer contract

Canonical installer URL:

```bash
curl -fsSL https://get.tyrum.ai/install.sh | bash
```

`public/install.sh` should match the installer behavior from the product repo.

## Deployment

Deploy this repository to Cloudflare Pages:

- Build command: `npm run build`
- Output directory: `dist`
- Custom domains (Pages): `tyrum.ai`, `get.tyrum.ai`
- Pages project name used by CI: `tyrum-ai-marketing`

Set GitHub repository secrets for deploy workflow:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Canonical host redirects (for example `www.tyrum.ai` -> `tyrum.ai`) are managed by Cloudflare Worker routes from the infra workflow (`cloudflare-infra.yml`).

## Cloudflare Infra Automation (DNS + Redirect Worker)

This repo includes API automation for DNS records plus Worker script/route management:

- Script: `scripts/cloudflare/apply-infra.sh`
- Worker module: `workers/canonical-redirect.mjs`
- Workflow: `.github/workflows/cloudflare-infra.yml`

It also ensures Cloudflare Pages projects have required custom domains (`tyrum.ai`, `get.tyrum.ai`, `docs.tyrum.ai`, `docs.tyrum.com`). If these are missing, requests can fail with a Cloudflare `522` even if the Pages `*.pages.dev` site works.

Required GitHub Secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_ZONE_ID_TYRUM_AI`
- `CLOUDFLARE_ZONE_ID_TYRUM_COM`

Optional GitHub Variables:

- `MARKETING_PAGES_PROJECT` (default: `tyrum-ai-marketing`)
- `MARKETING_PAGES_HOST` (default: `tyrum-ai-marketing.pages.dev`)
- `DOCS_PAGES_PROJECT` (default: `tyrum-docs`)
- `DOCS_PAGES_HOST` (default: `tyrum-docs.pages.dev`)
- `WORKER_NAME` (default: `tyrum-host-redirects`)
- `WORKER_COMPAT_DATE` (default: `2026-02-18`)

Local run example:

```bash
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ACCOUNT_ID=...
export CLOUDFLARE_ZONE_ID_TYRUM_AI=...
export CLOUDFLARE_ZONE_ID_TYRUM_COM=...
bash scripts/cloudflare/apply-infra.sh
```
