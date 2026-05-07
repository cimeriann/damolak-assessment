const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const app = require('../src/server');

function request(server, path) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    http
      .get(`http://127.0.0.1:${port}${path}`, (res) => {
        let body = '';
        res.on('data', (chunk) => (body += chunk));
        res.on('end', () => resolve({ status: res.statusCode, body }));
      })
      .on('error', reject);
  });
}

test('GET /healthz returns 200', async () => {
  const server = app.listen(0);
  try {
    const res = await request(server, '/healthz');
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(JSON.parse(res.body), { status: 'ok' });
  } finally {
    server.close();
  }
});

test('GET / returns service metadata', async () => {
  const server = app.listen(0);
  try {
    const res = await request(server, '/');
    assert.strictEqual(res.status, 200);
    const payload = JSON.parse(res.body);
    assert.strictEqual(payload.service, 'assessment-app');
    assert.ok(payload.commit);
  } finally {
    server.close();
  }
});

test('GET /version returns commit', async () => {
  const server = app.listen(0);
  try {
    const res = await request(server, '/version');
    assert.strictEqual(res.status, 200);
    const payload = JSON.parse(res.body);
    assert.ok(payload.commit);
  } finally {
    server.close();
  }
});
