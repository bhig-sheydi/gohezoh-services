import { useCallback, useEffect, useState } from 'react'
import type { getSupabaseClient } from './lib/supabase'

type Supabase = ReturnType<typeof getSupabaseClient>
type ExceptionNotice = { id: string; job_id: string | null; title: string; body: string; created_at: string; read_at: string | null; payload: Record<string, unknown> }

export default function InternalExceptionInbox({ supabase, userId, onError }: { supabase: Supabase; userId: string; onError: (message: string) => void }) {
  const [notices, setNotices] = useState<ExceptionNotice[]>([])
  const [loading, setLoading] = useState(true)
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('notifications')
      .select('id, job_id, title, body, created_at, read_at, payload')
      .eq('user_id', userId).eq('event_type', 'job_exception_escalated')
      .order('created_at', { ascending: false }).limit(20)
    if (error) onError(error.message)
    else setNotices((data ?? []) as ExceptionNotice[])
    setLoading(false)
  }, [onError, supabase, userId])

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer) }, [load])

  async function markReviewed(notice: ExceptionNotice) {
    if (notice.read_at) return
    const { data, error } = await supabase.rpc('mark_customer_notification_read', { p_notification_id: notice.id })
    if (error) onError(error.message)
    else setNotices((current) => current.map((item) => item.id === notice.id ? { ...item, read_at: String(data) } : item))
  }

  return <section className="history-panel notification-panel" aria-label="Delivery exception alerts">
    <div className="history-heading"><div><p className="eyebrow">OPERATIONS ALERTS</p><h2>Delivery exceptions</h2></div><button className="secondary-button notification-refresh" onClick={() => { setLoading(true); void load() }} disabled={loading}>Refresh</button></div>
    {loading ? <div className="loading">Loading exception alerts...</div> : notices.length === 0 ? <p className="notification-empty">No delivery exceptions need review.</p> : <div className="notification-list">{notices.map((notice) => <article className={`notification-item ${notice.read_at ? 'notification-read' : 'notification-unread'}`} key={notice.id}>
      <div className="notification-copy"><div className="notification-title-row"><strong>{notice.title}</strong>{!notice.read_at && <span className="notification-new">New</span>}</div><p>{notice.body}</p><small>{new Date(notice.created_at).toLocaleString('en-NG')}</small></div>
      {!notice.read_at && <button className="secondary-button notification-read-button" onClick={() => void markReviewed(notice)}>Mark reviewed</button>}
    </article>)}</div>}
  </section>
}
