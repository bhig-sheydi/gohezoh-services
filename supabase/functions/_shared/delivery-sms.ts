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
  whatsappAccessToken?: string
  whatsappPhoneNumberId?: string
  whatsappTemplateName?: string
  whatsappTemplateLanguage?: string
  whatsappGraphVersion?: string
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
  if (config.provider === 'whatsapp_cloud') {
    if (!config.whatsappAccessToken || !config.whatsappPhoneNumberId || !config.whatsappTemplateName || !config.whatsappTemplateLanguage || !config.whatsappGraphVersion) {
      throw new Error('WhatsApp delivery messaging is not configured')
    }
    if (!/^v\d+\.\d+$/.test(config.whatsappGraphVersion) || !/^\d+$/.test(config.whatsappPhoneNumberId)) {
      throw new Error('WhatsApp delivery messaging configuration is invalid')
    }
    const response = await fetcher(`https://graph.facebook.com/${config.whatsappGraphVersion}/${config.whatsappPhoneNumberId}/messages`, {
      method: 'POST',
      signal: AbortSignal.timeout(10_000),
      headers: { authorization: `Bearer ${config.whatsappAccessToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', to: termiiPhone(phone), type: 'template',
        template: { name: config.whatsappTemplateName, language: { code: config.whatsappTemplateLanguage }, components: [
          { type: 'body', parameters: [{ type: 'text', text: jobNumber }, { type: 'text', text: code }] },
        ] } }),
    })
    if (!response.ok) throw new Error(`WhatsApp provider rejected the message (${response.status})`)
    const result = await response.json() as { messages?: { id?: string }[] }
    if (!result.messages?.[0]?.id) throw new Error('WhatsApp provider did not accept the message')
    return
  }
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
  throw new Error('Delivery message provider must be configured')
}
