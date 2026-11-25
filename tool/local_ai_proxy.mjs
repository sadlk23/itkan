import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { timingSafeEqual } from 'node:crypto';

const service = 'my-fridge-local-ai-proxy';

export function createAiProxy(forward, {
  maxRequests = 200,
  requestsPerMinute = 20,
  now = Date.now,
  authToken,
} = {}) {
  if (!Number.isSafeInteger(maxRequests) || maxRequests < 1 ||
      !Number.isSafeInteger(requestsPerMinute) || requestsPerMinute < 1 ||
      typeof now !== 'function') throw new TypeError('Valid finite request limits and clock are required.');
  if (authToken !== undefined && (typeof authToken !== 'string' || authToken.length < 32)) {
    throw new TypeError('A local client token of at least 32 characters is required.');
  }
  const expectedToken = authToken === undefined ? null : Buffer.from(authToken, 'utf8');
  let active = 0;
  let attempted = 0;
  let recentAttempts = [];
  let upstreamStatus = 'not_checked';
  let lastSuccessAt = null;
  let lastAttemptAt = null;
  return http.createServer(async (req, res) => {
    const reply = (status, value) => {
      if (!res.destroyed) {
        res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
        res.end(JSON.stringify(value));
      }
    };
    // Browser pages must not be able to spend the local development account.
    if (req.headers.origin) return reply(403, { error: 'Browser requests are disabled.' });
    if (req.url === '/health' && req.method === 'GET') return reply(200, {
      service,
      ready: true, // Compatibility: means process readiness, not valid credentials/quota.
      readiness: 'process_only',
      clientAuthentication: expectedToken === null ? 'disabled' : 'local_token',
      upstream: { status: upstreamStatus, lastAttemptAt, lastSuccessAt },
      limits: { maxRequests, requestsPerMinute, attempted, remaining: maxRequests - attempted },
    });
    if (req.url !== '/ai' || req.method !== 'POST') return reply(404, { error: 'Not found.' });
    if (expectedToken !== null) {
      const supplied = req.headers['x-itkan-client'];
      const received = typeof supplied === 'string' ? Buffer.from(supplied, 'utf8') : Buffer.alloc(0);
      if (received.length !== expectedToken.length || !timingSafeEqual(received, expectedToken)) {
        return reply(401, { error: 'Local client authentication required.' });
      }
    }
    if (!req.headers['content-type']?.startsWith('application/json')) return reply(415, { error: 'JSON required.' });
    if (active >= 2) return reply(429, { error: 'Another request is running. Please retry.' });
    active++;
    let upstreamAttempted = false;
    try {
      const chunks = [];
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 131072) return reply(413, { error: 'Request too large.' });
        chunks.push(chunk);
      }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { return reply(400, { error: 'Invalid JSON.' }); }
      if (typeof body?.text !== 'string' || !body.text.trim()) return reply(400, { error: 'Text required.' });
      const at = now();
      recentAttempts = recentAttempts.filter((time) => time > at - 60000);
      if (attempted >= maxRequests) return reply(429, { error: 'This local session request budget is exhausted.' });
      if (recentAttempts.length >= requestsPerMinute) return reply(429, { error: 'Request rate limit reached. Please retry later.' });
      // Reserve before awaiting upstream so simultaneous calls cannot overspend.
      // Failed attempts count too: they can still consume upstream resources.
      attempted++;
      recentAttempts.push(at);
      lastAttemptAt = new Date(at).toISOString();
      upstreamAttempted = true;
      const result = await forward(body.text);
      if (typeof result.answer !== 'string') {
        upstreamStatus = 'failed';
        return reply(result.status ?? 502, { error: 'AI request failed. Please retry.' });
      }
      upstreamStatus = 'ok';
      lastSuccessAt = new Date(now()).toISOString();
      return reply(200, { answer: result.answer });
    } catch {
      if (upstreamAttempted) upstreamStatus = 'failed';
      return reply(502, { error: 'AI connection unavailable. Please retry.' });
    } finally {
      active--;
    }
  });
}

async function main() {
  // Only this host process reads the secret. It never enters the mobile build.
  const config = JSON.parse(await readFile(new URL('../config/ai.local.json', import.meta.url), 'utf8'));
  if (config.AI_BASE_URL !== 'https://api.openai.com/v1/responses' ||
      config.AI_API_FORMAT !== 'response' || !config.AI_API_KEY || !config.AI_MODEL) {
    throw new Error('Local OpenAI Responses configuration is required.');
  }
  // This is an extractable development client token, NOT the provider key.
  // It blocks unrelated local callers but does not replace production identity.
  const clientConfig = JSON.parse(await readFile(new URL('../config/ai.emulator.json', import.meta.url), 'utf8'));
  if (typeof clientConfig.AI_PROXY_TOKEN !== 'string' || !/^[a-f0-9]{64}$/.test(clientConfig.AI_PROXY_TOKEN)) {
    throw new Error('Prepare the local development client token before starting the proxy.');
  }
  const server = createAiProxy(async (text) => {
    const response = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.AI_API_KEY}` },
      body: JSON.stringify({ model: config.AI_MODEL, input: text, store: false, max_output_tokens: 4000 }),
      signal: AbortSignal.timeout(35000),
    });
    if (!response.ok) return { status: [401, 403, 429].includes(response.status) ? response.status : 502 };
    const result = await response.json();
    if (result.status === 'incomplete') return { status: 502 };
    const answer = (result.output ?? []).flatMap((item) => item.type === 'message' ? (item.content ?? []) : [])
      .filter((item) => item.type === 'output_text').map((item) => item.text).join('');
    return answer ? { answer } : { status: 502 };
  }, { authToken: clientConfig.AI_PROXY_TOKEN });
  server.on('error', () => { process.stderr.write('Local AI proxy could not start.\n'); process.exitCode = 1; });
  server.listen(8787, '127.0.0.1', () => process.stdout.write('Local AI proxy ready on loopback port 8787.\n'));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { process.stderr.write('Local AI proxy setup failed. Check local configuration.\n'); process.exitCode = 1; });
}
