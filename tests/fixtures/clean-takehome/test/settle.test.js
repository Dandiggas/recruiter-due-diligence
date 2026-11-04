const test = require("node:test");
const assert = require("node:assert");
const { settle } = require("../src/settle");
test("only settled payments count", () => {
  assert.deepStrictEqual(settle([{ account: "a", amount: 5, status: "settled" }, { account: "a", amount: 3, status: "pending" }]), { a: 5 });
});
