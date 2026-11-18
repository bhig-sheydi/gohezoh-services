import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'

export default function DeliveryPoint({ supabase }: {
  supabase: SupabaseClient
}) {
  return <UnifiedLocationPicker kind="delivery" supabase={supabase} />
}
