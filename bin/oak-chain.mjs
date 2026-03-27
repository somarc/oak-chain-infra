#!/usr/bin/env node

import { main } from '../src/cli.mjs';

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
