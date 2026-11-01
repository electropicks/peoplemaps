import { describe, expect, it } from "vitest";
import { StorageUnavailable } from "../src/errors";
import { d1Sql } from "../src/store-d1";

const refusing = (message: string) => {
  const fail = async () => { throw new Error(message); };
  const prepared = { bind: () => prepared, all: fail, run: fail };
  return d1Sql({ prepare: () => prepared, batch: fail } as unknown as D1Database);
};

describe("D1 limit errors", () => {
  for (const kind of ["read", "write"]) {
    it(`turns the daily row ${kind} limit into StorageUnavailable`, async () => {
      const sql = refusing(`D1_ERROR: Your account has exceeded D1's free tier daily row ${kind} limit. Upgrade to a paid plan or wait until tomorrow (midnight UTC) to continue.`);
      await expect(sql.all("SELECT 1")).rejects.toBeInstanceOf(StorageUnavailable);
      await expect(sql.run("SELECT 1")).rejects.toBeInstanceOf(StorageUnavailable);
      await expect(sql.batch([])).rejects.toBeInstanceOf(StorageUnavailable);
    });
  }
  for (const message of ["Exceeded maximum DB size.", "Your account has exceeded D1's maximum account storage limit, please contact Cloudflare to raise your limit"]) {
    it(`turns "${message.slice(0, 30)}…" into StorageUnavailable`, async () => {
      await expect(refusing(`D1_ERROR: ${message}`).run("INSERT")).rejects.toMatchObject({ untilMidnight: false });
      await expect(refusing(`D1_ERROR: ${message}`).run("INSERT")).rejects.toBeInstanceOf(StorageUnavailable);
    });
  }
  it("leaves other errors that mention a limit alone", async () => {
    for (const message of ["D1 DB exceeded its CPU time limit and was reset.", "D1 query result exceeded the maximum response size limit of 50 MB", "UNIQUE constraint failed: reports.id"]) {
      await expect(refusing(message).all("SELECT 1")).rejects.toThrow(message);
    }
  });
});
