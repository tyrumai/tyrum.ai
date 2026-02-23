#!/usr/bin/env bash
set -euo pipefail

CF_API_BASE="https://api.cloudflare.com/client/v4"
WORKER_ENTRYPOINT="workers/canonical-redirect.mjs"
WORKER_MAIN_MODULE="canonical-redirect.mjs"
WORKER_COMPAT_DATE="${WORKER_COMPAT_DATE:-2026-02-18}"
WORKER_NAME="${WORKER_NAME:-tyrum-host-redirects}"
MARKETING_PAGES_PROJECT="${MARKETING_PAGES_PROJECT:-tyrum-ai-marketing}"
MARKETING_PAGES_HOST="${MARKETING_PAGES_HOST:-tyrum-ai-marketing.pages.dev}"
DOCS_PAGES_PROJECT="${DOCS_PAGES_PROJECT:-tyrum-docs}"
DOCS_PAGES_HOST="${DOCS_PAGES_HOST:-tyrum-docs.pages.dev}"
EXTRA_REDIRECT_APEX_DOMAINS="${EXTRA_REDIRECT_APEX_DOMAINS:-}"
CLOUDFLARE_ZONE_ID_MAP="${CLOUDFLARE_ZONE_ID_MAP:-}"

usage() {
  cat <<'USAGE'
Apply Tyrum DNS + redirect worker infrastructure in Cloudflare.

Required environment variables:
  CLOUDFLARE_API_TOKEN
  CLOUDFLARE_ACCOUNT_ID

Optional environment variables:
  CLOUDFLARE_ZONE_ID_TYRUM_AI (skips zone lookup for tyrum.ai)
  CLOUDFLARE_ZONE_ID_TYRUM_COM (skips zone lookup for tyrum.com)
  CLOUDFLARE_ZONE_ID_MAP (JSON map of zone name -> zone ID, ex: {"tyrum.ai":"...","tyrum.com":"..."})
  MARKETING_PAGES_PROJECT (default: tyrum-ai-marketing)
  MARKETING_PAGES_HOST  (default: tyrum-ai-marketing.pages.dev)
  DOCS_PAGES_PROJECT    (default: tyrum-docs)
  DOCS_PAGES_HOST       (default: tyrum-docs.pages.dev)
  EXTRA_REDIRECT_APEX_DOMAINS (comma/space separated apex domains to redirect like tyrum.com, ex: "tyrum.app, tyrum.io")
  WORKER_NAME           (default: tyrum-host-redirects)
  WORKER_COMPAT_DATE    (default: 2026-02-18)

This script is idempotent: it upserts DNS records, deploys the Worker script,
and upserts Worker routes for canonical redirects.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "error: missing required command: $name" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "error: missing required environment variable: $name" >&2
    exit 1
  fi
}

cf_api_json() {
  local method="$1"
  local endpoint="$2"
  local payload="${3:-}"

  local args=(
    -sS
    -X "$method"
    "$CF_API_BASE$endpoint"
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    -H "Content-Type: application/json"
  )

  if [[ -n "$payload" ]]; then
    args+=(--data "$payload")
  fi

  local response
  response="$(curl "${args[@]}")"

  local success
  success="$(printf '%s' "$response" | jq -r '.success // false')"

  if [[ "$success" != "true" ]]; then
    echo "error: Cloudflare API request failed: $method $endpoint" >&2
    printf '%s' "$response" | jq -C '.' >&2 || printf '%s\n' "$response" >&2
    exit 1
  fi

  printf '%s' "$response"
}

normalize_zone_env_suffix() {
  local zone_name="$1"
  zone_name="${zone_name//./_}"
  zone_name="${zone_name//-/_}"
  printf '%s' "$zone_name" | tr '[:lower:]' '[:upper:]'
}

