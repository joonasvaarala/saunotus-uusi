// Normalisoidun laskun muunnos Procountor POST /invoices -rungoksi.
// Kentät tulevat OpenAPI-skeemasta Invoice / CounterParty / InvoiceRow / PaymentInfo / ExtraInfo / EInvoiceAddress (18.10.2026).
// Toinen agentti rakentaa booking.invoices-taulut ja kutsuu buildProcountorInvoice + deliverInvoice.

export type InvoiceAddress = { street?: string; zip?: string; city?: string; country?: string };
export type InvoiceLine = {
  description: string;
  quantity: number;
  unit?: string;
  unit_price_net: number;
  unit_price_gross?: number | null;
  price_basis?: "net" | "gross" | null;
  vat_rate: number;
};
export type InvoiceCustomer = {
  name: string;
  business_id?: string;
  vat_id?: string;
  einvoice_address?: string;
  einvoice_operator?: string;
  email?: string;
  address?: InvoiceAddress;
};
export type NormalizedInvoice = {
  customer: InvoiceCustomer;
  number?: string;
  date: string;
  due_date: string;
  reference?: string;
  currency: string;
  lines: InvoiceLine[];
  notes?: string;
};

export type BuildOptions = { vatStatus?: string | number | null; bankAccount?: string | null };

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const Y_TUNNUS = /^\d{7}-\d$/;
const UNIT_MAP: Record<string, string> = {
  kpl: "PIECE", pcs: "PIECE", piece: "PIECE",
  hour: "HOUR", hours: "HOUR", tunti: "HOUR", tuntia: "HOUR", h: "HOUR",
  min: "MINUTE", minute: "MINUTE", minuutti: "MINUTE", minuuttia: "MINUTE",
  henkilo: "PERSON", henkilö: "PERSON", person: "PERSON",
  paiva: "DAY", päivä: "DAY", day: "DAY",
};
const KNOWN_UNITS = new Set(["PIECE", "HOUR", "MINUTE", "PERSON", "DAY", "NO_UNIT"]);
const COUNTRY_ALIAS: Record<string, string> = {
  fi: "FINLAND", fin: "FINLAND", finland: "FINLAND", suomi: "FINLAND",
};

export type BuiltInvoice = {
  ok: boolean;
  errors: string[];
  blockers: string[];
  channel: "EMAIL" | "ELECTRONIC_INVOICE" | null;
  request: Record<string, unknown> | null;
};

const blank = (v: unknown) => String(v ?? "").trim();
const finite = (v: unknown) => typeof v === "number" && Number.isFinite(v);

function mapUnit(raw: string | undefined, errors: string[]): string {
  if (raw == null || blank(raw) === "") return "PIECE";
  const key = blank(raw).toLowerCase();
  if (UNIT_MAP[key]) return UNIT_MAP[key];
  const upper = blank(raw).toUpperCase();
  if (KNOWN_UNITS.has(upper)) return upper;
  errors.push("unknown_unit");
  return upper;
}

function mapCountry(raw: string | undefined): string | null {
  if (raw == null || blank(raw) === "") return "FINLAND";
  const alias = COUNTRY_ALIAS[blank(raw).toLowerCase()];
  if (alias) return alias;
  const token = blank(raw).toUpperCase();
  if (/^[A-Z][A-Z0-9_]+$/.test(token)) return token;
  return null;
}

