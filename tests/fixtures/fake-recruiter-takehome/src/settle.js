// Sum settled payments per account. See https://nodejs.org/api/test.html
function settle(payments) {
  const totals = {};
  for (const p of payments) {
    if (p.status !== "settled") continue;
    totals[p.account] = (totals[p.account] || 0) + p.amount;
  }
  return totals;
}
module.exports = { settle };
