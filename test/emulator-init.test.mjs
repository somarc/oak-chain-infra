import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const initializer = path.join(repoRoot, 'modes/mock/emulators/init-emulators.sh');

async function startHealthyFixture() {
  const server = http.createServer((_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{}');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  return {
    close: () => new Promise((resolve) => server.close(resolve)),
    url: `http://127.0.0.1:${address.port}`,
  };
}

test('cloud emulator initializer creates buckets/containers and defers Oak DynamoDB schemas', async () => {
  const awsFixture = await startHealthyFixture();
  const azureFixture = await startHealthyFixture();
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'oak-emulator-init-'));
  const binDir = path.join(tempDir, 'bin');
  const callsFile = path.join(tempDir, 'calls.log');
  try {
    await mkdir(binDir);
    const awsStub = `#!/bin/bash\necho "aws $*" >> "$CALLS_FILE"\nif [[ "$*" == *"s3api head-bucket"* ]]; then exit 1; fi\nexit 0\n`;
    const azStub = `#!/bin/bash\necho "az $*" >> "$CALLS_FILE"\nexit 0\n`;
    await Promise.all([
      writeFile(path.join(binDir, 'aws'), awsStub),
      writeFile(path.join(binDir, 'az'), azStub),
    ]);
    await Promise.all([
      chmod(path.join(binDir, 'aws'), 0o755),
      chmod(path.join(binDir, 'az'), 0o755),
    ]);

    const { stdout } = await execFileAsync('bash', [initializer], {
      env: {
        ...process.env,
        CALLS_FILE: callsFile,
        FLOCI_AZ_ENDPOINT: azureFixture.url,
        FLOCI_ENDPOINT: awsFixture.url,
        PATH: `${binDir}:${process.env.PATH}`,
      },
    });
    const calls = await readFile(callsFile, 'utf8');
    assert.match(calls, /aws .*s3 mb s3:\/\/oak-chain-segments/);
    assert.match(calls, /aws .*s3 mb s3:\/\/oak-chain-blobs/);
    assert.doesNotMatch(calls, /dynamodb create-table/);
    assert.match(calls, /az storage container create --name oak-chain-segments/);
    assert.match(calls, /az storage container create --name oak-chain-blobs/);
    assert.match(stdout, /DynamoDB tables: deferred to Oak/);
    assert.match(stdout, /OAK_SEGMENT_AZURE_CONNECTION_STRING=/);
    assert.match(stdout, /OAK_BLOB_AZURE_CONNECTION_STRING=/);
    assert.match(stdout, /KBHBeksoGMGw==/);
  } finally {
    await Promise.all([awsFixture.close(), azureFixture.close()]);
    await rm(tempDir, { force: true, recursive: true });
  }
});