zone_id_for() {
  local zone_name="$1"

  if [[ -n "${CLOUDFLARE_ZONE_ID_MAP:-}" ]]; then
    local mapped
    mapped="$(printf '%s' "$CLOUDFLARE_ZONE_ID_MAP" | jq -r --arg name "$zone_name" '.[$name] // empty')"
    if [[ -n "$mapped" && "$mapped" != "null" ]]; then
      printf '%s' "$mapped"
      return 0
    fi
  fi

  local env_suffix
  env_suffix="$(normalize_zone_env_suffix "$zone_name")"
  local env_name="CLOUDFLARE_ZONE_ID_${env_suffix}"

  if [[ -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
    return 0
  fi

  local zones
  zones="$(cf_api_json GET "/zones?name=${zone_name}")"

  local found_id
  found_id="$(printf '%s' "$zones" | jq -r '.result[0].id // empty')"

  if [[ -z "$found_id" ]]; then
    echo "error: unable to resolve Cloudflare zone ID for ${zone_name}" >&2
    echo "       Provide ${env_name}, set CLOUDFLARE_ZONE_ID_MAP, or grant the API token Zone:Read." >&2
    exit 1
  fi

  printf '%s' "$found_id"
}

sanitize_apex_domain() {
  local domain="$1"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%.}"
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  domain="${domain#www.}"
  printf '%s' "$domain"
}

list_extra_redirect_domains() {
  local raw="${EXTRA_REDIRECT_APEX_DOMAINS:-}"
  if [[ -z "$raw" ]]; then
    return 0
  fi

  raw="${raw//,/ }"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\t'/ }"
  raw="${raw//$'\r'/ }"

  local domain
  for domain in $raw; do
    domain="$(sanitize_apex_domain "$domain")"
    if [[ -z "$domain" ]]; then
      continue
    fi
    if [[ "$domain" == "tyrum.ai" || "$domain" == "tyrum.com" ]]; then
      continue
    fi
    printf '%s\n' "$domain"
  done
}

ensure_pages_domain() {
  local project_name="$1"
  local domain_name="$2"

  local domains
  domains="$(cf_api_json GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${project_name}/domains")"

  local exists
  exists="$(printf '%s' "$domains" | jq -r --arg name "$domain_name" '((.result // []) | if type == "array" then any(.name == $name) else false end)')"

  if [[ "$exists" == "true" ]]; then
    echo "Pages domain already configured: ${domain_name} (project: ${project_name})"
    return 0
  fi

  local payload
  payload="$(jq -nc --arg name "$domain_name" '{name:$name}')"

  cf_api_json POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${project_name}/domains" "$payload" >/dev/null
  echo "Added Pages domain: ${domain_name} (project: ${project_name})"
}

upsert_dns_cname() {
  local zone_id="$1"
  local fqdn="$2"
  local content="$3"

  local lookup
  lookup="$(cf_api_json GET "/zones/${zone_id}/dns_records?type=CNAME&name=${fqdn}")"

  local payload
  payload="$(jq -nc \
    --arg name "$fqdn" \
    --arg content "$content" \
    '{type:"CNAME",name:$name,content:$content,ttl:1,proxied:true}')"

  local existing_id
  existing_id="$(printf '%s' "$lookup" | jq -r '.result[0].id // empty')"

  if [[ -n "$existing_id" ]]; then
    cf_api_json PUT "/zones/${zone_id}/dns_records/${existing_id}" "$payload" >/dev/null
    echo "updated DNS CNAME ${fqdn} -> ${content}"
  else
    cf_api_json POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
    echo "created DNS CNAME ${fqdn} -> ${content}"
  fi
}

deploy_worker_script() {
  local metadata
  metadata="$(jq -nc \
    --arg main_module "$WORKER_MAIN_MODULE" \
    --arg compatibility_date "$WORKER_COMPAT_DATE" \
    '{main_module:$main_module,compatibility_date:$compatibility_date}')"

  local response
  response="$(curl -sS \
    -X PUT "${CF_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -F "metadata=${metadata};type=application/json" \
    -F "${WORKER_MAIN_MODULE}=@${WORKER_ENTRYPOINT};type=application/javascript+module")"

  local success
  success="$(printf '%s' "$response" | jq -r '.success // false')"

  if [[ "$success" != "true" ]]; then
    echo "error: failed to deploy worker script ${WORKER_NAME}" >&2
    printf '%s' "$response" | jq -C '.' >&2 || printf '%s\n' "$response" >&2
    exit 1
  fi

  echo "deployed worker script ${WORKER_NAME}"
}

