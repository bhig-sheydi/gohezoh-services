import { code39Bars } from './code39'

export type LabelParcel = { tracking_code: string; parcel_number: number; description: string; quantity: number }

const PAGE_WIDTH_MM = 80
const PAGE_HEIGHT_MM = 60
const CANVAS_WIDTH = 945
const CANVAS_HEIGHT = 709

function wrappedLines(context: CanvasRenderingContext2D, text: string, maxWidth: number) {
  const words = text.trim().split(/\s+/)
  const lines: string[] = []
  let line = ''
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word
    if (context.measureText(candidate).width <= maxWidth || !line) line = candidate
    else { lines.push(line); line = word }
  }
  if (line) lines.push(line)
  return lines
}

function drawLabel(parcel: LabelParcel, logo: HTMLImageElement | null) {
  const canvas = document.createElement('canvas')
  canvas.width = CANVAS_WIDTH
  canvas.height = CANVAS_HEIGHT
  const context = canvas.getContext('2d')
  if (!context) throw new Error('This browser cannot create parcel labels. Please try another browser.')
  context.fillStyle = '#fff'
  context.fillRect(0, 0, CANVAS_WIDTH, CANVAS_HEIGHT)
  context.fillStyle = '#173b34'
  if (logo) context.drawImage(logo, 36, 25, 82, 82)
  context.font = 'bold 37px Arial, sans-serif'
  context.fillText('KWIK-PARSEL', logo ? 135 : 36, 78)
  context.fillStyle = '#b9c9bb'
  context.fillRect(36, 128, CANVAS_WIDTH - 72, 2)
  context.fillStyle = '#315747'
  context.font = 'bold 25px Arial, sans-serif'
  context.fillText(`PARCEL ${parcel.parcel_number}`, 36, 177)
  context.fillStyle = '#142d23'
  context.font = 'bold 41px Arial, sans-serif'
  context.fillText(parcel.tracking_code, 36, 232)

  let descriptionFontSize = 31
  let lines: string[] = []
  do {
    context.font = `${descriptionFontSize}px Arial, sans-serif`
    lines = wrappedLines(context, parcel.description, CANVAS_WIDTH - 72)
    descriptionFontSize -= 2
  } while (lines.length > 3 && descriptionFontSize >= 19)
  context.fillStyle = '#2e4336'
  lines.slice(0, 3).forEach((line, index) => context.fillText(line, 36, 285 + index * 33))
  context.fillStyle = '#536956'
  context.font = '26px Arial, sans-serif'
  context.fillText(`${parcel.quantity} item${parcel.quantity === 1 ? '' : 's'} in this parcel`, 36, 395)

  const barcode = code39Bars(parcel.tracking_code)
  const scale = (CANVAS_WIDTH - 110) / barcode.width
  context.fillStyle = '#000'
  for (const bar of barcode.bars) context.fillRect(55 + bar.x * scale, 426, bar.width * scale, 190)
  context.font = '26px monospace'
  context.textAlign = 'center'
  context.fillText(parcel.tracking_code, CANVAS_WIDTH / 2, 659)
  return canvas.toDataURL('image/jpeg', 0.94)
}

async function loadLogo() {
  const logo = new Image()
  return new Promise<HTMLImageElement | null>((resolve) => {
    logo.onload = () => resolve(logo)
    logo.onerror = () => resolve(null)
    logo.src = '/favicon.svg'
  })
}

export async function createParcelLabelsPdf(parcels: LabelParcel[]) {
  const { PDFDocument } = await import('pdf-lib')
  const pdf = await PDFDocument.create()
  const logo = await loadLogo()
  const width = PAGE_WIDTH_MM * 72 / 25.4
  const height = PAGE_HEIGHT_MM * 72 / 25.4
  for (const parcel of parcels) {
    const image = await pdf.embedJpg(drawLabel(parcel, logo))
    const page = pdf.addPage([width, height])
    page.drawImage(image, { x: 0, y: 0, width, height })
  }
  return pdf.save()
}
