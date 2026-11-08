import { PlaidError, type PlaidApi, type AccountsResponse, type PlaidAccount } from "../src/plaid.ts";

/** In-memory stand-in for Plaid with one bank: checking + a credit card. */
export class FakePlaid implements PlaidApi {
  calls: string[] = [];
  balanceCalls = 0;
  /** Live balance the "bank" reports right now. */
  liveAvailable = 1234.56;
  failAccountsWith: string | null = null;
  failBalanceWith: string | null = null;
  liabilitiesError: string | null = null;
  removed: string[] = [];
  lastLinkBody: Record<string, unknown> | null = null;

  private accounts(live: boolean): PlaidAccount[] {
    return [
      {
        account_id: "acc_chk", name: "Plaid Checking", mask: "0000", type: "depository", subtype: "checking",
        balances: live
          ? { available: this.liveAvailable, current: this.liveAvailable + 10, iso_currency_code: "USD", last_updated_datetime: null }
          : { available: 100, current: 110, iso_currency_code: "USD", last_updated_datetime: "2026-11-08T01:00:00Z" },
      },
      {
        account_id: "acc_cc", name: "Plaid Credit Card", mask: "3333", type: "credit", subtype: "credit card",
        balances: { available: null, current: 410, limit: 2000, iso_currency_code: "USD" },
      },
    ];
  }

  private resp(live: boolean, ids?: string[]): AccountsResponse {
    const accounts = this.accounts(live).filter((a) => !ids || ids.includes(a.account_id));
    return { accounts, item: { item_id: "item_1", institution_id: "ins_109508", institution_name: null } };
  }

  async linkTokenCreate(body: Record<string, unknown>) {
    this.calls.push("link/token/create");
    this.lastLinkBody = body;
    return { link_token: "link-sandbox-123", expiration: "2026-11-08T05:00:00Z" };
  }
  async itemPublicTokenExchange(publicToken: string) {
    this.calls.push("item/public_token/exchange");
    if (publicToken !== "public-sandbox-ok") throw new PlaidError(400, { error_code: "INVALID_PUBLIC_TOKEN", error_type: "INVALID_INPUT" });
    return { access_token: "access-sandbox-secret", item_id: "item_1" };
  }
  async accountsGet(token: string) {
    this.calls.push("accounts/get");
    if (token !== "access-sandbox-secret") throw new Error("wrong token passed to Plaid");
    if (this.failAccountsWith) throw new PlaidError(400, { error_code: this.failAccountsWith, error_type: "ITEM_ERROR" });
    return this.resp(false);
  }
  async accountsBalanceGet(_token: string, ids?: string[]) {
    this.calls.push("accounts/balance/get");
    this.balanceCalls++;
    if (this.failBalanceWith) throw new PlaidError(400, { error_code: this.failBalanceWith, error_type: "ITEM_ERROR" });
    return this.resp(true, ids);
  }
  async liabilitiesGet() {
    this.calls.push("liabilities/get");
    if (this.liabilitiesError) throw new PlaidError(400, { error_code: this.liabilitiesError, error_type: "ITEM_ERROR" });
    return {
      liabilities: {
        credit: [{
          account_id: "acc_cc", is_overdue: false, last_payment_amount: 168.25, last_payment_date: "2026-10-22",
          last_statement_balance: 1708.77, last_statement_issue_date: "2026-10-25", minimum_payment_amount: 20,
          next_payment_due_date: "2026-11-20",
        }],
      },
    };
  }
  async transactionsRecurringGet() {
    this.calls.push("transactions/recurring/get");
    return {
      inflow_streams: [
        { stream_id: "s_pay", account_id: "acc_chk", description: "ACME PAYROLL", merchant_name: "Acme",
          average_amount: { amount: -2150 }, last_amount: { amount: -2150 }, frequency: "BIWEEKLY",
          last_date: "2026-10-30", predicted_next_date: "2026-11-13", is_active: true },
        { stream_id: "s_bad", account_id: "acc_chk", description: "?", average_amount: { amount: null },
          frequency: "UNKNOWN", is_active: true },
      ],
    };
  }
  async institutionName() { return "First Platypus Bank"; }
  async itemRemove(token: string) { this.removed.push(token); }
  async sandboxPublicTokenCreate() { return { public_token: "public-sandbox-ok" }; }
}
