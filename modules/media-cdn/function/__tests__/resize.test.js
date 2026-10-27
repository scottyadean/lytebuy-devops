// lb-28: the resize decisions.
//
// These are the only parts of the function that can be wrong in a way AWS will
// not tell us about. The I/O is thin and obvious; the KEY PARSING decides what
// gets generated, and the width allow-list is the only thing standing between
// an attacker-controlled key and unbounded storage billing.

// describe/it come from node:test explicitly rather than as globals, so this
// file runs under `node --test` with no runner config and no dev dependency.
const { describe, it } = require("node:test");
const { expect } = require("./expect");

const {
  planResize,
  planUpload,
  variantKeyFor,
  parseWidths,
  parseVariantKey,
  extensionOf,
} = require("../resize");

const WIDTHS = [400, 800];

describe("parseVariantKey", () => {
  it("maps a variant back to its original", () => {
    expect(parseVariantKey("vendors/a/products/photo.png-400w.webp")).toEqual({
      originalKey: "vendors/a/products/photo.png",
      width: 400,
    });
  });

  it("survives a filename containing hyphens and digits", () => {
    // A REAL key shape from this bucket. A regex anchored less carefully would
    // split on the first hyphen-digit run and ask S3 for a key that does not
    // exist, so every product image would 404 through the resizer.
    expect(parseVariantKey("vendors/a/products/photo-1790292853965-0.png-400w.webp")).toEqual({
      originalKey: "vendors/a/products/photo-1790292853965-0.png",
      width: 400,
    });
  });

  it("is null for a plain object key", () => {
    // The S3 origin serves these. If this returned a match, every normal image
    // request would be routed into the resizer.
    expect(parseVariantKey("vendors/a/products/photo.png")).toBeNull();
  });

  it("is null when the width is not a number", () => {
    expect(parseVariantKey("vendors/a/products/photo.png-abcw.webp")).toBeNull();
  });
});

describe("planResize", () => {
  it("accepts a configured width", () => {
    const plan = planResize("vendors/a/products/photo.png-400w.webp", WIDTHS);
    expect(plan).toMatchObject({ ok: true, width: 400 });
  });

  it("REFUSES a width that is not configured", () => {
    // THE billing guard. The key is attacker-controlled, so without the
    // allow-list a crawler walking 1..2000 mints 2000 objects per image and we
    // pay to store all of them.
    const plan = planResize("vendors/a/products/photo.png-1234w.webp", WIDTHS);
    expect(plan.ok).toBe(false);
    expect(plan.reason).toMatch(/not configured/);
  });

  it("refuses an animated-capable format", () => {
    // Resizing a GIF flattens it to one frame - a silent content change, which
    // is worse than serving the original untouched.
    expect(planResize("vendors/a/products/clip.gif-400w.webp", WIDTHS).ok).toBe(false);
  });

  it("refuses a digital-download key", () => {
    // downloads/ is the PAYWALL (app/services/digital_assets.py): private
    // objects reached only by a presigned URL for a buyer who paid. The
    // resizer must never read from there, whatever the extension.
    expect(planResize("vendors/a/downloads/model.stl-400w.webp", WIDTHS).ok).toBe(false);
  });

  it("refuses a variant of a variant", () => {
    // `photo.png-400w.webp-800w.webp` parses fine and its "original" is a
    // .webp, which IS resizable - so this would upscale a 400px thumbnail to
    // 800px and cache the blurry result. CloudFront would then serve that as
    // the product photo.
    const plan = planResize("vendors/a/products/photo.png-400w.webp-800w.webp", WIDTHS);
    expect(plan.ok).toBe(false);
    expect(plan.reason).toMatch(/derived/);
  });

  it("gives a distinct reason per refusal", () => {
    // "Unknown width" is someone probing; "not an image" is a mistake. Logging
    // one reason for both would hide the first behind the second.
    const reasons = [
      planResize("x.png-9999w.webp", WIDTHS).reason,
      planResize("x.gif-400w.webp", WIDTHS).reason,
      planResize("x.png", WIDTHS).reason,
      planResize("x.png-400w.webp-800w.webp", WIDTHS).reason,
    ];
    expect(new Set(reasons).size).toBe(4);
  });
});

describe("parseWidths", () => {
  it("parses a comma list with spaces", () => {
    expect(parseWidths("400, 800")).toEqual([400, 800]);
  });

  it("throws on a non-numeric entry rather than dropping it", () => {
    // A typo in Terraform must fail the first invocation loudly. Dropping it
    // silently disables a size in production with no symptom until someone
    // notices the images are full-size again.
    expect(() => parseWidths("400,abc")).toThrow(/non-numeric/);
  });

  it("throws on an empty config", () => {
    expect(() => parseWidths("")).toThrow(/empty/);
  });

  it("throws on an absurd width", () => {
    // An 80000px resize is an out-of-memory crash, not an image.
    expect(() => parseWidths("80000")).toThrow(/out of range/);
  });
});

describe("extensionOf", () => {
  it("lowercases, so an uppercase upload still resizes", () => {
    // Vendors upload PHOTO.PNG from a camera roll. A case-sensitive check
    // would refuse exactly those and nobody would know why.
    expect(extensionOf("a/b/PHOTO.PNG")).toBe("png");
  });

  it("is empty for a key with no extension", () => {
    expect(extensionOf("a/b/photo")).toBe("");
  });
});

// --- the upload path (the S3 trigger) --------------------------------------

describe("planUpload", () => {
  it("resizes an ordinary product photo", () => {
    expect(planUpload("vendors/a/products/photo.png", WIDTHS)).toMatchObject({
      ok: true,
      widths: WIDTHS,
    });
  });

  it("REFUSES a key that is already a variant", () => {
    // THE runaway guard, and the reason it is the first check in the function.
    // Variants are written into the SAME bucket that triggers the Lambda, so
    // without this every variant triggers another resize - 400w begets
    // 400w-400w begets 400w-400w-400w. S3 will not stop it and the bill will
    // not care.
    const plan = planUpload("vendors/a/products/photo.png-400w.webp", WIDTHS);
    expect(plan.ok).toBe(false);
    expect(plan.reason).toMatch(/derived/);
  });

  it("refuses a digital-download key", () => {
    // downloads/ is the paywall: private objects a buyer reaches only through
    // a presigned URL after paying. The trigger is prefix-filtered too; this
    // is the second layer.
    expect(planUpload("vendors/a/downloads/model.png", WIDTHS).ok).toBe(false);
  });

  it("refuses a format that may be animated", () => {
    expect(planUpload("vendors/a/products/clip.gif", WIDTHS).ok).toBe(false);
  });

  it("accepts an uppercase extension", () => {
    // Camera rolls produce PHOTO.JPG. A case-sensitive check would skip
    // exactly those uploads and nobody would know why.
    expect(planUpload("vendors/a/products/PHOTO.JPG", WIDTHS).ok).toBe(true);
  });
});

describe("variantKeyFor", () => {
  it("round-trips through parseVariantKey", () => {
    // These two have to agree or the resizer writes keys the client never
    // requests. Holding both in one module is why that is checkable at all.
    const original = "vendors/a/products/photo-1790292853965-0.png";
    const variant = variantKeyFor(original, 400);
    expect(parseVariantKey(variant)).toEqual({ originalKey: original, width: 400 });
  });

  it("is refused by planUpload, closing the loop", () => {
    // The output of the resizer must be something the resizer itself skips.
    // If these two disagreed, the recursion guard would not hold.
    const variant = variantKeyFor("vendors/a/products/photo.png", 800);
    expect(planUpload(variant, WIDTHS).ok).toBe(false);
  });
});
