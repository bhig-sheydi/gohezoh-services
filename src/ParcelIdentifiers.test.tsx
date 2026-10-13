import {fireEvent,render,screen,waitFor} from '@testing-library/react'
import {describe,expect,it,vi} from 'vitest'
import ParcelIdentifiers from './ParcelIdentifiers'

describe('parcel identification labels',()=>{
  it('renders the stable barcode and makes clear quantity belongs to one parcel row',()=>{
    render(<ParcelIdentifiers parcels={[{tracking_code:'KWP-P-00000001',parcel_number:1,description:'Books',quantity:2}]} />)
    expect(screen.getByText('KWP-P-00000001',{selector:'strong'})).toBeInTheDocument()
    expect(screen.getByText('Books · 2 items in this parcel')).toBeInTheDocument()
    const barcode=screen.getByRole('img',{name:'Barcode KWP-P-00000001'})
    expect(barcode).toBeInTheDocument()
    expect(barcode).toHaveStyle({width:'360px'})
  })

  it('prints the barcode labels without a hosted barcode provider',async()=>{
    const print=vi.spyOn(window,'print').mockImplementation(()=>undefined)
    render(<ParcelIdentifiers parcels={[{tracking_code:'KWP-P-00000001',parcel_number:1,description:'Books',quantity:2}]} />)
    fireEvent.click(screen.getByRole('button',{name:'Print labels'}))
    expect(screen.getByLabelText('Parcel tracking identifiers')).toHaveClass('is-print-target')
    await waitFor(()=>expect(print).toHaveBeenCalledOnce())
    expect(print).toHaveBeenCalledOnce()
    print.mockRestore()
  })
})
