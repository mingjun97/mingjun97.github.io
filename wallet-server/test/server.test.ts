import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import type { AddressInfo } from "node:net";
import { FakePlaid } from "./fake-plaid.ts";
import { Store } from "../src/db.ts";
import { TokenCipher } from "../src/crypto.ts";
import { CashlineService } from "../src/service.ts";
import { createApp, parseTokens } from "../src/http.ts";
import { PlaidClient } from "../src/plaid.ts";

const TOKEN = "t".repeat(40);

function setup(opts: { intervalMs?: number } = {}) {
  const plaid = new FakePlaid();
  const store = new Store(":memory:");
  const cipher = new TokenCipher(randomBytes(32).toString("base64"));
  let now = new Date("2026-11-08T10:00:00Z");
  const service = new CashlineService({
    plaid, store, cipher, realtimeMinIntervalMs: opts.intervalMs ?? 300_000, now: () => now,
  });
  return { plaid, store, cipher, service, advance: (ms: number) => { now = new Date(now.getTime() + ms); } };
}

async function linked(s = setup()) {
  await s.service.exchangePublicToken("me", "public-sandbox-ok", null);
  return s;
}

test("access tokens are stored encrypted", async () => {
  const s = await linked();
  const row = s.store.items("me")[0];
  assert.ok(!row.access_token_enc.includes("access-sandbox-secret"));
  assert.equal(s.cipher.decrypt(row.access_token_enc), "access-sandbox-secret");
  assert.equal(row.institution_name, "First Platypus Bank");
});

test("link token asks for transactions, with liabilities optional", async () => {
  const s = setup();
  await s.service.createLinkToken("me", null);
  assert.deepEqual(s.plaid.lastLinkBody?.products, ["transactions"]);
  assert.deepEqual(s.plaid.lastLinkBody?.optional_products, ["liabilities"]);
  assert.deepEqual(s.plaid.lastLinkBody?.user, { client_user_id: "me" });
});

