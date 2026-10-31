// Runs the relay with Node instead of Cloudflare (Node 22+, no dependencies).
//
//   FCM_SERVICE_ACCOUNT=/path/to/service-account.json node relay/node.mjs
//
// Environment:
//   FCM_SERVICE_ACCOUNT  path to the Firebase service account key JSON
//   PORT                 default 8090
//   HOST                 default 127.0.0.1 (put Caddy or nginx in front for HTTPS)
//   DATA_FILE            default ./relay-data.json (the last times seen per masjid)
//   ALLOW_HTTP           "1" to accept plain-http masjid addresses (local testing)

import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, renameSync } from 'node:fs';
import { createRelay } from './src/relay.mjs';
import { fcmClient } from './src/fcm.mjs';

const file = process.env.DATA_FILE ?? './relay-data.json';
const data = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {};
const kv = {
  get: async (key) => data[key] ?? null,
  put: async (key, value) => {
    data[key] = value;
    writeFileSync(`${file}.tmp`, JSON.stringify(data));
    renameSync(`${file}.tmp`, file);
  },
};

if (!process.env.FCM_SERVICE_ACCOUNT) throw new Error('Set FCM_SERVICE_ACCOUNT to the service account key file.');
const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);
const relay = createRelay({
  fcm: fcmClient(JSON.parse(readFileSync(process.env.FCM_SERVICE_ACCOUNT, 'utf8'))),
  kv,
  allowHttp: process.env.ALLOW_HTTP === '1',
  log,
});

createServer(async (req, res) => {
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const response = await relay(new Request(`http://${req.headers.host ?? 'localhost'}${req.url}`, {
      method: req.method,
      headers: req.headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks),
    }));
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch (err) {
    log(`error: ${err.message ?? err}`);
    res.writeHead(500).end();
  }
}).listen(Number(process.env.PORT ?? 8090), process.env.HOST ?? '127.0.0.1', () => log('relay listening'));
