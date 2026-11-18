import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'
import type { ReusableLocation } from './UnifiedLocationPicker'

export default function PickupLocation({ supabase, initial }: {
  supabase: SupabaseClient
  initial?: ReusableLocation | null
}) {
  return <UnifiedLocationPicker kind="pickup" supabase={supabase} initial={initial} />
}
