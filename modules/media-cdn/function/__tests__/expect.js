// A five-matcher `expect` over node:assert, so these tests run under
// `node --test` with NO dev dependency and no runner config.
//
// Deliberately tiny and deliberately not Jest. The Lambda bundle is built by
// build.sh and shipped to AWS; adding a test framework to this package would
// put it in that dependency tree for no benefit. Only the matchers this suite
// actually uses are here - an unknown matcher should be a loud TypeError
// rather than a silent pass.

const assert = require("node:assert/strict");

function expect(actual) {
  return {
    toBe(expected) {
      assert.strictEqual(actual, expected);
    },
    toEqual(expected) {
      assert.deepStrictEqual(actual, expected);
    },
    toBeNull() {
      assert.strictEqual(actual, null);
    },
    toMatch(re) {
      assert.match(String(actual), re);
    },
    toMatchObject(subset) {
      // A SUBSET match, like Jest's: only the named keys are compared, so a
      // test asserting { ok: true } does not have to restate every field the
      // function happens to return.
      for (const [key, want] of Object.entries(subset)) {
        assert.deepStrictEqual(
          actual?.[key],
          want,
          `key ${JSON.stringify(key)} did not match`,
        );
      }
    },
    toThrow(expected) {
      // `actual` is a function here, matching Jest's calling convention.
      assert.throws(actual, expected);
    },
  };
}

module.exports = { expect };
