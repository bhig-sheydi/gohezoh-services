import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import CustomerPaymentReceipt from './CustomerPaymentReceipt'

describe('customer payment receipt', () => {
  it('shows a branded paid receipt with separate transaction details', () => {
    render(<CustomerPaymentReceipt requestNumber="REQ-1" orderNumber="ORD-1" amount={2500} currency="NGN" payments={[{
      payment_number: 'PAY-1', amount: 2500, currency: 'NGN', method: 'bank_transfer', received_at: '2026-10-21T10:00:00Z', status: 'received',
    }]} />)
    const receipt = screen.getByRole('region', { name: 'Payment receipt for REQ-1' })
    expect(receipt).toHaveTextContent('KWIK-PARSEL')
    expect(screen.getByAltText('Kwik-Parsel logo')).toHaveAttribute('src', '/favicon.svg')
    expect(receipt).toHaveTextContent('Paid')
    expect(receipt).toHaveTextContent('PAY-1')
    expect(receipt).toHaveTextContent('ORD-1')
    expect(screen.getByText('Balance').nextElementSibling).toHaveTextContent('₦0.00')
  })

  it('does not call an unpaid charge a paid receipt', () => {
    render(<CustomerPaymentReceipt requestNumber="REQ-2" amount={2500} currency="NGN" payments={[]} />)
    expect(screen.getByRole('region', { name: 'Payment receipt for REQ-2' })).toHaveTextContent('Awaiting payment')
    expect(screen.getByText('Balance').nextElementSibling).toHaveTextContent('₦2,500.00')
  })
})
