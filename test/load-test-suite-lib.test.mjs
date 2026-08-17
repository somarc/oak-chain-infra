import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const suiteLib = path.join(repoRoot, 'modes/mock/load-tests/suite-lib.sh');

async function startFixture() {
  const requests = [];
  let baseUrl;
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      requests.push({
        body: Buffer.concat(chunks).toString('utf8'),
        method: request.method,
        url: request.url,
      });
      if (request.url === '/v1/consensus/status') {
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ currentLeader: baseUrl }));
        return;
      }
      if (request.url === '/v1/register-client') {
        if (request.headers['x-reject-registration'] === 'true') {
          response.writeHead(409, { 'content-type': 'application/json' });
          response.end(JSON.stringify({ error: 'registration conflict' }));
          return;
        }
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ registered: true }));
        return;
      }
      if (request.url === '/redirect') {
        response.writeHead(307, { location: `${baseUrl}/accepted` });
        response.end();
        return;
      }
      if (request.url === '/accepted') {
        response.writeHead(202, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ accepted: true }));
        return;
      }
      response.writeHead(404).end();
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
  return {
    baseUrl,
    close: () => new Promise((resolve) => server.close(resolve)),
    requests,
  };
}

test('load-test registration resolves the leader and sends the selected client type', async () => {
  const fixture = await startFixture();
  const logDir = await mkdtemp(path.join(os.tmpdir(), 'oak-load-lib-'));
  try {
    await execFileAsync('bash', ['-c', `source "$SUITE_LIB"; register_client 0xabc 7 enterprise`], {
      env: {
        ...process.env,
        LOG_DIR: logDir,
        SUITE_LIB: suiteLib,
        VALIDATOR_URL: fixture.baseUrl,
      },
    });
    const registration = fixture.requests.find((entry) => entry.url === '/v1/register-client');
    assert.ok(registration);
    assert.equal(registration.method, 'POST');
    assert.match(registration.body, /clientId=client-7/);
    assert.match(registration.body, /clientType=enterprise/);
    assert.match(registration.body, /walletAddress=0xabc/);
  } finally {
    await fixture.close();
    await rm(logDir, { force: true, recursive: true });
  }
});

test('load-test HTTP helper follows leader redirects and preserves mutation body', async () => {
  const fixture = await startFixture();
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'oak-load-http-'));
  const outputFile = path.join(tempDir, 'response.json');
  try {
    const { stdout } = await execFileAsync('bash', ['-c', `source "$SUITE_LIB"; curl_http_code "$OUTPUT" -s -X POST "$URL/redirect" -d proposalId=0x123`], {
      env: {
        ...process.env,
        LOG_DIR: tempDir,
        OUTPUT: outputFile,
        SUITE_LIB: suiteLib,
        URL: fixture.baseUrl,
      },
    });
    assert.equal(stdout, '202');
    const accepted = fixture.requests.find((entry) => entry.url === '/accepted');
    assert.ok(accepted);
    assert.equal(accepted.method, 'POST');
    assert.equal(accepted.body, 'proposalId=0x123');
    assert.deepEqual(JSON.parse(await readFile(outputFile, 'utf8')), { accepted: true });
  } finally {
    await fixture.close();
    await rm(tempDir, { force: true, recursive: true });
  }
});

test('load-test registration fails fast on a rejected client policy', async () => {
  const fixture = await startFixture();
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'oak-load-reject-'));
  try {
    await assert.rejects(
      execFileAsync('bash', ['-c', `source "$SUITE_LIB"; curl_follow_redirects() { command curl --location --max-redirs 5 --connect-timeout 3 --max-time 30 --post301 --post302 --post303 -H 'x-reject-registration: true' "$@"; }; register_client 0xabc 7 enterprise`], {
        env: {
          ...process.env,
          LOG_DIR: tempDir,
          SUITE_LIB: suiteLib,
          VALIDATOR_URL: fixture.baseUrl,
        },
      }),
      (error) => {
        assert.match(error.stderr, /client registration failed/);
        assert.match(error.stderr, /HTTP 409/);
        assert.match(error.stderr, /registration conflict/);
        return true;
      },
    );
  } finally {
    await fixture.close();
    await rm(tempDir, { force: true, recursive: true });
  }
});
