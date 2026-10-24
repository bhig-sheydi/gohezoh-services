import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'

export default function PickupLocation({ supabase, userId, onCitySelected }: {
  supabase: SupabaseClient; userId: string; onCitySelected: (city: string) => void
}) {
  return <UnifiedLocationPicker kind="pickup" supabase={supabase} userId={userId} onCitySelected={onCitySelected} />
}
