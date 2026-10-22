import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import RiderNextStop from './RiderNextStop'

const job = { job_id: 'job-1', job_number: 'JOB-7', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Palm Street', delivery_city: 'Lagos' }

describe('rider next stop', () => {
  it('shows only the server-planned stop and preserves the job handoff workflow', () => {
    render(<RiderNextStop jobs={[job]} stop={{ plan_version: 3, job_id: 'job-1', stop_kind: 'dropoff', latitude: 6.4, longitude: 3.4, eta_at: null, estimate_source: 'road' }} />)
    expect(screen.getByRole('heading', { name: 'Deliver parcel' })).toBeInTheDocument()
    expect(screen.getByText(/2 Palm Street, Lagos/)).toBeInTheDocument()
    expect(screen.queryByText(/1 Market Road/)).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open directions' })).toHaveAttribute('href', 'https://www.google.com/maps/search/?api=1&query=6.4,3.4')
    expect(screen.getByText(/pickup or delivery code/)).toBeInTheDocument()
  })

  it('does not suggest a route when no committed server stop exists', () => {
    const { container } = render(<RiderNextStop jobs={[job]} stop={null} />)
    expect(container).toBeEmptyDOMElement()
  })
})