test("update-mode link token uses the stored access token", async () => {
  const s = await linked();
  await s.service.createLinkToken("me", "item_1");
  assert.equal(s.plaid.lastLinkBody?.access_token, "access-sandbox-secret");
  assert.equal(s.plaid.lastLinkBody?.products, undefined);
  await assert.rejects(s.service.createLinkToken("someone-else", "item_1"), /doesn't exist/);
});

test("cached sync uses Plaid's stored balance and never calls live balance", async () => {
  const s = await linked();
  const snap = await s.service.sync("me", "cached");
  const chk = snap.accounts.find((a) => a.id === "acc_chk")!;
  assert.equal(chk.available_balance, 100);
  assert.equal(chk.balance_source, "cached");
  assert.equal(chk.balance_updated_at, "2026-11-08T01:00:00Z");
  assert.equal(s.plaid.balanceCalls, 0);
});

test("realtime sync reads live balances for checking only", async () => {
  const s = await linked();
  const snap = await s.service.sync("me", "realtime");
  const chk = snap.accounts.find((a) => a.id === "acc_chk")!;
  const cc = snap.accounts.find((a) => a.id === "acc_cc")!;
  assert.equal(chk.available_balance, 1234.56);
  assert.equal(chk.current_balance, 1244.56);
  assert.equal(chk.balance_source, "realtime");
  assert.equal(chk.balance_updated_at, "2026-11-08T10:00:00.000Z");
  assert.equal(cc.balance_source, "cached");
  assert.equal(s.plaid.balanceCalls, 1);
});

test("live calls are throttled and the last live read is reused", async () => {
  const s = await linked();
  await s.service.sync("me", "realtime");
  s.plaid.liveAvailable = 999;
  s.advance(60_000);
  const again = await s.service.sync("me", "realtime");
  assert.equal(s.plaid.balanceCalls, 1, "second call within 5 minutes is not billed");
  assert.equal(again.accounts.find((a) => a.id === "acc_chk")!.available_balance, 1234.56);
  // a later cached sync still shows the newer live value
  const cached = await s.service.sync("me", "cached");
  assert.equal(cached.accounts.find((a) => a.id === "acc_chk")!.balance_source, "realtime");
  s.advance(300_000);
  const fresh = await s.service.sync("me", "realtime");
  assert.equal(s.plaid.balanceCalls, 2);
  assert.equal(fresh.accounts.find((a) => a.id === "acc_chk")!.available_balance, 999);
});

test("a live read wins even if Plaid's cache timestamp is ahead of our clock", async () => {
  const s = await linked();
  s.advance(-10 * 3600_000); // our clock 00:00; Plaid's cached timestamp says 01:00
  const snap = await s.service.sync("me", "realtime");
  const chk = snap.accounts.find((a) => a.id === "acc_chk")!;
  assert.equal(chk.balance_source, "realtime");
  assert.equal(chk.available_balance, 1234.56);
});

test("a failed live call falls back to cached and isn't retried immediately", async () => {
  const s = await linked();
  s.plaid.failBalanceWith = "INSTITUTION_NOT_RESPONDING";
  const snap = await s.service.sync("me", "realtime");
  assert.equal(snap.accounts.find((a) => a.id === "acc_chk")!.balance_source, "cached");
  await s.service.sync("me", "realtime");
  assert.equal(s.plaid.balanceCalls, 1);
});

test("statements and payroll are mapped; bad streams skipped", async () => {
  const s = await linked();
  const snap = await s.service.sync("me", "cached");
  assert.equal(snap.credit_liabilities[0].last_statement_balance, 1708.77);
  assert.equal(snap.credit_liabilities[0].next_payment_due_date, "2026-11-20");
  assert.equal(snap.recurring_inflows.length, 1);
  assert.equal(snap.recurring_inflows[0].average_amount, 2150, "inflows are positive");
  assert.equal(snap.items[0].status, "ok");
});

test("missing liabilities product is not an error", async () => {
  const s = await linked();
  s.plaid.liabilitiesError = "PRODUCTS_NOT_SUPPORTED";
  const snap = await s.service.sync("me", "cached");
  assert.equal(snap.credit_liabilities.length, 0);
  assert.equal(snap.accounts.length, 2);
});

test("login-required marks the item so the app can prompt re-auth", async () => {
  const s = await linked();
  s.plaid.failAccountsWith = "ITEM_LOGIN_REQUIRED";
  const snap = await s.service.sync("me", "realtime");
  assert.equal(snap.items[0].status, "login_required");
  assert.equal(snap.accounts.length, 0);
  assert.equal(s.store.items("me")[0].status, "login_required");
});

test("users only see their own banks; remove deletes token", async () => {
  const s = await linked();
  assert.equal((await s.service.sync("other", "cached")).items.length, 0);
  await assert.rejects(s.service.removeItem("other", "item_1"));
  await s.service.removeItem("me", "item_1");
  assert.deepEqual(s.plaid.removed, ["access-sandbox-secret"]);
  assert.equal(s.store.items("me").length, 0);
});

test("HTTP: auth, routes and error shapes", async () => {
  const s = setup();
  const server = createApp({ service: s.service, tokens: parseTokens(`me:${TOKEN}`) });
  await new Promise<void>((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const call = (method: string, path: string, body?: unknown, token = TOKEN) =>
    fetch(base + path, {
      method,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  try {
    assert.equal((await fetch(base + "/health")).status, 200);
    assert.equal((await call("GET", "/v1/sync", undefined, "wrong".repeat(10))).status, 401);

    const lt = await call("POST", "/v1/plaid/link-token", { update_item_id: null, platform: "ios" });
    assert.deepEqual(await lt.json(), { link_token: "link-sandbox-123" });

    const bad = await call("POST", "/v1/plaid/items", { public_token: "nope" });
    assert.equal(bad.status, 502);
    assert.equal((await bad.json()).error, "invalid_public_token");

    const item = await call("POST", "/v1/plaid/items", { public_token: "public-sandbox-ok", institution_name: "Chase" });
    assert.equal(item.status, 201);
    assert.equal((await item.json()).institution_name, "Chase");

    const snap = await (await call("GET", "/v1/sync?balances=realtime")).json();
    assert.equal(snap.accounts[0].balance_source, "realtime");

    assert.equal((await call("DELETE", "/v1/plaid/items/item_1")).status, 200);
    assert.equal((await call("GET", "/v1/nope")).status, 404);
  } finally {
    server.close();
  }
});

test("Plaid client sends credentials in the body and surfaces Plaid errors", async () => {
  const sent: { url: string; body: Record<string, unknown> }[] = [];
  const fakeFetch = (async (url: string, init: RequestInit) => {
    sent.push({ url, body: JSON.parse(String(init.body)) });
    return new Response(JSON.stringify({ error_code: "ITEM_LOGIN_REQUIRED", error_type: "ITEM_ERROR", error_message: "login" }), { status: 400 });
  }) as unknown as typeof fetch;
  const client = new PlaidClient({ env: "sandbox", clientId: "cid", secret: "sec", fetch: fakeFetch });
  await assert.rejects(client.accountsBalanceGet("access-1", ["a"]), (e: Error & { code?: string }) => e.code === "ITEM_LOGIN_REQUIRED");
  assert.equal(sent[0].url, "https://sandbox.plaid.com/accounts/balance/get");
  assert.deepEqual(sent[0].body, { client_id: "cid", secret: "sec", access_token: "access-1", options: { account_ids: ["a"] } });
});

test("token config is validated", () => {
  assert.throws(() => parseTokens("me:short"), /too short/);
  assert.throws(() => parseTokens("nocolon"), /userId:token/);
  assert.deepEqual(parseTokens(` me:${TOKEN} `), [{ userId: "me", token: TOKEN }]);
});