upsert_worker_route() {
  local zone_id="$1"
  local pattern="$2"

  local routes
  routes="$(cf_api_json GET "/zones/${zone_id}/workers/routes")"

  local existing_id
  existing_id="$(printf '%s' "$routes" | jq -r --arg pattern "$pattern" '.result[] | select(.pattern == $pattern) | .id' | head -n 1)"

  local payload
  payload="$(jq -nc --arg pattern "$pattern" --arg script "$WORKER_NAME" '{pattern:$pattern,script:$script}')"

  if [[ -n "$existing_id" ]]; then
    cf_api_json PUT "/zones/${zone_id}/workers/routes/${existing_id}" "$payload" >/dev/null
    echo "updated worker route ${pattern} -> ${WORKER_NAME}"
  else
    cf_api_json POST "/zones/${zone_id}/workers/routes" "$payload" >/dev/null
    echo "created worker route ${pattern} -> ${WORKER_NAME}"
  fi
}

require_cmd curl
require_cmd jq
require_env CLOUDFLARE_API_TOKEN
require_env CLOUDFLARE_ACCOUNT_ID

if [[ ! -f "$WORKER_ENTRYPOINT" ]]; then
  echo "error: worker entrypoint not found: $WORKER_ENTRYPOINT" >&2
  exit 1
fi

TYRUM_AI_ZONE_ID="$(zone_id_for "tyrum.ai")"
TYRUM_COM_ZONE_ID="$(zone_id_for "tyrum.com")"

echo "==> Upserting DNS records"
upsert_dns_cname "$TYRUM_AI_ZONE_ID" "tyrum.ai" "$MARKETING_PAGES_HOST"
upsert_dns_cname "$TYRUM_AI_ZONE_ID" "www.tyrum.ai" "$MARKETING_PAGES_HOST"
upsert_dns_cname "$TYRUM_AI_ZONE_ID" "get.tyrum.ai" "$MARKETING_PAGES_HOST"
upsert_dns_cname "$TYRUM_AI_ZONE_ID" "docs.tyrum.ai" "$DOCS_PAGES_HOST"

upsert_dns_cname "$TYRUM_COM_ZONE_ID" "tyrum.com" "$MARKETING_PAGES_HOST"
upsert_dns_cname "$TYRUM_COM_ZONE_ID" "www.tyrum.com" "$MARKETING_PAGES_HOST"
upsert_dns_cname "$TYRUM_COM_ZONE_ID" "docs.tyrum.com" "$DOCS_PAGES_HOST"

while IFS= read -r apex; do
  extra_zone_id="$(zone_id_for "$apex")"
  upsert_dns_cname "$extra_zone_id" "$apex" "$MARKETING_PAGES_HOST"
  upsert_dns_cname "$extra_zone_id" "www.${apex}" "$MARKETING_PAGES_HOST"
  upsert_dns_cname "$extra_zone_id" "docs.${apex}" "$DOCS_PAGES_HOST"
done < <(list_extra_redirect_domains | sort -u)

echo "==> Ensuring Cloudflare Pages custom domains"
ensure_pages_domain "$MARKETING_PAGES_PROJECT" "tyrum.ai"
ensure_pages_domain "$MARKETING_PAGES_PROJECT" "get.tyrum.ai"
ensure_pages_domain "$DOCS_PAGES_PROJECT" "docs.tyrum.ai"
ensure_pages_domain "$DOCS_PAGES_PROJECT" "docs.tyrum.com"

while IFS= read -r apex; do
  ensure_pages_domain "$DOCS_PAGES_PROJECT" "docs.${apex}"
done < <(list_extra_redirect_domains | sort -u)

echo "==> Deploying redirect Worker script"
deploy_worker_script

echo "==> Upserting redirect Worker routes"
upsert_worker_route "$TYRUM_AI_ZONE_ID" "www.tyrum.ai/*"
upsert_worker_route "$TYRUM_COM_ZONE_ID" "tyrum.com/*"
upsert_worker_route "$TYRUM_COM_ZONE_ID" "www.tyrum.com/*"

while IFS= read -r apex; do
  extra_zone_id="$(zone_id_for "$apex")"
  upsert_worker_route "$extra_zone_id" "${apex}/*"
  upsert_worker_route "$extra_zone_id" "www.${apex}/*"
done < <(list_extra_redirect_domains | sort -u)

echo "==> Cloudflare infrastructure apply complete"
