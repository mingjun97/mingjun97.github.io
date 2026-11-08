# Cashline backend contract

The iOS app works fully offline. Bank connections (Plaid) are optional and go
through a small server you run, because Plaid's `secret` and the per-bank
`access_token`s must never be shipped inside an app.

```
iPhone (Cashline)                Cashline server                    Plaid
─────────────────                ───────────────                    ─────
POST /v1/plaid/link-token  ───►  /link/token/create           ───►
         ◄── link_token
open Plaid Link (LinkKit SDK) ─────────────────────────────────────► (user logs in to bank)
         ◄── public_token
POST /v1/plaid/items       ───►  /item/public_token/exchange  ───►
                                 store access_token (encrypted)
GET  /v1/sync              ───►  /accounts/balance/get, /liabilities/get,
                                 /transactions/recurring/get   ───►
         ◄── SyncSnapshot
merge locally (SyncMerger)
```

The app side of this is already built:

| Piece | File |
|---|---|
| API client protocol + HTTP implementation | `Packages/CashlineCore/Sources/CashlineCore/Sync/Backend.swift` |
| Response models | `.../Sync/SyncModels.swift` |
| Merge rules (bank data → bills/accounts/deposits) | `.../Sync/SyncMerger.swift` (tested in `SyncTests.swift`) |
| Fake server for development | `.../Sync/MockBackend.swift` ("Demo bank" in Settings) |
| Plaid Link presenter | `Cashline/Services/PlaidLinkPresenter.swift` |
| Server URL / mode, auth token in Keychain | `Cashline/Services/BackendSettings.swift` |

The reference server implementing this contract is in
[`../../wallet-server`](../../wallet-server) (Node, no dependencies, tested).

## Conventions

- JSON, `snake_case` keys.
- Dates are `YYYY-MM-DD`; timestamps are ISO-8601 (`2026-11-07T10:00:00Z`).
- Amounts are positive numbers in dollars (`410.5`).
- Every request carries `Authorization: Bearer <token>` once the app has a
  user token (`AuthTokenStore.shared.set(_:)`). How users sign in (Sign in with
  Apple is the natural fit) is up to the server.
- Errors: non-2xx status with `{"error": "code", "message": "Human readable"}`.
  The app shows `message`.

## Endpoints

### `POST /v1/plaid/link-token`

Request: `{"update_item_id": null, "platform": "ios"}`
(`update_item_id` set → create the token in update mode for re-authentication.)

Server calls `/link/token/create` with
`products: ["transactions", "liabilities"]`, `country_codes: ["US"]`, and your
iOS `redirect_uri` if you use OAuth institutions.

Response: `{"link_token": "link-sandbox-..."}`

### `POST /v1/plaid/items`

Request: `{"public_token": "public-sandbox-...", "institution_name": "Chase"}`

Server exchanges the token (`/item/public_token/exchange`), stores the
`access_token` encrypted, and returns the item:

```json
{"id": "item_abc", "provider": "plaid", "institution_name": "Chase",
 "status": "ok", "last_synced_at": null}
```

### `GET /v1/sync?balances=realtime|cached`

Returns everything for the signed-in user. Server-side, for each item call:

- `/accounts/get` for accounts and Plaid's cached balances (included in price)
- with `balances=realtime`: `/accounts/balance/get` for checking/savings to
  read exact balances live from the bank (billed per call — throttle it, and
  reuse the last live read in between)
- `/liabilities/get` → `liabilities.credit[]`
- `/transactions/recurring/get` → `inflow_streams[]`

```json
{
  "items": [
    {"id": "item_abc", "provider": "plaid", "institution_name": "Chase",
     "status": "ok", "last_synced_at": "2026-11-07T10:00:00Z"}
  ],
  "accounts": [
    {"id": "acc_chk", "item_id": "item_abc", "name": "Total Checking", "official_name": null,
     "mask": "4821", "type": "depository", "subtype": "checking",
     "current_balance": 2410.12, "available_balance": 2350.00, "iso_currency_code": "USD",
     "balance_source": "realtime", "balance_updated_at": "2026-11-07T09:59:58Z"},
    {"id": "acc_cc", "item_id": "item_abc", "name": "Sapphire Preferred", "mask": "9911",
     "type": "credit", "subtype": "credit card", "current_balance": 684.12}
  ],
  "credit_liabilities": [
    {"account_id": "acc_cc", "last_statement_balance": 512.30, "last_statement_issue_date": "2026-10-26",
     "minimum_payment_amount": 35, "next_payment_due_date": "2026-11-20",
     "last_payment_amount": 401.77, "last_payment_date": "2026-10-18", "is_overdue": false}
  ],
  "recurring_inflows": [
    {"id": "stream_1", "account_id": "acc_chk", "description": "ACME CORP PAYROLL", "merchant_name": "Acme Corp",
     "average_amount": 2150, "last_amount": 2150, "frequency": "BIWEEKLY",
     "last_date": "2026-10-29", "predicted_next_date": "2026-11-12", "is_active": true}
  ],
  "synced_at": "2026-11-07T10:00:00Z"
}
```

Field mapping from Plaid:

| Snapshot field | Plaid source |
|---|---|
| `accounts[].current_balance / available_balance` | `balances.current / balances.available` |
| `accounts[].balance_source` | `"realtime"` if from `/accounts/balance/get`, else `"cached"` |
| `accounts[].balance_updated_at` | time of the live read, else `balances.last_updated_datetime` (often null) |
| `credit_liabilities[]` | `liabilities.credit[]` (same field names) |
| `recurring_inflows[].average_amount` | `abs(average_amount.amount)` |
| `recurring_inflows[].frequency` | `frequency` (`WEEKLY`, `BIWEEKLY`, `SEMI_MONTHLY`, `MONTHLY`) |
| `recurring_inflows[].id` | `stream_id` |
| `items[].status` | `"ok"`, or `"login_required"` when Plaid returns `ITEM_LOGIN_REQUIRED` |

Unknown account types (`investment`, `loan`, …) are ignored by the app today.

### `DELETE /v1/plaid/items/{id}`

Server calls `/item/remove` and deletes the stored token. Response: `{}`.
The app keeps the records from that bank as manual ones.

## How the app merges a snapshot

See `SyncMerger.swift`; in short:

- **Checking/savings → accounts.** Balance = available, else current. Matched by
  Plaid account id, so renaming in the app is safe.
- **Credit cards → bills.** Amount = last statement balance; due day = day of
  `next_payment_due_date`. Cycles before the bank's next due date count as
  settled (unless `is_overdue`). A payment made after the statement was issued
  that meets the minimum marks the current cycle paid — and drops any payment
  the user had scheduled in the app for that cycle, so it isn't counted twice.
- **Payroll → recurring deposits.** Active inflow streams with a known
  frequency; inactive streams remove their deposit.
- **User choices are kept:** names, icons, autopay settings, and which checking
  account pays a card. Manual records are never touched.

## When the app asks for live balances

- Pull to refresh (Home, Accounts), **Sync now**, and right after connecting
  or reconnecting a bank → `balances=realtime`.
- Automatic sync when the app opens (if the last one is over 15 minutes old)
  → `balances=cached`.

Each synced account shows "● Live · 2:14 PM" or "Bank balance as of …"
(amber after 12 hours).

## Next steps

1. Run `wallet-server` against Plaid **Sandbox** (`npm run sandbox-check`;
   in Link, sandbox login is `user_good` / `pass_good`).
2. Add the LinkKit package (see README), set the server URL and access token
   in Settings → Bank connections → Cashline server.
3. Later: Plaid webhooks + push notifications, Sign in with Apple.
