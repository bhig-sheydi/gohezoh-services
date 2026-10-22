import { useState } from 'react'
import { code39Bars } from './lib/code39'
import { createParcelLabelsPdf } from './lib/parcel-label-pdf'

export type ParcelIdentifier = { tracking_code: string; parcel_number: number; description: string; quantity: number }

export function ParcelBarcode({ code }: { code: string }) {
  const { bars, width } = code39Bars(code)
  return <svg className="parcel-barcode" role="img" aria-label={`Barcode ${code}`} viewBox={`0 0 ${width} 48`} shapeRendering="crispEdges">
    {bars.map((bar, index) => <rect key={index} x={bar.x} y="1" width={bar.width} height="34" fill="currentColor" />)}
    <text x={width / 2} y="46" textAnchor="middle" fontSize="8" fontFamily="monospace" fill="currentColor">{code}</text>
  </svg>
}

export default function ParcelIdentifiers({ parcels }: { parcels: ParcelIdentifier[] }) {
  const [downloading, setDownloading] = useState(false)
  const [downloadError, setDownloadError] = useState('')
  async function downloadLabels() {
    if (downloading) return
    setDownloading(true)
    setDownloadError('')
    try {
      const bytes = await createParcelLabelsPdf(parcels)
      const blob = new Blob([Uint8Array.from(bytes).buffer], { type: 'application/pdf' })
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = `kwik-parsel-labels-${parcels[0].tracking_code}.pdf`
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
    } catch (error) {
      setDownloadError(error instanceof Error ? error.message : 'Could not create the parcel labels PDF.')
    } finally {
      setDownloading(false)
    }
  }
  if (!parcels.length) return null
  return <section className="parcel-identifiers" aria-label="Parcel tracking identifiers">
    <div className="parcel-identifiers-heading">
      <div className="parcel-identifiers-brand"><img src="/favicon.svg" alt="" /><h3>Parcel IDs</h3></div>
      <button className="secondary-button parcel-print-button" type="button" disabled={downloading} onClick={() => void downloadLabels()}>{downloading ? 'Creating PDF…' : 'Download labels'}</button>
    </div>
    {downloadError && <p className="parcel-label-error" role="alert">{downloadError}</p>}
    <div className="parcel-identifier-list">{parcels.map((parcel) => <article className="parcel-identifier" key={parcel.tracking_code}>
      <div className="parcel-identifier-copy">
        <span className="parcel-identifier-kicker">PARCEL {parcel.parcel_number}</span>
        <strong>{parcel.tracking_code}</strong>
        <p>{parcel.description}</p>
        <small>{parcel.quantity} item{parcel.quantity === 1 ? '' : 's'} in this parcel</small>
      </div>
      <div className="parcel-identifier-barcode"><ParcelBarcode code={parcel.tracking_code} /></div>
    </article>)}</div>
  </section>
}
