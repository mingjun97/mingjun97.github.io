import type { PlaidApi, PlaidAccount, CreditLiability, RecurringStream } from "./plaid.ts";
import { PlaidError } from "./plaid.ts";
import type { Store, ItemRow } from "./db.ts";
import type { TokenCipher } from "./crypto.ts";

// The snapshot the iOS app consumes (see wallet-ios/docs/BACKEND.md).
export interface SnapshotItem {
  id: string;
  provider: "plaid";
  institution_name: string | null;
  status: string;
  last_synced_at: string | null;
}

export interface SnapshotAccount {
  id: string;
  item_id: string;
  name: string;
  official_name: string | null;
  mask: string | null;
  type: string;
  subtype: string | null;
  current_balance: number | null;
  available_balance: number | null;
  iso_currency_code: string | null;
  /** "realtime" = read from the bank during this or a recent sync; "cached" = Plaid's stored copy. */
  balance_source: "realtime" | "cached";
  /** When the balance was read from the bank, if known. */
  balance_updated_at: string | null;
}

export interface SnapshotCreditLiability {
  account_id: string;
  last_statement_balance: number | null;
  last_statement_issue_date: string | null;
  minimum_payment_amount: number | null;
  next_payment_due_date: string | null;
  last_payment_amount: number | null;
  last_payment_date: string | null;
  is_overdue: boolean | null;
}

export interface SnapshotInflow {
  id: string;
  account_id: string;
  description: string;
  merchant_name: string | null;
  average_amount: number;
  last_amount: number | null;
  frequency: string;
  last_date: string | null;
  predicted_next_date: string | null;
  is_active: boolean;
}

export interface Snapshot {
  items: SnapshotItem[];
  accounts: SnapshotAccount[];
  credit_liabilities: SnapshotCreditLiability[];
  recurring_inflows: SnapshotInflow[];
  synced_at: string;
}

export type BalanceMode = "realtime" | "cached";

/** An error safe to show the person using the app. */
export class UserFacingError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/** Plaid error codes that mean the person has to sign in to their bank again. */
const REAUTH_CODES = new Set(["ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION", "PENDING_DISCONNECT", "ACCESS_NOT_GRANTED"]);
/** Codes that just mean "this product has nothing for this bank (yet)". */
const NOT_AVAILABLE_CODES = new Set([
  "PRODUCT_NOT_READY", "PRODUCTS_NOT_SUPPORTED", "NO_LIABILITY_ACCOUNTS", "NO_ACCOUNTS",
  "ADDITIONAL_CONSENT_REQUIRED", "INVALID_PRODUCT",
]);

export interface ServiceOptions {
  plaid: PlaidApi;
  store: Store;
  cipher: TokenCipher;
  clientName?: string;
  redirectUri?: string;
  webhookUrl?: string;
  /** Minimum gap between billed live-balance calls for one bank connection. */
  realtimeMinIntervalMs: number;
  now?: () => Date;
  log?: (msg: string, extra?: Record<string, unknown>) => void;
}

export class CashlineService {
  private readonly o: ServiceOptions;

  constructor(options: ServiceOptions) {
    this.o = options;
  }

  private now() { return (this.o.now ?? (() => new Date()))(); }
  private log(msg: string, extra?: Record<string, unknown>) { (this.o.log ?? (() => {}))(msg, extra); }

  // MARK: linking

  async createLinkToken(userId: string, updateItemId: string | null): Promise<{ link_token: string }> {
    const body: Record<string, unknown> = {
      client_name: this.o.clientName ?? "Cashline",
      language: "en",
      country_codes: ["US"],
      user: { client_user_id: userId },
    };
    if (this.o.redirectUri) body.redirect_uri = this.o.redirectUri;
    if (this.o.webhookUrl) body.webhook = this.o.webhookUrl;
    if (updateItemId) {
      // update mode: re-authenticate an existing connection
      const item = this.o.store.item(userId, updateItemId);
      if (!item) throw new UserFacingError(404, "not_found", "That bank connection doesn't exist.");
      body.access_token = this.o.cipher.decrypt(item.access_token_enc);
    } else {
      // Transactions powers payroll detection (recurring inflows) and keeps
      // cached balances fresh; Liabilities adds card statements and due
      // dates when the bank has a credit card. Balance needs no product.
      body.products = ["transactions"];
      body.optional_products = ["liabilities"];
      body.transactions = { days_requested: 180 };
    }
    const r = await this.o.plaid.linkTokenCreate(body);
    return { link_token: r.link_token };
  }

