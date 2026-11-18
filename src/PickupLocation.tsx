import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'

export default function PickupLocation({ supabase }: {
  supabase: SupabaseClient
}) {
  return <UnifiedLocationPicker kind="pickup" supabase={supabase} />
}
