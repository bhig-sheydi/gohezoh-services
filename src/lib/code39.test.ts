import {describe,expect,it} from 'vitest'
import {code39Bars} from './code39'

describe('Code 39 parcel labels',()=>{
  it('creates deterministic, scannable bars for generated parcel IDs',()=>{
    const first=code39Bars('KWP-P-00000001')
    expect(first).toEqual(code39Bars('kwp-p-00000001'))
    expect(first.bars.length).toBeGreaterThan(40)
    expect(first.bars.every((bar)=>bar.x>=10&&bar.width>0&&bar.x+bar.width<=first.width)).toBe(true)
  })

  it('rejects values outside the scanner-supported alphabet',()=>{
    expect(()=>code39Bars('KWP-P-01@02')).toThrow('Unsupported Code 39 character: @')
  })
})
