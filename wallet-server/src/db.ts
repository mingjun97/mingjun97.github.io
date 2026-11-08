import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export interface ItemRow {
  id: string;
  user_id: string;
  access_token_enc: string;
  institution_name: string | null;
  status: string;
  created_at: string;
  last_synced_at: string | null;
}

/** Last live balance read per account, reused while live calls are throttled. */
export interface LiveBalanceRow {
  account_id: string;
  item_id: string;
  available: number | null;
  current: number | null;
  fetched_at: string;
}

/** SQLite storage (built into Node). One file, no server to run. */
export class Store {
  readonly db: DatabaseSync;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        access_token_enc TEXT NOT NULL,
        institution_name TEXT,
        status TEXT NOT NULL DEFAULT 'ok',
        created_at TEXT NOT NULL,
        last_synced_at TEXT
      );
      CREATE INDEX IF NOT EXISTS items_user ON items(user_id);
      CREATE TABLE IF NOT EXISTS live_balances (
        account_id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        available REAL,
        current REAL,
        fetched_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS item_live_calls (
        item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
        last_call_at TEXT NOT NULL
      );
    `);
  }

  insertItem(row: Omit<ItemRow, "last_synced_at" | "status">) {
    this.db.prepare(
      `INSERT INTO items (id, user_id, access_token_enc, institution_name, status, created_at)
       VALUES (?, ?, ?, ?, 'ok', ?)
       ON CONFLICT(id) DO UPDATE SET access_token_enc = excluded.access_token_enc, status = 'ok'`,
    ).run(row.id, row.user_id, row.access_token_enc, row.institution_name, row.created_at);
  }

  items(userId: string): ItemRow[] {
    return this.db.prepare("SELECT * FROM items WHERE user_id = ? ORDER BY created_at").all(userId) as unknown as ItemRow[];
  }

  item(userId: string, id: string): ItemRow | undefined {
    return this.db.prepare("SELECT * FROM items WHERE user_id = ? AND id = ?").get(userId, id) as unknown as ItemRow | undefined;
  }

  updateItem(id: string, fields: { status?: string; last_synced_at?: string; institution_name?: string | null }) {
    const sets: string[] = [];
    const vals: (string | null)[] = [];
    for (const [k, v] of Object.entries(fields)) {
      if (v === undefined) continue;
      sets.push(`${k} = ?`);
      vals.push(v);
    }
    if (!sets.length) return;
    this.db.prepare(`UPDATE items SET ${sets.join(", ")} WHERE id = ?`).run(...vals, id);
  }

  deleteItem(id: string) {
    this.db.prepare("DELETE FROM live_balances WHERE item_id = ?").run(id);
    this.db.prepare("DELETE FROM item_live_calls WHERE item_id = ?").run(id);
    this.db.prepare("DELETE FROM items WHERE id = ?").run(id);
  }

  lastLiveCall(itemId: string): string | null {
    const r = this.db.prepare("SELECT last_call_at FROM item_live_calls WHERE item_id = ?").get(itemId) as
      | { last_call_at: string }
      | undefined;
    return r?.last_call_at ?? null;
  }

  recordLiveCall(itemId: string, at: string) {
    this.db.prepare(
      `INSERT INTO item_live_calls (item_id, last_call_at) VALUES (?, ?)
       ON CONFLICT(item_id) DO UPDATE SET last_call_at = excluded.last_call_at`,
    ).run(itemId, at);
  }

  saveLiveBalance(row: LiveBalanceRow) {
    this.db.prepare(
      `INSERT INTO live_balances (account_id, item_id, available, current, fetched_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(account_id) DO UPDATE SET available = excluded.available, current = excluded.current,
         fetched_at = excluded.fetched_at`,
    ).run(row.account_id, row.item_id, row.available, row.current, row.fetched_at);
  }

  liveBalances(itemId: string): Map<string, LiveBalanceRow> {
    const rows = this.db.prepare("SELECT * FROM live_balances WHERE item_id = ?").all(itemId) as unknown as LiveBalanceRow[];
    return new Map(rows.map((r) => [r.account_id, r]));
  }
}
