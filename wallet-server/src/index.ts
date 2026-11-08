import { existsSync, readFileSync } from "node:fs";
import { PlaidClient, type PlaidEnv } from "./plaid.ts";
import { Store } from "./db.ts";
import { TokenCipher } from "./crypto.ts";
import { CashlineService } from "./service.ts";
import { createApp, parseTokens } from "./http.ts";

// Loads .env if present (simple KEY=value lines; real env vars win).
if (existsSync(".env")) {
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing ${name}. See .env.example.`);
    process.exit(1);
  }
  return v;
}

const env = (process.env.PLAID_ENV ?? "sandbox") as PlaidEnv;
if (env !== "sandbox" && env !== "production") {
  console.error("PLAID_ENV must be sandbox or production");
  process.exit(1);
}

const log = (msg: string, extra?: Record<string, unknown>) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), msg, ...extra }));

const service = new CashlineService({
  plaid: new PlaidClient({ env, clientId: required("PLAID_CLIENT_ID"), secret: required("PLAID_SECRET") }),
  store: new Store(process.env.DATABASE_PATH ?? "./data/cashline.db"),
  cipher: new TokenCipher(required("CASHLINE_ENCRYPTION_KEY")),
  redirectUri: process.env.PLAID_REDIRECT_URI || undefined,
  realtimeMinIntervalMs: Number(process.env.REALTIME_MIN_INTERVAL_SECONDS ?? 300) * 1000,
  log,
});

const port = Number(process.env.PORT ?? 8787);
createApp({ service, tokens: parseTokens(required("CASHLINE_API_TOKENS")), log }).listen(port, () => {
  log("cashline-server listening", { port, plaid_env: env });
});
