# cashline-server

The backend for the Cashline iOS app's bank connections. It keeps the Plaid
keys and every bank's access token on the server (never on the phone), and
returns one JSON "snapshot" the app merges into its data. The full API is in
[`../wallet-ios/docs/BACKEND.md`](../wallet-ios/docs/BACKEND.md).

- Node 22.18+, **no dependencies**: Node runs the TypeScript directly, and
  stores data in its built-in SQLite.
- Bank access tokens are encrypted at rest (AES-256-GCM).
- Each person using it has their own access token; they only ever see their
  own banks.

## Exact balances: how it works

Plaid has two ways to get a balance, and the server uses both:

| | `/accounts/get` (cached) | `/accounts/balance/get` (live) |
|---|---|---|
| Freshness | Plaid's last copy — often hours old | Read from the bank right now |
| Cost | Included | **Billed per call** |
| Speed | Fast | A few seconds, sometimes more |
| Used when | App opens / background sync | Pull to refresh, Sync now |

- **Live reads cover checking and savings only.** Credit cards use the
  statement data from Liabilities. Some banks, like Capital One, can't give
  live card balances at all.
- **The balance the app shows is the _available_ balance.** That's what you
  can actually spend, with pending debits already taken out. If a bank
  doesn't report one, the app falls back to the current balance.
- **Live calls are throttled per bank connection.** By default there's at most
  one every 5 minutes (`REALTIME_MIN_INTERVAL_SECONDS`). Within that window
  the last live read is reused, and still labeled live with its time.
- **A failed live call falls back to the cached balance.** It isn't retried
  in a loop, because Plaid bills failed calls too.
- **Every account says how fresh its balance is.** The snapshot carries
  `balance_source` (`realtime`/`cached`) and `balance_updated_at`. The app
  shows "● Live · 2:14 PM" or "Bank balance as of 9:02 AM".

Plaid's newer `/signal/evaluate` endpoint also returns balances, but it's
meant for checking ACH payment risk. For showing balances, Plaid's guidance is
to stay on `/accounts/balance/get`.

## Run it locally

```sh
cd wallet-server
cp .env.example .env      # fill in the values (see comments in the file)
npm start                 # http://localhost:8787
npm test                  # 15 tests, uses a fake Plaid
```

No Plaid keys yet? `node scripts/dev-fake.ts` runs the same server with a
fake bank. In the app, set Bank connections → Cashline server, with the URL
and the token it prints.

With Sandbox keys from https://dashboard.plaid.com/developers/keys:

```sh
PLAID_CLIENT_ID=... PLAID_SECRET=... npm run sandbox-check
```

This links Plaid's test bank without the app, then prints cached balances,
live balances, card statements and paydays.

## Deploy

Any host that runs a Docker container with a persistent disk works, for
example Fly.io, Railway, Render, or a small VPS:

```sh
docker build -t cashline-server .
docker run -p 8787:8787 -v cashline-data:/data --env-file .env cashline-server
```

Put it behind HTTPS. Most hosts do that for you. Then point the app at it in
Settings → Bank connections.

## Going to production with Plaid

1. **Request Production access** in the Plaid dashboard for Transactions and
   Liabilities. Balance comes with them and is billed per call.
2. **Register OAuth.** Big banks like Chase, Wells Fargo and Capital One sign
   in through OAuth and need a redirect URI. It's an iOS universal link
   registered in the Plaid dashboard, set as `PLAID_REDIRECT_URI`.
3. **Switch environments.** Set `PLAID_ENV=production` and use the production
   secret.
4. **Back up the database** (`/data/cashline.db`) and **the encryption key**,
   separately. Without the key, the stored tokens can't be decrypted, and
   everyone would have to re-link their banks.

## Not built yet

- **Webhooks.** Plaid can notify the server when new data is ready or a bank
  needs re-login. Today the app finds out on its next sync, then shows
  "Reconnect".
- **Sign in with Apple.** It would replace the hand-issued access tokens if
  more people use this.
