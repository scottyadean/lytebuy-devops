// The resize decisions, with no AWS and no I/O in sight (lb-28).
//
// SPLIT OUT ON PURPOSE. Everything here is a pure function of a key and the
// configured widths, so it is testable without S3, without a Lambda runtime,
// and without sharp. The handler in index.js does the I/O and nothing else.
// The first version of this file mixed the two and the parsing could only be
// exercised by deploying it.

/** Variant key -> the original it derives from, or null if not a variant.
 *
 *  `vendors/x/products/photo.png-400w.webp`
 *      -> { originalKey: "vendors/x/products/photo.png", width: 400 }
 *
 *  The width is APPENDED rather than replacing the extension, so the original
 *  key survives intact inside the variant key. That makes the mapping back
 *  exact instead of a guess about what extension the original had - and it
 *  keeps working for a filename that contains its own hyphens and digits,
 *  which `photo-1790292853965-0.png` (a real key in this bucket) does.
 */
function parseVariantKey(variantKey) {
  const match = /^(.+)-(\d+)w\.webp$/.exec(variantKey);
  if (!match) return null;
  return { originalKey: match[1], width: parseInt(match[2], 10) };
}

/** Extensions worth converting.
 *
 *  GIF is deliberately absent: it may be animated, and resizing would flatten
 *  it to a single frame - a silent content change, which is worse than serving
 *  the original. SVG is absent because it is already small and resizing a
 *  vector to a fixed width throws away the one thing it is good at.
 */
const RESIZABLE = new Set(["png", "jpg", "jpeg", "webp"]);

function extensionOf(key) {
  const dot = key.lastIndexOf(".");
  return dot === -1 ? "" : key.slice(dot + 1).toLowerCase();
}

/** Variant key for an original at a given width.
 *
 *  The one place the naming scheme lives. The resizer writes these and the
 *  client builds the same strings to request them, so a change here is a
 *  change everywhere - which is the point of it being a named function rather
 *  than string concatenation at each site.
 */
function variantKeyFor(originalKey, width) {
  return `${originalKey}-${width}w.webp`;
}

/**
 * Should this UPLOAD have variants generated, and which?
 *
 * Returns `{ ok: true, widths }` or `{ ok: false, reason }`. A reason rather
 * than a bare false so the handler can log WHY something was skipped -
 * "already a variant" is routine, "not an image" may be a misconfigured
 * trigger.
 */
function planUpload(key, widths) {
  // THE RECURSION GUARD, and the reason this is the first check. The function
  // writes .webp files into the SAME bucket that triggers it, so without this
  // every variant triggers another resize: 400w begets 400w-400w begets
  // 400w-400w-400w, until something gives. S3 does not stop it and the bill
  // does not care.
  if (parseVariantKey(key)) return { ok: false, reason: "already a derived image" };

  if (!RESIZABLE.has(extensionOf(key))) {
    return { ok: false, reason: "not a resizable image" };
  }

  // The paywall. Digital goods are private objects reached only through a
  // presigned URL for a buyer who paid, and nothing should read them here -
  // belt and braces alongside the prefix filter on the trigger itself.
  if (key.includes("/downloads/")) {
    return { ok: false, reason: "digital download, not a display image" };
  }

  return { ok: true, widths };
}

/**
 * Should this REQUEST be served by resizing, and from what?
 *
 * Retained for the request-time path and its tests. Returns
 * `{ ok: true, originalKey, width }`, or `{ ok: false, reason }`.
 */
function planResize(requestKey, allowedWidths) {
  const parsed = parseVariantKey(requestKey);
  if (!parsed) return { ok: false, reason: "not a variant key" };

  // A width we did not configure is REFUSED, not generated. Without this, a
  // crawler walking 1..2000 mints two thousand objects per image and we pay to
  // store every one of them. The allowed set is the whole defence, because the
  // key is otherwise attacker-controlled.
  if (!allowedWidths.includes(parsed.width)) {
    return { ok: false, reason: `width ${parsed.width} is not configured` };
  }
  if (!RESIZABLE.has(extensionOf(parsed.originalKey))) {
    return { ok: false, reason: "original is not a resizable image" };
  }

  // REFUSE A VARIANT OF A VARIANT. `photo.png-400w.webp-800w.webp` parses
  // happily - the "original" is itself a variant, and .webp is resizable - so
  // without this it would UPSCALE a 400px thumbnail to 800px and store the
  // blurry result. Found by probing the parser rather than by a failing test:
  // the intended path never produces a chained key, so nothing exercised it.
  if (parseVariantKey(parsed.originalKey)) {
    return { ok: false, reason: "refusing to resize a derived image" };
  }

  return { ok: true, originalKey: parsed.originalKey, width: parsed.width };
}

/** Parse the configured widths. Rejects anything non-numeric or absurd rather
 *  than silently dropping it, so a typo in Terraform fails loudly at cold
 *  start instead of quietly disabling a size in production. */
function parseWidths(raw) {
  const widths = String(raw || "")
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part !== "")
    .map((part) => {
      if (!/^\d+$/.test(part)) throw new Error(`RESIZE_WIDTHS has a non-numeric entry: ${part}`);
      const width = parseInt(part, 10);
      if (width < 1 || width > 4000) throw new Error(`RESIZE_WIDTHS out of range: ${width}`);
      return width;
    });
  if (widths.length === 0) throw new Error("RESIZE_WIDTHS is empty");
  return widths;
}

/** A year, immutable. Safe because a variant key is derived from a key that
 *  never changes contents - re-uploading a photo produces a NEW key (the
 *  backend stamps a uuid), so a cached variant can never be stale. */
const CACHE_CONTROL = "public, max-age=31536000, immutable";

module.exports = {
  parseVariantKey,
  variantKeyFor,
  planUpload,
  planResize,
  parseWidths,
  extensionOf,
  RESIZABLE,
  CACHE_CONTROL,
};
