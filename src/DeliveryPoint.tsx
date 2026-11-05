import type { SupabaseClient } from '@supabase/supabase-js'
import type { ParcelDestination } from './ParcelPalsPanel'
import UnifiedLocationPicker from './UnifiedLocationPicker'

export default function DeliveryPoint({ supabase, destination, userId, onCitySelected }: {
  supabase: SupabaseClient; destination?: ParcelDestination | null; userId?: string; onCitySelected?: (city: string) => void
}) {
  return <UnifiedLocationPicker kind="delivery" supabase={supabase} destination={destination} userId={userId} onCitySelected={onCitySelected} />
}
