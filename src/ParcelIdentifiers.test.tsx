import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import ParcelIdentifiers from './ParcelIdentifiers'
import { createParcelLabelsPdf } from './lib/parcel-label-pdf'

vi.mock('./lib/parcel-label-pdf', () => ({ createParcelLabelsPdf: vi.fn(async () => new Uint8Array([37, 80, 68, 70])) }))

const originalCreateObjectURL = URL.createObjectURL
const originalRevokeObjectURL = URL.revokeObjectURL
afterEach(() => {
  vi.restoreAllMocks()
  URL.createObjectURL = originalCreateObjectURL
  URL.revokeObjectURL = originalRevokeObjectURL
})

describe('parcel identification labels', () => {
  const parcels = [{ tracking_code: 'KWP-P-00000001', parcel_number: 1, description: 'Books', quantity: 2 }]

  it('groups each parcel ID, description, quantity, and barcode in one label', () => {
    render(<ParcelIdentifiers parcels={parcels} />)
    expect(screen.getByRole('heading', { name: 'Parcel IDs' })).toBeInTheDocument()
    expect(screen.getByText('PARCEL 1')).toBeInTheDocument()
    expect(screen.getByText('KWP-P-00000001', { selector: 'strong' })).toBeInTheDocument()
    expect(screen.getByText('Books')).toBeInTheDocument()
    expect(screen.getByText('2 items in this parcel')).toBeInTheDocument()
    expect(screen.getByRole('img', { name: 'Barcode KWP-P-00000001' })).toBeInTheDocument()
  })

  it('downloads the labels as a PDF without opening a print dialog', async () => {
    URL.createObjectURL = vi.fn(() => 'blob:parcel-labels')
    URL.revokeObjectURL = vi.fn()
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
      expect(this.download).toBe('kwik-parsel-labels-KWP-P-00000001.pdf')
      expect(this.href).toBe('blob:parcel-labels')
    })
    const open = vi.spyOn(window, 'open')
    const print = vi.spyOn(window, 'print')
    render(<ParcelIdentifiers parcels={parcels} />)
    fireEvent.click(screen.getByRole('button', { name: 'Download labels' }))
    await waitFor(() => expect(createParcelLabelsPdf).toHaveBeenCalledWith(parcels))
    await waitFor(() => expect(click).toHaveBeenCalledOnce())
    expect(open).not.toHaveBeenCalled()
    expect(print).not.toHaveBeenCalled()
  })
})
