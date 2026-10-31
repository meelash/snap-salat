// Cloudflare Workers entry. Secrets and bindings (see wrangler.toml):
//   FCM_SERVICE_ACCOUNT  the Firebase service account key JSON (a secret)
//   TIMES                a KV namespace: the last times seen per masjid

import { createRelay } from './src/relay.mjs';
import { fcmClient } from './src/fcm.mjs';

let relay = null;

export default {
  async fetch(request, env) {
    relay ??= createRelay({
      fcm: fcmClient(JSON.parse(env.FCM_SERVICE_ACCOUNT)),
      kv: env.TIMES,
      log: (msg) => console.log(msg),
    });
    return relay(request);
  },
};
