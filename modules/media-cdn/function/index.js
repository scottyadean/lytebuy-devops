// Generate WebP variants when an image is uploaded (lb-28).
//
// WHY ON UPLOAD. The request-time design was built first and abandoned: it
// needed a Lambda Function URL as a CloudFront origin, and a public Function
// URL returns 403 in this account however its resource policy is written -
// the function is never invoked at all (zero log streams), so the denial is
// above Lambda. Switching to AWS_IAM with a CloudFront OAC did not fix it. An
// S3 ObjectCreated trigger invokes Lambda directly and has none of that auth
// surface.
//
// The trade is real and accepted: objects already in the bucket need a one-off
// backfill (35 images), and adding a width means re-running it. Both are cheap
// at this scale, and cheaper than more hours spent on origin signing.
//
// THE ORIGINAL IS NEVER TOUCHED. It is the vendor's upload and their only
// copy, so a bad resize must not be able to destroy it. Variants are written
// to separate keys, and the IAM policy only permits writing `*w.webp`.
//
// IDEMPOTENT. Re-running over a key that already has variants simply
// overwrites them with identical bytes, so a backfill can be run twice without
// worrying about it.

const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const sharp = require("sharp");

const { planUpload, variantKeyFor, parseWidths, CACHE_CONTROL } = require("./resize");

const s3 = new S3Client({});

// Thrown at cold start, not per record: a bad config should fail the first
// invocation loudly rather than silently disable a size forever.
const WIDTHS = parseWidths(process.env.RESIZE_WIDTHS || "400,800");
const QUALITY = parseInt(process.env.RESIZE_QUALITY || "80", 10);

async function readObject(bucket, key) {
  const result = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const chunks = [];
  for await (const chunk of result.Body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

/** Resize to `width` preserving aspect ratio, then encode WebP.
 *
 *  `rotate()` comes first because it applies EXIF orientation. Without it a
 *  photo taken in portrait on a phone is resized sideways and the wrong
 *  orientation is baked into the variant permanently.
 *
 *  `withoutEnlargement` so a 300px upload is never upscaled to 400px, which
 *  looks worse than the original AND is a bigger file.
 */
async function toWebp(input, width) {
  return sharp(input)
    .rotate()
    .resize({ width, withoutEnlargement: true })
    .webp({ quality: QUALITY })
    .toBuffer();
}

async function writeVariant(bucket, key, body) {
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: body,
      ContentType: "image/webp",
      // The bucket serves no Cache-Control of its own, which is half of why a
      // browse feed re-downloaded every image on every scroll. Set it here so
      // a variant is cacheable for a year - safe because the key is derived
      // from an original that never changes contents (a re-upload gets a new
      // uuid from the backend).
      CacheControl: CACHE_CONTROL,
    }),
  );
}

/** Generate every configured width for one uploaded object. */
async function processObject(bucket, key) {
  const plan = planUpload(key, WIDTHS);
  if (!plan.ok) {
    console.log(JSON.stringify({ message: "skipped", key, reason: plan.reason }));
    return { key, skipped: plan.reason };
  }

  const original = await readObject(bucket, key);
  const written = [];

  for (const width of plan.widths) {
    const variantKey = variantKeyFor(key, width);
    const resized = await toWebp(original, width);
    await writeVariant(bucket, variantKey, resized);
    written.push({ variantKey, bytes: resized.length });
  }

  console.log(
    JSON.stringify({
      message: "resized",
      key,
      originalBytes: original.length,
      variants: written,
    }),
  );
  return { key, written };
}

/**
 * S3 ObjectCreated handler.
 *
 * Records are processed SEQUENTIALLY rather than in parallel. A batch of
 * uploads from one vendor would otherwise decode several large images at once
 * in a single 1536MB sandbox, and an out-of-memory kill loses the whole batch
 * instead of one image.
 */
exports.handler = async (event) => {
  const results = [];

  for (const record of event.Records || []) {
    const bucket = record.s3.bucket.name;
    // S3 event keys are URL-encoded: a space arrives as "+" and anything
    // non-ASCII as %XX. Reading record.s3.object.key raw asks for a key that
    // does not exist, which is a NoSuchKey on exactly the uploads with spaces
    // in the filename.
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    try {
      results.push(await processObject(bucket, key));
    } catch (error) {
      // Logged and swallowed, deliberately. Throwing makes S3 retry the whole
      // event, and a genuinely undecodable upload would then retry forever.
      // The original is still served; only the variant is missing.
      console.error(
        JSON.stringify({
          message: "resize failed",
          key,
          error: error.name || String(error),
          detail: error.message,
        }),
      );
      results.push({ key, error: error.name || String(error) });
    }
  }

  return { processed: results.length, results };
};
