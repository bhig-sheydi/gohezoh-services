import type { WithdrawalQuote } from './lib/withdrawalQuote'
import './withdrawal-fee-preview.css'

const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)

export default function WithdrawalFeePreview({ quote }: { quote: WithdrawalQuote }) {
  return <section className="withdrawal-fee-preview" aria-label="Withdrawal breakdown">
    <h3>Withdrawal breakdown</h3>
    <dl>
      <div><dt>Earnings deducted</dt><dd>{money(quote.grossDebitNgn)}</dd></div>
      <div><dt>Paystack transfer fee</dt><dd>−{money(quote.transferFeeNgn)}</dd></div>
      <div><dt>Stamp duty</dt><dd>−{money(quote.stampDutyNgn)}</dd></div>
      <div className="withdrawal-fee-net"><dt>You receive at your bank</dt><dd>{money(quote.netAmountNgn)}</dd></div>
      {quote.remainderNgn > 0 && <div><dt>Remaining earnings</dt><dd>{money(quote.remainderNgn)}</dd></div>}
    </dl>
    <p>The transfer charges above are deducted from your earnings before money reaches your bank.</p>
  </section>
}
