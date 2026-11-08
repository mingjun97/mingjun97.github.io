// End-to-end check against the real Plaid Sandbox, without the iOS app:
// creates a sandbox bank connection (skipping Link), stores it, and prints a
// cached and a live sync.
//
//   PLAID_CLIENT_ID=... PLAID_SECRET=... npm run sandbox-check
//
// Uses an in-memory database and a throwaway encryption key; touches nothing
// on disk.
import { randomBytes } from "node:crypto";
import { PlaidClient } from "../src/plaid.ts";
import { Store } from "../src/db.ts";
import { TokenCipher } from "../src/crypto.ts";
import { CashlineService } from "../src/service.ts";

const clientId = process.env.PLAID_CLIENT_ID;
const secret = process.env.PLAID_SECRET;
if (!clientId || !secret) {
  console.error("Set PLAID_CLIENT_ID and PLAID_SECRET (Sandbox keys from dashboard.plaid.com).");
  process.exit(1);
}

const plaid = new PlaidClient({ env: "sandbox", clientId, secret });
const service = new CashlineService({
  plaid,
  store: new Store(":memory:"),
  cipher: new TokenCipher(randomBytes(32).toString("base64")),
  realtimeMinIntervalMs: 0,
  log: (msg, extra) => console.log("  log:", msg, extra ?? ""),
});

// "First Platypus Bank" — Plaid's standard sandbox institution.
const { public_token } = await plaid.sandboxPublicTokenCreate("ins_109508", ["transactions", "liabilities"]);
const item = await service.exchangePublicToken("sandbox-user", public_token, null);
console.log("Linked:", item);

const cached = await service.sync("sandbox-user", "cached");
console.log("\nCached balances:");
for (const a of cached.accounts) console.log(`  ${a.name.padEnd(28)} ${a.type.padEnd(11)} available=${a.available_balance} current=${a.current_balance} (${a.balance_source}, ${a.balance_updated_at ?? "time unknown"})`);

const live = await service.sync("sandbox-user", "realtime");
console.log("\nLive balances (checking/savings):");
for (const a of live.accounts.filter((x) => x.type === "depository")) {
  console.log(`  ${a.name.padEnd(28)} available=${a.available_balance} current=${a.current_balance} (${a.balance_source} @ ${a.balance_updated_at})`);
}
console.log(`\nCard statements: ${live.credit_liabilities.length}, recurring inflows: ${live.recurring_inflows.length}`);
console.log("(Recurring inflows can take a minute to be ready on a new sandbox item.)");

await service.removeItem("sandbox-user", item.id);
console.log("\nRemoved the sandbox item. ✓");
