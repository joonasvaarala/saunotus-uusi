// Hyvitysten seurannan RPC-kerros. Näkymä ei tunne parametrien nimiä.
export function createRefundWatchApi({ rpc, fn }) {
  return {
    list(search) {
      return rpc('admin_list_open_refunds', { p_search: search || null });
    },
    retry(refundId) {
      return rpc('admin_retry_provider_refund', { p_refund_id: refundId });
    },
    manual({ refundId, amount, date, providerRef, note }) {
      return rpc('admin_record_manual_refund', {
        p_refund_id: refundId,
        p_amount: amount,
        p_refunded_on: date,
        p_provider_ref: providerRef,
        p_note: note,
      });
    },
    async providerRefund(provider, refundId) {
      const supported = provider === 'montonio' || provider === 'visma_pay' || provider === 'mobilepay';
      if (!fn || !supported) return { result: 'done', mock: true };
      const name = provider === 'visma_pay' ? 'vismapay-refund' : provider === 'mobilepay' ? 'mobilepay-refund' : 'montonio-refund';
      const j = await fn(name, { refund_id: refundId });
      const x = (j?.processed || []).find((p) => +p.refund_id === +refundId);
      return x ? { result: String(x.result || 'error'), detail: x.detail ?? null } : { result: j?.mode === 'off' ? 'off' : 'none' };
    },
  };
}
