import { describe, expect, it } from "vitest";
import { cellOf, isCell } from "../src/cells";

describe("cells", () => {
  it("accepts every cell of the grid and nothing else", () => {
    expect(isCell("r0c0")).toBe(true);
    expect(isCell("r49c26")).toBe(true);
    for (const bad of ["r50c0", "r0c27", "r-1c0", "r01c0", "R1C1", "r1c", "", 7, null]) expect(isCell(bad)).toBe(false);
  });
  it("uses the 5.2 formula and clamps the edges", () => {
    expect(cellOf(47.6298, -122.35931)).toBe("r27c10");
    expect(cellOf(47.49, -122.44)).toBe("r0c0");
    expect(cellOf(47.74, -122.24)).toBe("r49c26");
    expect(cellOf(47.40, -122.50)).toBe("r0c0");
    expect(cellOf(47.80, -122.20)).toBe("r49c26");
  });
});
