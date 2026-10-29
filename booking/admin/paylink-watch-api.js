// Seurattavat maksut: RPC-nimet pysyvät tässä, näkymä ei tunne p_-parametreja.
export function createPaylinkWatchApi({ rpc }) {
  return {
    list(a = {}) {
      return rpc('admin_list_payment_link_watch', {
        p_search: a.search || null,
        p_status: a.status || null,
        p_limit: a.limit ?? 50,
        p_offset: a.offset ?? 0,
      });
    },
    remindNow(paymentId) {
      return rpc('admin_payment_link_remind_now', { p_payment_id: paymentId });
    },
    pause(paymentId) {
      return rpc('admin_payment_link_pause_reminders', { p_payment_id: paymentId });
    },
    markHandled(paymentId, method, note) {
      return rpc('admin_payment_link_mark_handled', { p_payment_id: paymentId, p_method: method, p_note: note || null });
    },
  };
}
