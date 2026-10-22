import './customer-payment-receipt.css'

type Payment = {
  payment_number: string
  amount: number
  currency: string
  method: string
  received_at: string
  status: string
}

type Props = {
  requestNumber: string
  orderNumber?: string
  amount: number
  currency: string
  payments: Payment[]
}

const money = (amount: number, currency: string) => new Intl.NumberFormat('en-NG', { style: 'currency', currency }).format(amount)
const date = (value: string) => new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium' }).format(new Date(value))

export default function CustomerPaymentReceipt({ requestNumber, orderNumber, amount, currency, payments }: Props) {
  const received = payments.filter((payment) => payment.status === 'received').reduce((sum, payment) => sum + Number(payment.amount), 0)
  const balance = Math.max(0, Number(amount) - received)
  const status = balance === 0 ? 'Paid' : received > 0 ? 'Part paid' : 'Awaiting payment'

  return <section className="customer-payment-receipt" aria-label={`Payment receipt for ${requestNumber}`}>
    <div className="customer-receipt-header">
      <div className="customer-receipt-brand"><img src="/favicon.svg" alt="Kwik-Parsel logo" /><div><strong>KWIK-PARSEL</strong><small>BY GOHEZO INTEGRATED SERVICES</small></div></div>
      <span className={`customer-receipt-status ${balance === 0 ? 'is-paid' : received > 0 ? 'is-part-paid' : 'is-awaiting'}`}>{status}</span>
    </div>
    <div className="customer-receipt-main"><div><span>PAYMENT RECEIPT</span><h3>{money(Number(amount), currency)}</h3><p>Total delivery charge</p></div><div className="customer-receipt-reference"><small>REQUEST</small><strong>{requestNumber}</strong>{orderNumber && <><small>ORDER</small><strong>{orderNumber}</strong></>}</div></div>
    <dl className="customer-receipt-totals"><div><dt>Total</dt><dd>{money(Number(amount), currency)}</dd></div><div><dt>Received</dt><dd>{money(received, currency)}</dd></div><div className="customer-receipt-balance"><dt>Balance</dt><dd>{money(balance, currency)}</dd></div></dl>
    {payments.length > 0 && <div className="customer-receipt-history"><h4>Recorded payments</h4>{payments.map((payment) => <div className="customer-receipt-payment" key={payment.payment_number}><div><strong>{payment.payment_number}</strong><small>{payment.method.replaceAll('_', ' ')} · {date(payment.received_at)}{payment.status === 'reversed' ? ' · Reversed' : ''}</small></div><span>{money(Number(payment.amount), payment.currency)}</span></div>)}</div>}
  </section>
}
