// Minimal HTTP client for the consensus harness: bounded timeouts, explicit redirect
// handling (307/308 keep method and body, as the validators' leader redirect expects),
// and failures reported as status 0 rather than thrown. Callers decide what UNKNOWN means.

const REDIRECTS_PRESERVING_METHOD = new Set([307, 308]);

export function createHttp({ fetchImpl = globalThis.fetch, timeoutMs = 3_000 } = {}) {
  async function request(url, { form = null, headers = {}, maxRedirects = 3, method = 'GET', timeout = timeoutMs } = {}) {
    const body = form ? new URLSearchParams(form).toString() : undefined;
    const requestHeaders = { Accept: 'application/json', ...headers };
    if (form) requestHeaders['Content-Type'] = 'application/x-www-form-urlencoded';
    const hops = [];
    let target = url;

    for (let attempt = 0; attempt <= maxRedirects; attempt += 1) {
      let response;
      try {
        response = await fetchImpl(target, {
          body,
          headers: requestHeaders,
          method,
          redirect: 'manual',
          signal: AbortSignal.timeout(timeout),
        });
      } catch (error) {
        return { error: error instanceof Error ? error.message : String(error), hops, json: null, ok: false, status: 0, text: '', url: target };
      }

      const location = response.headers.get('location');
      if (REDIRECTS_PRESERVING_METHOD.has(response.status) && location) {
        const next = new URL(location, target).toString();
        hops.push({ from: target, status: response.status, to: next });
        target = next;
        continue;
      }

      const text = await response.text();
      let json = null;
      try {
        json = text ? JSON.parse(text) : null;
      } catch (_error) {
        json = null;
      }
      return { error: null, hops, json, ok: response.ok, status: response.status, text, url: target };
    }
    return { error: `more than ${maxRedirects} redirects`, hops, json: null, ok: false, status: 0, text: '', url: target };
  }

  return { request };
}

// Validators report peers as http://localhost:PORT while the harness addresses
// 127.0.0.1; compare host-normalized URLs.
export function normalizeNodeUrl(value) {
  if (!value) return null;
  try {
    const url = new URL(String(value));
    const host = url.hostname === 'localhost' ? '127.0.0.1' : url.hostname;
    return `${url.protocol}//${host}:${url.port}`;
  } catch (_error) {
    return String(value);
  }
}
