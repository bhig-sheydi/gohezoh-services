import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'
import type { ReusableLocation } from './UnifiedLocationPicker'

export default function DeliveryPoint({ supabase, initial }: {
  supabase: SupabaseClient
  initial?: ReusableLocation | null
}) {
  return <UnifiedLocationPicker kind="delivery" supabase={supabase} initial={initial} />
}
