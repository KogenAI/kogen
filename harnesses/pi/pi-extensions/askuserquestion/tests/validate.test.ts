import { describe, expect, it } from "vitest";
import { validateUniqueness } from "../src/validate.ts";
import type { Question } from "../src/schema.ts";

const q = (text: string, labels: string[]): Question => ({
  question: text,
  header: text.slice(0, 12),
  multiSelect: false,
  options: labels.map((l) => ({ label: l })),
});

describe("validateUniqueness", () => {
  it("returns null for valid unique questions and options", () => {
    const result = validateUniqueness([
      q("Color?", ["Red", "Blue"]),
      q("Size?", ["Large", "Small"]),
    ]);
    expect(result).toBeNull();
  });

  it("returns error message for duplicate question text", () => {
    const result = validateUniqueness([
      q("Color?", ["Red"]),
      q("Color?", ["Blue"]),
    ]);
    expect(result).toContain("Color?");
  });

  it("returns error message for duplicate option label within a question", () => {
    const result = validateUniqueness([q("Pick one", ["Same", "Same"])]);
    expect(result).toContain("Same");
  });

  it("returns null for empty question list", () => {
    expect(validateUniqueness([])).toBeNull();
  });
});