  async exchangePublicToken(userId: string, publicToken: string, institutionName: string | null): Promise<SnapshotItem> {
    const { access_token, item_id } = await this.o.plaid.itemPublicTokenExchange(publicToken);
    let name = institutionName;
    if (!name) {
      try {
        const acc = await this.o.plaid.accountsGet(access_token);
        name = acc.item.institution_name ?? (acc.item.institution_id ? await this.o.plaid.institutionName(acc.item.institution_id) : null);
      } catch { /* the name is cosmetic */ }
    }
    this.o.store.insertItem({
      id: item_id,
      user_id: userId,
      access_token_enc: this.o.cipher.encrypt(access_token),
      institution_name: name,
      created_at: this.now().toISOString(),
    });
    this.log("item linked", { userId, item_id });
    return { id: item_id, provider: "plaid", institution_name: name, status: "ok", last_synced_at: null };
  }

  async removeItem(userId: string, itemId: string): Promise<void> {
    const item = this.o.store.item(userId, itemId);
    if (!item) throw new UserFacingError(404, "not_found", "That bank connection doesn't exist.");
    try {
      await this.o.plaid.itemRemove(this.o.cipher.decrypt(item.access_token_enc));
    } catch (e) {
      // Already gone at Plaid is fine; anything else, keep the token so we can retry.
      if (!(e instanceof PlaidError && (e.code === "ITEM_NOT_FOUND" || e.code === "INVALID_ACCESS_TOKEN"))) throw e;
    }
    this.o.store.deleteItem(itemId);
    this.log("item removed", { userId, itemId });
  }

  // MARK: sync

  /**
   * Everything for the user's linked banks.
   *
   * Balances: with `mode = "realtime"` checking/savings balances are read
   * live from the bank (`/accounts/balance/get`) — at most once per
   * `realtimeMinIntervalMs` per connection, since Plaid bills each call; in
   * between, the last live read is reused. `"cached"` uses Plaid's stored
   * balances (`/accounts/get`), which can be hours old.
   */
  async sync(userId: string, mode: BalanceMode): Promise<Snapshot> {
    const snap: Snapshot = { items: [], accounts: [], credit_liabilities: [], recurring_inflows: [], synced_at: this.now().toISOString() };
    // banks are independent: fetch them in parallel, and one failing doesn't sink the rest
    const results = await Promise.all(this.o.store.items(userId).map((item) => this.syncItem(item, mode)));
    for (const r of results) {
      snap.items.push(r.item);
      snap.accounts.push(...r.accounts);
      snap.credit_liabilities.push(...r.credit);
      snap.recurring_inflows.push(...r.inflows);
    }
    return snap;
  }

  private async syncItem(row: ItemRow, mode: BalanceMode) {
    const out = {
      item: { id: row.id, provider: "plaid" as const, institution_name: row.institution_name, status: row.status, last_synced_at: row.last_synced_at },
      accounts: [] as SnapshotAccount[],
      credit: [] as SnapshotCreditLiability[],
      inflows: [] as SnapshotInflow[],
    };
    const token = this.o.cipher.decrypt(row.access_token_enc);
    const now = this.now();

    // 1. accounts + cached balances (free)
    let accounts: PlaidAccount[];
    try {
      accounts = (await this.o.plaid.accountsGet(token)).accounts;
    } catch (e) {
      out.item.status = this.statusFor(e) ?? row.status;
      this.o.store.updateItem(row.id, { status: out.item.status });
      this.log("accounts/get failed", { item: row.id, code: e instanceof PlaidError ? e.code : String(e) });
      return out; // nothing else will work either
    }

    // 2. live balances for checking/savings, throttled
    const { rows: live, freshIds } = await this.liveBalances(row, token, accounts, mode, now);

    for (const a of accounts) {
      const l = live.get(a.account_id);
      const cachedAt = a.balances.last_updated_datetime ?? null;
      // A live read from this sync always wins (bank clocks can run ahead of
      // ours); an older live read wins only if it's newer than Plaid's cache.
      const useLive = l && (freshIds.has(a.account_id) || !cachedAt || Date.parse(l.fetched_at) >= Date.parse(cachedAt));
      out.accounts.push({
        id: a.account_id,
        item_id: row.id,
        name: a.name,
        official_name: a.official_name ?? null,
        mask: a.mask ?? null,
        type: a.type,
        subtype: a.subtype ?? null,
        current_balance: useLive ? l.current : a.balances.current,
        available_balance: useLive ? l.available : a.balances.available,
        iso_currency_code: a.balances.iso_currency_code,
        balance_source: useLive ? "realtime" : "cached",
        balance_updated_at: useLive ? l.fetched_at : cachedAt,
      });
    }

    // 3. card statements and payroll — optional, so failures are soft
    if (accounts.some((a) => a.type === "credit")) {
      const credit = await this.soft(row, "liabilities", () => this.o.plaid.liabilitiesGet(token));
      for (const c of credit?.liabilities.credit ?? []) {
        if (c.account_id) out.credit.push(mapCredit(c));
      }
    }
    const recurring = await this.soft(row, "recurring", () => this.o.plaid.transactionsRecurringGet(token));
    for (const s of recurring?.inflow_streams ?? []) {
      const m = mapInflow(s);
      if (m) out.inflows.push(m);
    }

    out.item.status = "ok";
    out.item.last_synced_at = now.toISOString();
    this.o.store.updateItem(row.id, { status: "ok", last_synced_at: out.item.last_synced_at });
    return out;
  }

