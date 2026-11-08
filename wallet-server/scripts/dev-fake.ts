// Runs the server with a fake Plaid (no keys needed) for developing the app
// or testing the HTTP contract. Token: "dev-token-0123456789abcdef0123".
//   node scripts/dev-fake.ts [port]
import { randomBytes } from "node:crypto";
import { FakePlaid } from "../test/fake-plaid.ts";
import { Store } from "../src/db.ts";
import { TokenCipher } from "../src/crypto.ts";
import { CashlineService } from "../src/service.ts";
import { createApp, parseTokens } from "../src/http.ts";

const port = Number(process.argv[2] ?? 8787);
const service = new CashlineService({
  plaid: new FakePlaid(),
  store: new Store(":memory:"),
  cipher: new TokenCipher(randomBytes(32).toString("base64")),
  realtimeMinIntervalMs: 300_000,
});
createApp({ service, tokens: parseTokens("dev:dev-token-0123456789abcdef0123") }).listen(port, () =>
  console.log(`fake cashline-server on http://127.0.0.1:${port}  (token dev-token-0123456789abcdef0123)`),
);
