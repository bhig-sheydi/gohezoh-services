import type { SupabaseClient } from '@supabase/supabase-js'
import type { ParcelDestination } from './ParcelPalsPanel'
import UnifiedLocationPicker from './UnifiedLocationPicker'

export default function DeliveryPoint({ supabase, destination }: {
  supabase: SupabaseClient; destination?: ParcelDestination | null
}) {
  return <UnifiedLocationPicker kind="delivery" supabase={supabase} destination={destination} />
}
