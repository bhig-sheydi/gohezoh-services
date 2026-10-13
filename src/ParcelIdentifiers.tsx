import {useEffect,useState} from 'react'
import {code39Bars} from './lib/code39'

export type ParcelIdentifier={tracking_code:string;parcel_number:number;description:string;quantity:number}

export function ParcelBarcode({code}:{code:string}) {
  const {bars,width}=code39Bars(code)
  return <svg className="parcel-barcode" role="img" aria-label={`Barcode ${code}`} viewBox={`0 0 ${width} 48`} style={{width:'360px',maxWidth:'100%'}} shapeRendering="crispEdges">
    {bars.map((bar,index)=><rect key={index} x={bar.x} y="1" width={bar.width} height="34" fill="currentColor"/>)}
    <text x={width/2} y="46" textAnchor="middle" fontSize="8" fontFamily="monospace" fill="currentColor">{code}</text>
  </svg>
}

export default function ParcelIdentifiers({parcels}:{parcels:ParcelIdentifier[]}) {
  const [printing,setPrinting]=useState(false)
  useEffect(()=>{const done=()=>setPrinting(false);window.addEventListener('afterprint',done);return()=>window.removeEventListener('afterprint',done)},[])
  if(!parcels.length)return null
  return <section className={`parcel-identifiers${printing?' is-print-target':''}`} aria-label="Parcel tracking identifiers">
    <div className="parcel-identifiers-heading"><h3>Parcel IDs</h3><button className="secondary-button parcel-print-button" onClick={()=>{setPrinting(true);window.setTimeout(()=>window.print(),50)}}>Print labels</button></div>
    {parcels.map((parcel)=><article className="parcel-identifier" key={parcel.tracking_code}>
      <div><strong>{parcel.tracking_code}</strong><p>{parcel.description} · {parcel.quantity} item{parcel.quantity===1?'':'s'} in this parcel</p></div>
      <ParcelBarcode code={parcel.tracking_code}/>
    </article>)}
  </section>
}
