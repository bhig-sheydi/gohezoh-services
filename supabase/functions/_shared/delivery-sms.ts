export type SmsConfig = {
  provider: string
  messagingNgPublicKey?: string
  messagingNgSecretKey?: string
  messagingNgSenderId?: string
  termiiApiKey?: string
  termiiSenderId?: string
  twilioAccountSid?: string
  twilioAuthToken?: string
  twilioFrom?: string
}

function termiiPhone(phone: string) {
  const digits = phone.replace(/\D/g, '')
  const international = digits.startsWith('0') ? `234${digits.slice(1)}` : digits
  if (!/^\d{8,15}$/.test(international)) throw new Error('Recipient phone number is invalid')
  return international
}

function twilioPhone(phone: string) {
  const digits = phone.replace(/\D/g, '')
  const international = digits.startsWith('0') ? `+234${digits.slice(1)}` : `+${digits}`
  if (!/^\+[1-9]\d{7,14}$/.test(international)) throw new Error('Recipient phone number is invalid')
  return international
}

export async function sendDeliveryCode(
  config: SmsConfig,
  phone: string,
  jobNumber: string,
  code: string,
  fetcher: typeof fetch = fetch,
) {
  const message = `Kwik-Parsel delivery ${jobNumber}: your delivery code is ${code}. Give it to the rider only when you receive your parcel. Expires in 10 minutes.`
  if (config.provider === 'messaging_ng') {
    if (!config.messagingNgPublicKey || !config.messagingNgSecretKey || !config.messagingNgSenderId) throw new Error('Messaging.ng SMS is not configured')
    const response = await fetcher('https://messaging.ng/api/v1/messages/send', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'X-Public-Key': config.messagingNgPublicKey,
        authorization: `Bearer ${config.messagingNgSecretKey}`,
      },
      body: JSON.stringify({ recipients: [termiiPhone(phone)], body: message, sender_id: config.messagingNgSenderId, channel: 'sms', route: 'transactional' }),
    })
    if (!response.ok) throw new Error(`SMS provider rejected the message (${response.status})`)
    const result = await response.json() as { accepted?: unknown[]; failures?: unknown[]; error?: unknown }
    if (result.error || (Array.isArray(result.failures) && result.failures.length > 0) || !Array.isArray(result.accepted) || result.accepted.length !== 1) {
      throw new Error('SMS provider did not accept the message')
    }
    return
  }
  if (config.provider === 'termii') {
    if (!config.termiiApiKey || !config.termiiSenderId) throw new Error('Termii SMS is not configured')
    const response = await fetcher('https://api.ng.termii.com/api/sms/send', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ api_key: config.termiiApiKey, to: termiiPhone(phone), from: config.termiiSenderId, sms: message, type: 'plain', channel: 'dnd' }),
    })
    if (!response.ok) throw new Error(`SMS provider rejected the message (${response.status})`)
    const result = await response.json() as { code?: string }
    if (result.code !== 'ok') throw new Error('SMS provider did not accept the message')
    return
  }
  if (config.provider === 'twilio') {
    if (!config.twilioAccountSid || !config.twilioAuthToken || !config.twilioFrom) throw new Error('Twilio SMS is not configured')
    const auth = btoa(`${config.twilioAccountSid}:${config.twilioAuthToken}`)
    const body = new URLSearchParams({ To: twilioPhone(phone), From: config.twilioFrom, Body: message })
    const response = await fetcher(`https://api.twilio.com/2010-04-01/Accounts/${config.twilioAccountSid}/Messages.json`, {
      method: 'POST', headers: { authorization: `Basic ${auth}`, 'content-type': 'application/x-www-form-urlencoded' }, body,
    })
    if (!response.ok) throw new Error(`SMS provider rejected the message (${response.status})`)
    return
  }
  throw new Error('SMS provider must be set to messaging_ng, termii or twilio')
}
