import { describe, expect, it } from "vitest";
import { htmlToMarkdown } from "../../src/utils/formatters.js";

describe("htmlToMarkdown", () => {
  it("converts a simple <p> element to markdown text", () => {
    const result = htmlToMarkdown(
      "<html><body><p>hello</p></body></html>",
      "https://example.com",
    );
    expect(result.markdown.toLowerCase()).toContain("hello");
    expect(["readability", "turndown"]).toContain(result.method);
  });
});
