import test from 'node:test';
import assert from 'node:assert/strict';
import { createAiProxy } from './local_ai_proxy.mjs';

test('loopback proxy forwards text only and blocks browser/invalid requests', async (t) => {
  const seen = [];
  const server = createAiProxy(async (text) => { seen.push(text); return { answer: '{"reply":"ok"}' }; });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await (await fetch(`${url}/health`)).json()).ready, true);
  const call = (body, extra = {}) => fetch(`${url}/ai`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...extra }, body: JSON.stringify(body) });
  assert.equal((await call({ text: 'hello' }, { Origin: 'https://example.com' })).status, 403);
  assert.equal((await call({ model: 'untrusted' })).status, 400);
  const response = await call({ text: 'hello', apiKey: 'ignored', model: 'ignored' });
  assert.deepEqual(await response.json(), { answer: '{"reply":"ok"}' });
  assert.deepEqual(seen, ['hello']);
});

test('upstream errors never expose exception content', async (t) => {
  const server = createAiProxy(async () => { throw new Error('private upstream detail'); });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/ai`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text: 'hello' }) });
  assert.equal(response.status, 502);
  assert.equal((await response.text()).includes('private upstream detail'), false);
});

async function start(t, forward, options) {
  const server = createAiProxy(forward, options);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}`;
  return {
    call: (body = { text: 'synthetic' }, token) => fetch(`${url}/ai`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', ...(token === undefined ? {} : { 'x-itkan-client': token }) }, body: JSON.stringify(body),
    }),
    health: async () => (await fetch(`${url}/health`)).json(),
  };
}

test('request budget counts failed upstream attempts but not invalid input', async (t) => {
  let calls = 0;
  const client = await start(t, async () => {
    calls++;
    return calls === 1 ? { status: 429 } : { answer: 'ok' };
  }, { maxRequests: 2 });
  assert.equal((await client.call({})).status, 400);
  assert.equal((await client.call()).status, 429);
  assert.equal((await client.call()).status, 200);
  assert.equal((await client.call()).status, 429);
  assert.equal(calls, 2);
  assert.equal((await client.health()).limits.remaining, 0);
});

test('minute rate window recovers without resetting lifetime budget', async (t) => {
  let clock = Date.UTC(2026, 10, 9);
  const client = await start(t, async () => ({ answer: 'ok' }), {
    now: () => clock, requestsPerMinute: 1, maxRequests: 3,
  });
  assert.equal((await client.call()).status, 200);
  assert.equal((await client.call()).status, 429);
  clock += 60000;
  assert.equal((await client.call()).status, 200);
  assert.equal((await client.health()).limits.attempted, 2);
});

test('health separates process readiness from observed upstream outcome', async (t) => {
  let fails = false;
  let clock = Date.UTC(2026, 10, 9);
  const client = await start(t, async () => {
    if (fails) throw new Error('private failure');
    return { answer: 'ok' };
  }, { now: () => clock });
  const initial = await client.health();
  assert.equal(initial.ready, true);
  assert.equal(initial.readiness, 'process_only');
  assert.equal(initial.upstream.status, 'not_checked');
  assert.equal(initial.upstream.lastSuccessAt, null);
  await client.call();
  const successful = await client.health();
  assert.equal(successful.upstream.status, 'ok');
  assert.equal(successful.upstream.lastSuccessAt, new Date(clock).toISOString());
  fails = true;
  clock += 1000;
  await client.call();
  const failed = await client.health();
  assert.equal(failed.upstream.status, 'failed');
  assert.equal(failed.upstream.lastSuccessAt, successful.upstream.lastSuccessAt);
  assert.equal(JSON.stringify(failed).includes('private'), false);
});

test('two active requests remain the maximum and reserve budget atomically', async (t) => {
  const pending = [];
  const client = await start(t, () => new Promise((resolve) => pending.push(resolve)), { maxRequests: 2 });
  const first = client.call();
  while (pending.length < 1) await new Promise((resolve) => setImmediate(resolve));
  const second = client.call();
  while (pending.length < 2) await new Promise((resolve) => setImmediate(resolve));
  assert.equal((await client.call()).status, 429);
  pending.forEach((resolve) => resolve({ answer: 'ok' }));
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  assert.equal((await client.call()).status, 429);
  assert.equal((await client.health()).limits.attempted, 2);
});

test('request limits must be finite positive integers', () => {
  for (const maxRequests of [0, -1, Infinity, 1.5]) {
    assert.throws(() => createAiProxy(async () => ({ answer: 'ok' }), { maxRequests }), TypeError);
  }
});

test('local client authentication rejects unrelated callers before forwarding or budget use', async (t) => {
  const token = 'a'.repeat(64); // Synthetic fixture, never a provider credential.
  let calls = 0;
  const client = await start(t, async () => { calls++; return { answer: 'ok' }; }, { authToken: token });
  assert.equal((await client.call()).status, 401);
  assert.equal((await client.call({}, 'b'.repeat(64))).status, 401);
  assert.equal((await client.call({}, 'short')).status, 401);
  assert.equal(calls, 0);
  const initial = await client.health();
  assert.equal(initial.clientAuthentication, 'local_token');
  assert.equal(initial.limits.attempted, 0);
  assert.equal(JSON.stringify(initial).includes(token), false);
  assert.equal((await client.call({ text: 'synthetic' }, token)).status, 200);
  assert.equal(calls, 1);
});

test('explicit weak client tokens are rejected instead of silently disabling authentication', () => {
  for (const authToken of ['', null, 123, 'short']) {
    assert.throws(() => createAiProxy(async () => ({ answer: 'ok' }), { authToken }), TypeError);
  }
});
