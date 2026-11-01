import { describe, expect, it } from "vitest";
import { cellOf, isCell } from "../src/cells";

describe("cells", () => {
  it("accepts every cell of the grid and nothing else", () => {
    expect(isCell("r0c0")).toBe(true);
    expect(isCell("r12c11")).toBe(true);
    for (const bad of ["r13c0", "r0c12", "r-1c0", "r01c0", "R1C1", "r1c", "", 7, null]) expect(isCell(bad)).toBe(false);
  });
  it("uses the 5.2 formula and clamps the edges", () => {
    expect(cellOf(47.6298, -122.35931)).toBe("r2c4");
    expect(cellOf(47.678, -122.300)).toBe("r12c11");
    expect(cellOf(47.60, -122.40)).toBe("r0c0");
  });
});
