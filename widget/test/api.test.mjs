import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSearchClient, debounce } from './.api.build.mjs';

test('out-of-order responses are discarded', async () => {
  const resolvers = [];
  const fakeFetch = () => new Promise((resolve) => resolvers.push(resolve));
  const client = createSearchClient({ api: 'http://x', key: 'k' }, fakeFetch);

  const first = client.search('a');
  const second = client.search('ab');

  resolvers[0]({ ok: true, json: async () => ({ results: [{ id: '1', title: 'stale' }] }) });
  resolvers[1]({ ok: true, json: async () => ({ results: [{ id: '2', title: 'fresh' }] }) });

  assert.equal(await first, null); // superseded
  assert.equal((await second)[0].id, '2');
});

test('failed search returns empty list, never throws', async () => {
  const client = createSearchClient(
    { api: 'http://x', key: 'k' },
    () => Promise.reject(new Error('down'))
  );
  assert.deepEqual(await client.search('ab'), []);
});

test('non-ok response returns empty list', async () => {
  const client = createSearchClient(
    { api: 'http://x', key: 'k' },
    async () => ({ ok: false, status: 401, json: async () => ({}) })
  );
  assert.deepEqual(await client.search('ab'), []);
});

test('debounce fires once with the last args', async () => {
  const calls = [];
  const d = debounce((v) => calls.push(v), 10);
  d('a'); d('ab'); d('abc');
  await new Promise((r) => setTimeout(r, 40));
  assert.deepEqual(calls, ['abc']);
});

test('track never throws even when fetch is broken', () => {
  const client = createSearchClient(
    { api: 'http://x', key: 'k' },
    () => { throw new Error('boom'); }
  );
  client.track({ id: 1, title: 'X' }); // must not throw
});

test('safeUrl only allows http(s)', async () => {
  const { safeUrl } = await import('./.api.build.mjs');
  assert.equal(safeUrl('https://ok.com/x'), 'https://ok.com/x');
  assert.equal(safeUrl('http://ok.com/x'), 'http://ok.com/x');
  assert.equal(safeUrl('javascript:alert(1)'), undefined);
  assert.equal(safeUrl('data:text/html,x'), undefined);
  assert.equal(safeUrl(undefined), undefined);
  assert.equal(safeUrl('/relative/path'), '/relative/path');
});
