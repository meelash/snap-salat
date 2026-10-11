#!/usr/bin/env node
// Snap Salat example server: the Snap Salat API, an admin page, and a
// prayer-times widget for the masjid's website. No dependencies; Node 22.13+.
//
//   node server/server.mjs                         run the server
//   node server/server.mjs create-admin <username> create or reset an admin
//   node server/server.mjs approve-user <username> approve a volunteer
//   node server/server.mjs list-users
//
// Environment:
//   PORT              default 8080
//   HOST              default 127.0.0.1 (put Caddy or nginx in front for HTTPS)
//   DATA_DIR          default ./data (database and uploaded photos)
//   INSECURE_COOKIES  "1" to allow the admin cookie over plain http (local testing)
//   ADMIN_PASSWORD    password for create-admin, instead of prompting

import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { openDb } from './src/db.mjs';
import { createApp, API_BASE } from './src/app.mjs';
import { hashPassword } from './src/util.mjs';

const dataDir = resolve(process.env.DATA_DIR ?? './data');
const store = openDb(join(dataDir, 'snap-salat.db'));
const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);

async function askPassword(prompt) {
  if (process.env.ADMIN_PASSWORD) return process.env.ADMIN_PASSWORD;
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  // Hide the typed password.
  rl._writeToOutput = (s) => rl.output.write(s.includes(prompt) ? s : '');
  const answer = await new Promise((r) => rl.question(prompt, r));
  rl.close();
  process.stdout.write('\n');
  return answer;
}

const [command, arg] = process.argv.slice(2);
switch (command) {
  case 'create-admin': {
    if (!arg) throw new Error('usage: create-admin <username>');
    const password = await askPassword(`Password for admin "${arg}": `);
    if (password.length < 10) throw new Error('Use at least 10 characters.');
    store.createAdmin(arg, await hashPassword(password));
    console.log(`Admin "${arg}" saved. Sign in at /admin.`);
    break;
  }
  case 'approve-user': {
    const user = store.userByName(arg ?? '');
    if (!user) throw new Error(`No volunteer named "${arg}".`);
    store.setUserStatus(user.id, 'approved', 'cli');
    console.log(`${user.username} can now update the times.`);
    break;
  }
  case 'list-users':
    for (const u of store.users()) console.log(`${u.status.padEnd(9)} ${u.username} (${u.name})`);
    break;
  case undefined:
  case 'serve': {
    const port = Number(process.env.PORT ?? 8080);
    const host = process.env.HOST ?? '127.0.0.1';
    const server = createApp({ store, dataDir, secureCookies: process.env.INSECURE_COOKIES !== '1', log });
    server.listen(port, host, () => {
      const p = server.address().port;
      log(`Snap Salat server on http://${host}:${p}`);
      log(`  app address: http://${host}:${p}${API_BASE}  ·  admin: /admin  ·  widget: /widget`);
      if (!store.hasAdmins()) log('  no admin yet: run `node server/server.mjs create-admin <username>`');
    });
    // Stop promptly (e.g. `docker stop`): finish requests, then exit.
    for (const signal of ['SIGTERM', 'SIGINT']) {
      process.on(signal, () => {
        log(`${signal}: shutting down`);
        server.close(() => process.exit(0));
        server.closeIdleConnections?.();
        setTimeout(() => process.exit(0), 5000).unref();
      });
    }
    break;
  }
  default:
    console.error(`Unknown command "${command}".`);
    process.exit(64);
}
