export type WithdrawalQuote = {
  netAmountNgn: number
  transferFeeNgn: number
  stampDutyNgn: number
  grossDebitNgn: number
  remainderNgn: number
}

// A quote is only a preview; the payout function recalculates charges when it reserves the balance.
export function parseWithdrawalQuote(value: unknown, availableNgn: number): WithdrawalQuote | null {
  if (!value || typeof value !== 'object') return null
  const row = value as Partial<WithdrawalQuote>
  const amounts = [row.netAmountNgn, row.transferFeeNgn, row.stampDutyNgn, row.grossDebitNgn, row.remainderNgn]
  if (!Number.isSafeInteger(availableNgn) || availableNgn <= 0 || amounts.some((amount) => !Number.isSafeInteger(amount) || Number(amount) < 0)) return null
  const quote = row as WithdrawalQuote
  if (quote.netAmountNgn <= 0 || quote.grossDebitNgn !== quote.netAmountNgn + quote.transferFeeNgn + quote.stampDutyNgn
    || quote.grossDebitNgn + quote.remainderNgn !== availableNgn) return null
  return quote
}
