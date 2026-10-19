// Verkkolaskun lähetysrajapinta. Procountor-agentti korvaa dryRunProviderin oikealla asiakkaalla.
// Tämä kerros ei tunne Procountorin osoitetta eikä tunnuksia.

export interface NormalizedInvoice {
  customer: {
    name: string;
    business_id?: string | null;
    vat_id?: string | null;
    einvoice_address?: string | null;
    einvoice_operator?: string | null;
    email?: string | null;
    address?: string | null;
  };
  number?: string | null;
  date: string;
  due_date: string;
  reference?: string | null;
  currency: string;
  lines: { description: string; quantity: number; unit: string; unit_price_net: number; vat_rate: number; unit_price_gross?: number | null; price_basis?: "net" | "gross" | null }[];
  notes?: string | null;
}

export interface ProviderResult {
  ok: boolean;
  mode: "dry_run" | "sent" | "failed";
  provider_ref?: string | null;
  error?: string | null;
}

export interface InvoiceProvider {
  send(invoice: NormalizedInvoice): Promise<ProviderResult>;
}

/** Oletus, kun Procountor-tunnuksia ei ole. Ei verkkokutsua. */
export const dryRunProvider: InvoiceProvider = {
  async send(invoice: NormalizedInvoice): Promise<ProviderResult> {
    if (!invoice?.customer?.name || !Array.isArray(invoice.lines) || invoice.lines.length < 1) {
      return { ok: false, mode: "failed", error: "normalized invoice incomplete" };
    }
    return { ok: true, mode: "dry_run", provider_ref: null, error: "dry_run" };
  },
};

export function providerFor(_mode: string): InvoiceProvider {
  return dryRunProvider;
}
