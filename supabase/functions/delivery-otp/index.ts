import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { sendDeliveryCode } from '../_shared/delivery-sms.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return Response.json({ error: 'Method not allowed' }, { status: 405, headers: corsHeaders })
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return Response.json({ error: 'Sign in to request a delivery code' }, { status: 401, headers: corsHeaders })

  const url = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } })
  const { data: { user }, error: userError } = await userClient.auth.getUser()
  if (userError || !user) return Response.json({ error: 'Your session is invalid. Sign in again.' }, { status: 401, headers: corsHeaders })

  let jobId: string
  try {
    const body = await request.json()
    jobId = String(body.jobId ?? '')
    if (!/^[0-9a-f-]{36}$/i.test(jobId)) throw new Error('invalid')
  } catch {
    return Response.json({ error: 'A valid delivery job is required' }, { status: 400, headers: corsHeaders })
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data, error } = await admin.rpc('issue_delivery_otp', { p_job_id: jobId, p_actor_id: user.id })
  if (error) return Response.json({ error: error.message }, { status: 400, headers: corsHeaders })
  try {
    await sendDeliveryCode({
      provider: Deno.env.get('DELIVERY_SMS_PROVIDER') ?? '',
      termiiApiKey: Deno.env.get('TERMII_API_KEY') ?? undefined,
      termiiSenderId: Deno.env.get('TERMII_SENDER_ID') ?? undefined,
      twilioAccountSid: Deno.env.get('TWILIO_ACCOUNT_SID') ?? undefined,
      twilioAuthToken: Deno.env.get('TWILIO_AUTH_TOKEN') ?? undefined,
      twilioFrom: Deno.env.get('TWILIO_FROM') ?? undefined,
    }, data.recipient_phone, data.job_number, data.code)
  } catch (sendError) {
    await admin.rpc('discard_delivery_otp', { p_job_id: jobId })
    console.error('Delivery OTP SMS failed', sendError)
    return Response.json({ error: 'Could not send the delivery code. Check SMS configuration and try again.' }, { status: 502, headers: corsHeaders })
  }
  return Response.json({ sent: true }, { headers: corsHeaders })
})
