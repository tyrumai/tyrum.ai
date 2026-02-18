# tyrum.ai

Public marketing site and installer endpoint for Tyrum.

## Domains

- `tyrum.ai`: marketing site
- `www.tyrum.ai`: redirects to `tyrum.ai`
- `get.tyrum.ai`: serves `/install.sh`
- `tyrum.com` and `www.tyrum.com`: redirect to `tyrum.ai`

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
- Custom domains: `tyrum.ai`, `www.tyrum.ai`, `get.tyrum.ai`
- Pages project name used by CI: `tyrum-ai-marketing`

Set GitHub repository secrets for deploy workflow:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Set redirect rules for `tyrum.com` and `www.tyrum.com` to `https://tyrum.ai`.
