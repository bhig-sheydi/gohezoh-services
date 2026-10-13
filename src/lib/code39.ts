const patterns: Record<string, string> = {
  '0':'nnnwwnwnn','1':'wnnwnnnnw','2':'nnwwnnnnw','3':'wnwwnnnnn','4':'nnnwwnnnw','5':'wnnwwnnnn','6':'nnwwwnnnn','7':'nnnwnnwnw','8':'wnnwnnwnn','9':'nnwwnnwnn',
  A:'wnnnnwnnw',B:'nnwnnwnnw',C:'wnwnnwnnn',D:'nnnnwwnnw',E:'wnnnwwnnn',F:'nnwnwwnnn',G:'nnnnnwwnw',H:'wnnnnwwnn',I:'nnwnnwwnn',J:'nnnnwwwnn',
  K:'wnnnnnnww',L:'nnwnnnnww',M:'wnwnnnnwn',N:'nnnnwnnww',O:'wnnnwnnwn',P:'nnwnwnnwn',Q:'nnnnnnwww',R:'wnnnnnwwn',S:'nnwnnnwwn',T:'nnnnwnwwn',
  U:'wwnnnnnnw',V:'nwwnnnnnw',W:'wwwnnnnnn',X:'nwnnwnnnw',Y:'wwnnwnnnn',Z:'nwwnwnnnn',
  '-':'nwnnnnwnw','.':'wwnnnnwnn',' ':'nwwnnnwnn','$':'nwnwnwnnn','/':'nwnwnnnwn','+':'nwnnnwnwn','%':'nnnwnwnwn','*':'nwnnwnwnn',
}

export type BarcodeBars = { bars: Array<{x:number;width:number}>; width:number }

/** Builds Code 39 bars for the uppercase parcel IDs; no network or barcode service is needed. */
export function code39Bars(value:string):BarcodeBars {
  const encoded=`*${value.toUpperCase()}*`
  let x=10
  const bars:Array<{x:number;width:number}>=[]
  for(const character of encoded){
    const pattern=patterns[character]
    if(!pattern) throw new Error(`Unsupported Code 39 character: ${character}`)
    for(let index=0;index<pattern.length;index++){
      const width=pattern[index]==='w'?3:1
      if(index%2===0)bars.push({x,width})
      x+=width
    }
    x+=1
  }
  return {bars,width:x+9}
}
