// Minimal Plaid REST client. Plaid's API is plain JSON over HTTPS, so a thin
// wrapper over fetch keeps this server dependency-free and easy to fake in
// tests. Only the endpoints Cashline uses are typed.

export type PlaidEnv = "sandbox" | "production";

const HOSTS: Record<PlaidEnv, string> = {
  sandbox: "https://sandbox.plaid.com",
  production: "https://production.plaid.com",
};

export interface PlaidBalances {
  available: number | null;
  current: number | null;
  limit?: number | null;
  iso_currency_code: string | null;
  last_updated_datetime?: string | null;
}

export interface PlaidAccount {
  account_id: string;
  name: string;
  official_name?: string | null;
  mask?: string | null;
  type: string; // depository | credit | loan | investment | other
  subtype?: string | null;
  balances: PlaidBalances;
}

export interface AccountsResponse {
  accounts: PlaidAccount[];
  item: { item_id: string; institution_id?: string | null; institution_name?: string | null };
}

export interface CreditLiability {
  account_id: string | null;
  is_overdue?: boolean | null;
  last_payment_amount?: number | null;
  last_payment_date?: string | null;
  last_statement_balance?: number | null;
  last_statement_issue_date?: string | null;
  minimum_payment_amount?: number | null;
  next_payment_due_date?: string | null;
}

export interface LiabilitiesResponse {
  liabilities: { credit: CreditLiability[] | null };
}

export interface RecurringStream {
  stream_id: string;
  account_id: string;
  description: string;
  merchant_name?: string | null;
  average_amount: { amount: number | null };
  last_amount?: { amount: number | null };
  frequency: string;
  last_date?: string | null;
  predicted_next_date?: string | null;
  is_active: boolean;
}

export interface RecurringResponse {
  inflow_streams: RecurringStream[];
}

/** An error returned by Plaid (`error_type`, `error_code`, …). */
export class PlaidError extends Error {
  readonly code: string;
  readonly type: string;
  readonly status: number;
  readonly displayMessage: string | null;
  readonly requestId: string | null;

  constructor(status: number, body: Record<string, unknown>) {
    super(String(body.error_message ?? `Plaid error ${status}`));
    this.name = "PlaidError";
    this.status = status;
    this.code = String(body.error_code ?? "UNKNOWN");
    this.type = String(body.error_type ?? "UNKNOWN");
    this.displayMessage = (body.display_message as string | null) ?? null;
    this.requestId = (body.request_id as string | null) ?? null;
  }
}

/** The calls the rest of the server makes. Implemented by `PlaidClient`, faked in tests. */
export interface PlaidApi {
  linkTokenCreate(body: Record<string, unknown>): Promise<{ link_token: string; expiration: string }>;
  itemPublicTokenExchange(publicToken: string): Promise<{ access_token: string; item_id: string }>;
  accountsGet(accessToken: string): Promise<AccountsResponse>;
  accountsBalanceGet(accessToken: string, accountIds?: string[]): Promise<AccountsResponse>;
  liabilitiesGet(accessToken: string): Promise<LiabilitiesResponse>;
  transactionsRecurringGet(accessToken: string): Promise<RecurringResponse>;
  institutionName(institutionId: string): Promise<string | null>;
  itemRemove(accessToken: string): Promise<void>;
  sandboxPublicTokenCreate(institutionId: string, products: string[]): Promise<{ public_token: string }>;
}

export class PlaidClient implements PlaidApi {
  private readonly host: string;
  private readonly clientId: string;
  private readonly secret: string;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: { env: PlaidEnv; clientId: string; secret: string; fetch?: typeof fetch }) {
    this.host = HOSTS[opts.env];
    this.clientId = opts.clientId;
    this.secret = opts.secret;
    this.fetchImpl = opts.fetch ?? fetch;
  }

  async post<T>(path: string, body: Record<string, unknown>, timeoutMs = 30_000): Promise<T> {
    const res = await this.fetchImpl(this.host + path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Plaid-Version": "2020-09-14" },
      body: JSON.stringify({ client_id: this.clientId, secret: this.secret, ...body }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
    if (!res.ok) throw new PlaidError(res.status, json);
    return json as T;
  }

  linkTokenCreate(body: Record<string, unknown>) {
    return this.post<{ link_token: string; expiration: string }>("/link/token/create", body);
  }

  itemPublicTokenExchange(publicToken: string) {
    return this.post<{ access_token: string; item_id: string }>("/item/public_token/exchange", { public_token: publicToken });
  }

  /** Balances as Plaid last cached them (no extra charge). */
  accountsGet(accessToken: string) {
    return this.post<AccountsResponse>("/accounts/get", { access_token: accessToken });
  }

  /**
   * Live balances read from the bank right now. Billed per call and can take
   * several seconds, so callers throttle it.
   */
  accountsBalanceGet(accessToken: string, accountIds?: string[]) {
    const options: Record<string, unknown> = {};
    if (accountIds?.length) options.account_ids = accountIds;
    return this.post<AccountsResponse>("/accounts/balance/get", { access_token: accessToken, options }, 60_000);
  }

  liabilitiesGet(accessToken: string) {
    return this.post<LiabilitiesResponse>("/liabilities/get", { access_token: accessToken });
  }

  transactionsRecurringGet(accessToken: string) {
    return this.post<RecurringResponse>("/transactions/recurring/get", { access_token: accessToken });
  }

  async institutionName(institutionId: string) {
    const r = await this.post<{ institution: { name: string } }>("/institutions/get_by_id", {
      institution_id: institutionId,
      country_codes: ["US"],
    });
    return r.institution?.name ?? null;
  }

  async itemRemove(accessToken: string) {
    await this.post("/item/remove", { access_token: accessToken });
  }

  /** Sandbox only: creates an item without going through Link. */
  sandboxPublicTokenCreate(institutionId: string, products: string[]) {
    return this.post<{ public_token: string }>("/sandbox/public_token/create", {
      institution_id: institutionId,
      initial_products: products,
    });
  }
}