export function buildProcountorInvoice(invoice: NormalizedInvoice, opts: BuildOptions = {}): BuiltInvoice {
  const errors: string[] = [];
  const blockers: string[] = [];
  const customer = invoice?.customer ?? ({} as InvoiceCustomer);
  const name = blank(customer.name);
  if (!name) errors.push("customer_name");
  const date = blank(invoice?.date);
  const due = blank(invoice?.due_date);
  if (!DATE_RE.test(date)) errors.push("date");
  if (!DATE_RE.test(due)) errors.push("due_date");
  if (DATE_RE.test(date) && DATE_RE.test(due) && due < date) errors.push("due_before_date");
  if (blank(invoice?.currency).toUpperCase() !== "EUR") errors.push("currency");

  const einvoiceAddress = blank(customer.einvoice_address);
  const einvoiceOperator = blank(customer.einvoice_operator);
  const email = blank(customer.email);
  let channel: BuiltInvoice["channel"] = null;
  if (einvoiceAddress || einvoiceOperator) {
    if (!einvoiceAddress || !einvoiceOperator) errors.push("einvoice_incomplete");
    else channel = "ELECTRONIC_INVOICE";
  } else if (email) channel = "EMAIL";
  else errors.push("channel_missing");

  const addr = customer.address ?? {};
  const street = blank(addr.street);
  const zip = blank(addr.zip);
  const city = blank(addr.city);
  const country = mapCountry(addr.country);
  if (addr.country && !country) errors.push("unknown_country");
  if (channel === "ELECTRONIC_INVOICE" && (!street || !zip || !city)) errors.push("address");

  const vatStatus = blank(opts.vatStatus);
  if (!/^[0-9]{1,4}$/.test(vatStatus)) blockers.push("vat_status");
  const bank = blank(opts.bankAccount).replace(/\s+/g, "");
  if (!bank) blockers.push("bank_account");

  const lines = Array.isArray(invoice?.lines) ? invoice.lines : [];
  if (!lines.length) errors.push("lines");
  const grossUnit = (line: InvoiceLine): number | null =>
    line?.price_basis === "gross" && finite(line.unit_price_gross) ? Number(line.unit_price_gross) : null;
  // Rivikohtaista verollisuuslippua ei ole. Koko lasku lähetetään verollisena vain, kun jokainen rivi on gross-perusteella.
  const pricesIncludeVat = lines.length > 0 && lines.every((line) => grossUnit(line) != null);
  const rows = lines.map((line) => {
    if (!blank(line?.description)) errors.push("line_description");
    if (!finite(line?.quantity) || line.quantity === 0) errors.push("line_quantity");
    const price = pricesIncludeVat ? grossUnit(line) : line?.unit_price_net;
    if (!finite(price)) errors.push("line_price");
    if (!finite(line?.vat_rate) || line.vat_rate < 0 || line.vat_rate > 100) errors.push("line_vat");
    return {
      product: blank(line?.description).slice(0, 255),
      quantity: line?.quantity,
      unit: mapUnit(line?.unit, errors),
      unitPrice: price,
      discountPercent: 0,
      vatPercent: line?.vat_rate,
    };
  });

  if (errors.length) return { ok: false, errors: [...new Set(errors)], blockers: [...new Set(blockers)], channel, request: null };

  const address = {
    name: name.slice(0, 80),
    ...(street ? { street: street.slice(0, 80) } : {}),
    ...(zip ? { zip: zip.slice(0, 20) } : {}),
    ...(city ? { city: city.slice(0, 40) } : {}),
    country: country ?? "FINLAND",
  };
  const counterParty: Record<string, unknown> = { counterPartyAddress: address };
  if (blank(customer.business_id)) counterParty.identifier = blank(customer.business_id);
  if (blank(customer.vat_id)) counterParty.taxCode = blank(customer.vat_id);
  if (email) counterParty.email = email;
  if (channel === "ELECTRONIC_INVOICE") {
    counterParty.einvoiceAddress = { operator: einvoiceOperator, address: einvoiceAddress };
  }

  const request: Record<string, unknown> = {
    type: "SALES_INVOICE",
    status: "UNFINISHED",
    date,
    language: "FINNISH",
    discountPercent: 0,
    invoiceChannel: channel,
    vatStatus: Number(vatStatus),
    counterParty,
    billingAddress: channel === "ELECTRONIC_INVOICE" ? { ...address } : {},
    extraInfo: { accountingByRow: false, unitPricesIncludeVat: pricesIncludeVat },
    invoiceRows: rows,
    paymentInfo: {
      paymentMethod: "BANK_TRANSFER",
      currency: "EUR",
      currencyRate: 1,
      dueDate: due,
      bankReferenceCode: blank(invoice.reference),
      bankAccount: { accountNumber: bank },
    },
  };
  const number = blank(invoice.number);
  if (number) request.originalInvoiceNumber = number.slice(0, 40);
  const notes = blank(invoice.notes);
  if (notes) request.additionalInformation = notes.slice(0, 10000);
  return { ok: true, errors: [], blockers: [...new Set(blockers)], channel, request };
}

export type PartnerWarning = "partner_ambiguous" | "partner_create_failed" | "partner_address_incomplete";

/** Hakee asiakkaan Y-tunnuksella. 0 osumaa luo CUSTOMER-kumppanin. Usea osuma ei linkitä. */
export async function linkCustomer(client: { call: (op: string, method: string, path: string, opts?: { query?: Record<string, string>; body?: unknown; headers?: Record<string, string> }) => Promise<unknown> }, invoice: NormalizedInvoice, channel: "EMAIL" | "ELECTRONIC_INVOICE"): Promise<{ partnerId: number | null; warnings: PartnerWarning[] }> {
  const businessId = blank(invoice.customer?.business_id);
  if (!businessId) return { partnerId: null, warnings: [] };
  const warnings: PartnerWarning[] = [];
  let results: { id?: number }[] = [];
  try {
    const found = await client.call("partner_search", "GET", "/businesspartners", {
      query: { type: "CUSTOMER" },
      headers: { identifier: businessId },
    }) as { results?: { id?: number }[] };
    results = Array.isArray(found?.results) ? found.results : [];
  } catch {
    warnings.push("partner_create_failed");
    return { partnerId: null, warnings };
  }
  if (results.length > 1) return { partnerId: null, warnings: ["partner_ambiguous"] };
  if (results.length === 1 && results[0]?.id) return { partnerId: results[0].id, warnings };
  const addr = invoice.customer.address ?? {};
  const street = blank(addr.street), zip = blank(addr.zip), city = blank(addr.city);
  if (!street || !zip || !city) return { partnerId: null, warnings: ["partner_address_incomplete"] };
  const country = mapCountry(addr.country) ?? "FINLAND";
  const body: Record<string, unknown> = {
    name: blank(invoice.customer.name).slice(0, 80),
    type: "CUSTOMER",
    paymentInfo: { paymentMethod: "BANK_TRANSFER" },
    address: { street: street.slice(0, 80), zip: zip.slice(0, 20), city: city.slice(0, 40), country },
    invoicingInfo: {
      identifier: businessId,
      ...(Y_TUNNUS.test(businessId) ? { identifierType: "FI" } : {}),
      ...(blank(invoice.customer.email) ? { email: blank(invoice.customer.email) } : {}),
      ...(channel === "ELECTRONIC_INVOICE" ? { einvoiceAddress: blank(invoice.customer.einvoice_address), einvoiceOperator: blank(invoice.customer.einvoice_operator) } : {}),
      invoiceChannel: channel,
    },
  };
  try {
    const created = await client.call("partner_create", "POST", "/businesspartners", { body }) as { id?: number };
    if (!created?.id) { warnings.push("partner_create_failed"); return { partnerId: null, warnings }; }
    return { partnerId: created.id, warnings };
  } catch {
    return { partnerId: null, warnings: ["partner_create_failed"] };
  }
}
