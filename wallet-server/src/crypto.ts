import { createCipheriv, createDecipheriv, randomBytes, timingSafeEqual, createHash } from "node:crypto";

// Bank access tokens are encrypted at rest with AES-256-GCM. If the database
// leaks without the key, the tokens are useless.

export class TokenCipher {
  private readonly key: Buffer;

  constructor(base64Key: string) {
    const key = Buffer.from(base64Key, "base64");
    if (key.length !== 32) throw new Error("CASHLINE_ENCRYPTION_KEY must be 32 bytes, base64 (openssl rand -base64 32)");
    this.key = key;
  }

  encrypt(plain: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    const ct = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
    return ["v1", iv.toString("base64"), cipher.getAuthTag().toString("base64"), ct.toString("base64")].join(":");
  }

  decrypt(stored: string): string {
    const [v, iv, tag, ct] = stored.split(":");
    if (v !== "v1" || !iv || !tag || !ct) throw new Error("Unrecognized encrypted token format");
    const decipher = createDecipheriv("aes-256-gcm", this.key, Buffer.from(iv, "base64"));
    decipher.setAuthTag(Buffer.from(tag, "base64"));
    return Buffer.concat([decipher.update(Buffer.from(ct, "base64")), decipher.final()]).toString("utf8");
  }
}

/** Constant-time string comparison (via hashes, so lengths don't leak). */
export function safeEqual(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb);
}