  /** Live balances for this connection's depository accounts (fresh or reused). */
  private async liveBalances(row: ItemRow, token: string, accounts: PlaidAccount[], mode: BalanceMode, now: Date) {
    const stored = this.o.store.liveBalances(row.id);
    const freshIds = new Set<string>();
    const depository = accounts.filter((a) => a.type === "depository").map((a) => a.account_id);
    if (mode !== "realtime" || depository.length === 0) return { rows: stored, freshIds };

    const last = this.o.store.lastLiveCall(row.id);
    if (last && now.getTime() - Date.parse(last) < this.o.realtimeMinIntervalMs) return { rows: stored, freshIds };

    // Record the attempt first: a failed call is still billed, so don't retry in a loop.
    this.o.store.recordLiveCall(row.id, now.toISOString());
    try {
      // Credit accounts are skipped on purpose: some banks (Capital One) can't
      // give live card balances, and the statement data comes from Liabilities.
      const r = await this.o.plaid.accountsBalanceGet(token, depository);
      for (const a of r.accounts) {
        if (a.type !== "depository") continue;
        const fetchedAt = a.balances.last_updated_datetime ?? now.toISOString();
        this.o.store.saveLiveBalance({
          account_id: a.account_id, item_id: row.id,
          available: a.balances.available, current: a.balances.current, fetched_at: fetchedAt,
        });
        freshIds.add(a.account_id);
      }
    } catch (e) {
      this.log("live balance failed; using cached", { item: row.id, code: e instanceof PlaidError ? e.code : String(e) });
    }
    return { rows: this.o.store.liveBalances(row.id), freshIds };
  }

  private async soft<T>(row: ItemRow, what: string, fn: () => Promise<T>): Promise<T | null> {
    try {
      return await fn();
    } catch (e) {
      if (e instanceof PlaidError && NOT_AVAILABLE_CODES.has(e.code)) return null;
      this.log(`${what} failed`, { item: row.id, code: e instanceof PlaidError ? e.code : String(e) });
      return null;
    }
  }

  private statusFor(e: unknown): string | null {
    if (!(e instanceof PlaidError)) return null;
    return REAUTH_CODES.has(e.code) ? "login_required" : "error";
  }
}

function mapCredit(c: CreditLiability): SnapshotCreditLiability {
  return {
    account_id: c.account_id!,
    last_statement_balance: c.last_statement_balance ?? null,
    last_statement_issue_date: c.last_statement_issue_date ?? null,
    minimum_payment_amount: c.minimum_payment_amount ?? null,
    next_payment_due_date: c.next_payment_due_date ?? null,
    last_payment_amount: c.last_payment_amount ?? null,
    last_payment_date: c.last_payment_date ?? null,
    is_overdue: c.is_overdue ?? null,
  };
}

function mapInflow(s: RecurringStream): SnapshotInflow | null {
  const avg = s.average_amount?.amount;
  if (avg == null) return null;
  // Plaid reports money coming in as negative amounts.
  const last = s.last_amount?.amount;
  return {
    id: s.stream_id,
    account_id: s.account_id,
    description: s.description,
    merchant_name: s.merchant_name ?? null,
    average_amount: Math.abs(avg),
    last_amount: last == null ? null : Math.abs(last),
    frequency: s.frequency,
    last_date: s.last_date ?? null,
    predicted_next_date: s.predicted_next_date ?? null,
    is_active: s.is_active,
  };
}
