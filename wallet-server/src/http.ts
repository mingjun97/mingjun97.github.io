import { createServer, type IncomingMessage, type ServerResponse, type Server } from "node:http";
import { safeEqual } from "./crypto.ts";
import { PlaidError } from "./plaid.ts";
import { UserFacingError, type CashlineService, type BalanceMode } from "./service.ts";

const MAX_BODY = 64 * 1024;

/** `userId:token` pairs → lookup of the caller. */
export function parseTokens(spec: string): { userId: string; token: string }[] {
  return spec.split(",").map((s) => s.trim()).filter(Boolean).map((pair) => {
    const i = pair.indexOf(":");
    if (i <= 0 || i === pair.length - 1) throw new Error("CASHLINE_API_TOKENS must look like userId:token,userId2:token2");
    const token = pair.slice(i + 1);
    if (token.length < 24) throw new Error(`Token for ${pair.slice(0, i)} is too short — use openssl rand -hex 32`);
    return { userId: pair.slice(0, i), token };
  });
}

function authenticate(req: IncomingMessage, tokens: { userId: string; token: string }[]): string | null {
  const h = req.headers.authorization ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(h);
  if (!m) return null;
  let found: string | null = null;
  // check every entry so timing doesn't reveal which one matched
  for (const t of tokens) if (safeEqual(m[1].trim(), t.token)) found = t.userId;
  return found;
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) throw new UserFacingError(413, "too_large", "Request too large.");
    chunks.push(chunk as Buffer);
  }
  if (!size) return {};
  try {
    const v = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    return v && typeof v === "object" && !Array.isArray(v) ? v : {};
  } catch {
    throw new UserFacingError(400, "bad_json", "Request body isn't valid JSON.");
  }
}

function send(res: ServerResponse, status: number, body: unknown) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(json),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(json);
}

const str = (v: unknown) => (typeof v === "string" && v.length > 0 ? v : null);

export function createApp(opts: {
  service: CashlineService;
  tokens: { userId: string; token: string }[];
  log?: (msg: string, extra?: Record<string, unknown>) => void;
}): Server {
  const log = opts.log ?? (() => {});

  return createServer(async (req, res) => {
    const started = Date.now();
    const url = new URL(req.url ?? "/", "http://localhost");
    const path = url.pathname.replace(/\/+$/, "") || "/";
    try {
      if (req.method === "GET" && path === "/health") return send(res, 200, { ok: true });

      const userId = authenticate(req, opts.tokens);
      if (!userId) throw new UserFacingError(401, "unauthorized", "Missing or invalid access token.");

      if (req.method === "POST" && path === "/v1/plaid/link-token") {
        const body = await readJson(req);
        return send(res, 200, await opts.service.createLinkToken(userId, str(body.update_item_id)));
      }
      if (req.method === "POST" && path === "/v1/plaid/items") {
        const body = await readJson(req);
        const publicToken = str(body.public_token);
        if (!publicToken) throw new UserFacingError(400, "missing_field", "public_token is required.");
        return send(res, 201, await opts.service.exchangePublicToken(userId, publicToken, str(body.institution_name)));
      }
      const del = /^\/v1\/plaid\/items\/([^/]+)$/.exec(path);
      if (req.method === "DELETE" && del) {
        await opts.service.removeItem(userId, decodeURIComponent(del[1]));
        return send(res, 200, {});
      }
      if (req.method === "GET" && path === "/v1/sync") {
        const mode: BalanceMode = url.searchParams.get("balances") === "realtime" ? "realtime" : "cached";
        return send(res, 200, await opts.service.sync(userId, mode));
      }
      throw new UserFacingError(404, "not_found", "No such endpoint.");
    } catch (e) {
      if (e instanceof UserFacingError) return send(res, e.status, { error: e.code, message: e.message });
      if (e instanceof PlaidError) {
        log("plaid error", { path, code: e.code, request_id: e.requestId });
        return send(res, 502, { error: e.code.toLowerCase(), message: e.displayMessage ?? "The bank connection service returned an error. Try again shortly." });
      }
      log("unhandled error", { path, error: e instanceof Error ? e.stack : String(e) });
      return send(res, 500, { error: "internal", message: "Something went wrong on the server." });
    } finally {
      log("request", { method: req.method, path, status: res.statusCode, ms: Date.now() - started });
    }
  });
}
