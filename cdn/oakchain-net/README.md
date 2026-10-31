# oakchain.net CDN

Production delivery for the Oak Chain public docs (`oak-chain-docs-eds`).

```text
Namecheap (registrar)
  -> Cloudflare DNS, zone oakchain.net (Free plan; margaret/simon.ns.cloudflare.com)
     -> Worker oak-chain-docs-cdn, route oakchain.net/*
        -> origin main--oak-chain-docs-eds--somarc.aem.live
```

Cloudflare account: `cc5a1a611277f98ee842200a4132efe6` (mc.hess@gmail.com).

## Worker (this directory)

`src/index.mjs` is Adobe's
[aem-cloudflare-prod-worker](https://github.com/adobe/aem-cloudflare-prod-worker),
unmodified, from commit `ec7387c0cd57e0b512e395f3ac5d163aa754356b`
(2026-10-20). Apache-2.0, see `LICENSE_APACHE`.

Deploy (wrangler OAuth login needs `workers_scripts:write` and
`workers_routes:write`):

```bash
cd oak-chain-infra/cdn/oakchain-net
npx wrangler@latest deploy
```

To update, copy `src/index.mjs` from upstream, record the new commit here,
and deploy.

## Zone settings (dashboard state, not in code)

Set on 2026-10-30, following
<https://www.aem.live/docs/byo-cdn-cloudflare-worker-setup>.

| Area | Setting |
| --- | --- |
| DNS | `oakchain.net` CNAME `main--oak-chain-docs-eds--somarc.aem.live`, proxied |
| DNS | `www` CNAME `oakchain.net`, proxied (only so the redirect can run) |
| SSL/TLS | Full (strict); Always Use HTTPS on; Universal SSL edge certificate |
| Caching | Caching level Standard; Browser Cache TTL "Respect Existing Headers" |
| Cache rule | `(http.host eq "oakchain.net")`: eligible for cache, browser TTL respects origin |
| Redirect rule | `https://www.oakchain.net/*` to `https://oakchain.net/${1}`, 301, query string kept |
| Scrape Shield | Email Address Obfuscation off: its injected script has no nonce, so the site's `strict-dynamic` CSP blocks it and obfuscated `mailto` links break |
| Bots | Bot Preference Sync off, so the site's own `robots.txt` is served unchanged |

No uploaded certificate. Cloudflare issues the edge certificate after the
zone activates, and the origin presents its own `aem.live` certificate.
Uploading custom certificates needs the Business plan.

## Push invalidation (not enabled yet)

`PUSH_INVALIDATION = "disabled"` keeps the origin's short cache TTLs, so
published changes appear within minutes without purging. To enable instant
purge on publish:

1. Create a Cloudflare API token: Zone, Cache Purge, Purge, limited to
   `oakchain.net`.
2. Register it in the AEM site CDN config (`cdn.prod`: host `oakchain.net`,
   type `cloudflare`, plan `free`, zone ID, token). See
   <https://www.aem.live/docs/setup-byo-cdn-push-invalidation-for-cloudflare>.
   On the Free plan every publish purges the whole zone.
3. Validate with <https://tools.aem.live/tools/push-invalidation/index.html?type=cloudflare>.
4. Set `PUSH_INVALIDATION = "enabled"` in `wrangler.toml` and deploy.

## Verify

```bash
dig +short NS oakchain.net                              # margaret/simon.ns.cloudflare.com
curl -sI https://oakchain.net/ | grep -iE '^HTTP|cf-ray|x-robots'   # 200, cf-ray, no x-robots-tag
curl -sI https://www.oakchain.net/x?y=1 | grep -iE '^HTTP|location'  # 301 -> https://oakchain.net/x?y=1
curl -sI http://oakchain.net/ | grep -iE '^HTTP|location'           # 301 -> https://oakchain.net/
curl -sI https://oakchain.net/drafts/x | head -1                     # 404 (blocked by the worker)
```

## History

- 2026-02-05: registered at Namecheap. The registrant email was never
  verified, so Namecheap suspended the domain by repointing its nameservers
  to `verify-contact-details` / `failed-whois-verification.namecheap.com`.
- 2026-03-24: zone first added to Cloudflare. It never activated, and the
  Free plan deleted it after 28 days pending.
- 2026-10-30: zone added again with the settings above, and worker deployed.
- 2026-10-31: registrant contact verified at Namecheap and the nameservers set
  to Cloudflare (registry updated 19:26 UTC). The zone activated about 6
  minutes later, and the Let's Encrypt edge certificate covers `oakchain.net`
  and `*.oakchain.net`. All the Verify checks pass, and canonical/`og:url`
  follow the forwarded host. The sitemap `<loc>` entries still use the
  `aem.live` origin set in `oak-chain-docs-eds/helix-sitemap.yaml`.
