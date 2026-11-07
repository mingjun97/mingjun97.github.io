# Cashline for iOS

A native SwiftUI version of the Cashline bill & cash-flow tracker at
[`/wallet/`](../wallet/index.html): checking accounts, credit-card and utility
bills, expected deposits, a 30-day running-balance projection, and alerts when
an account is about to come up short.

## What's here

```
wallet-ios/
├── project.yml                 XcodeGen spec → Cashline.xcodeproj
├── Cashline/                   the iOS app (SwiftUI, iOS 17+)
│   ├── App/                    entry point, AppStore (state + undo + sync), theme
│   ├── Views/                  Home, Bills, Accounts, Settings, cards, sheets
│   ├── Services/               notifications, Plaid Link, backend settings
│   └── Resources/              asset catalog (icon, accent color)
├── Packages/CashlineCore/      all the logic, platform-neutral, unit-tested
│   ├── Sources/CashlineCore/   models, due-date engine, actions, persistence
│   │   └── Sync/               bank-sync layer (backend client, merge rules, mock)
│   └── Tests/                  30 tests, incl. importing a web-app backup
└── docs/BACKEND.md             server contract for the Plaid integration
```

**CashlineCore** is a line-by-line port of the web app's logic (due dates,
autopay roll-forward, scheduled/held payments, next-statement charges,
payroll schedules, projections). It's pure Foundation, so it builds and
tests anywhere Swift runs.

## Run it

Requires a Mac with Xcode 16 or newer.

```sh
brew install xcodegen
cd wallet-ios
xcodegen            # creates Cashline.xcodeproj
open Cashline.xcodeproj
```

Pick an iPhone simulator and Run. To run on your own phone, set your team
under Signing & Capabilities (or `DEVELOPMENT_TEAM` in `project.yml`).

Run the logic tests (Mac or Linux):

```sh
cd wallet-ios/Packages/CashlineCore
swift test
```

## Compared with the web app

Same features and the same data. Differences:

- **Your web data comes along.** Export a backup in the web app (Settings →
  Export), then in iOS Settings → Import backup. It works the other way too.
- **Real reminders.** Local notifications fire on schedule even when the app is
  closed (the web app could only notify while open).
- **Native interactions:** pull to refresh, long-press menus on bill cards,
  drag one account onto another to transfer, system date pickers, Undo on
  every change.
- **Home calendar** is a horizontally scrolling 5-week day strip pinned above
  the timeline; tapping a day jumps the timeline there and scrolling the
  timeline moves the highlight.
- **Google Drive backup** (a claude.ai-only feature of the web app) is replaced
  by the system file exporter, which can save to iCloud Drive, Google Drive,
  etc.

Data lives in `Application Support/Cashline/cashline.v1.json` on the device,
protected by iOS file encryption.

## Bank connections (Plaid) — ready for a backend

Settings → **Bank connections** has three modes:

| Mode | What it does |
|---|---|
| Off (default) | Everything entered by hand, like the web app. |
| Demo bank | A built-in fake bank. Try the whole connect → sync flow with no server. |
| Cashline server | Talks to your server, which talks to Plaid. |

Synced data fills in automatically: checking balances, credit-card statement
amounts and due dates (marking cards paid when the bank shows a payment), and
payroll schedules. Your own settings — names, icons, autopay, which account
pays a card — are kept across syncs, and manual entries are never touched.

What's left for a real Plaid integration:

1. **Build the server** — four endpoints, specified in
   [docs/BACKEND.md](docs/BACKEND.md). Plaid secrets and bank tokens stay there.
2. **Add the Plaid SDK** — in `project.yml`, uncomment the `LinkKit` package
   and dependency, then run `xcodegen` again. `PlaidLinkPresenter.swift` picks
   it up automatically (`#if canImport(LinkKit)`).
3. **User sign-in** — give the app a token for your server with
   `AuthTokenStore.shared.set(token)` (e.g. after Sign in with Apple).

To swap Plaid for another aggregator, only the server changes: the app's
`SyncSnapshot` format is provider-neutral.
