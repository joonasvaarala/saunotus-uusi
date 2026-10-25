// Maksulinkkisivun tekstit (FI/EN): /maksa/?p=<link_token> ja /en/pay/?p=<link_token>. Avaimet ui.paylink.*. Ei yhteystietoja eikä osoitteita (puhelin tulee S.phone-arvosta).
export const PLT = {
  fi: {
    title: 'Maksulinkki',
    lead: 'Maksa tilauksesi kortilla tai verkkopankissa. Siirryt Visma Payn sivulle, jossa näet maksettavan summan ja tilauksen viitteen ennen maksua. Maksun jälkeen palaat tilaukseesi.',
    btn: 'Siirry maksamaan',
    busy: 'Avataan Visma Payta…',
    redirecting: 'Siirrytään Visma Payhin…',
    amount: 'Maksettava: {amount}',
    dryRun: 'Testitila: maksua ei veloiteta.',
    contact: 'Kysyttävää? Soita meille:',
    'err.invalid': 'Maksulinkki on virheellinen. Tarkista, että avasit koko linkin sähköpostista.',
    'err.not_found': 'Maksulinkkiä ei löytynyt. Tarkista linkki tai ota yhteyttä.',
    'err.expired': 'Maksulinkki on vanhentunut tai korvattu uudella. Pyydä meiltä uusi linkki.',
    'err.stale': 'Tilauksen maksettava summa on muuttunut. Pyydä meiltä uusi maksulinkki.',
    'err.paid': 'Tämä maksu on jo maksettu. Kiitos.',
    'err.other': 'Maksu on jo aloitettu toisella maksutavalla.',
    'err.not_payable': 'Tätä tilausta ei voi maksaa verkossa.',
    'err.off': 'Verkkomaksu ei ole juuri nyt käytössä.',
    'err.busy': 'Maksun avaus on jo käynnissä. Odota hetki ja yritä uudelleen.',
    'err.rate': 'Liian monta yritystä. Yritä hetken kuluttua uudelleen.',
    'err.provider': 'Visma Pay ei vastannut. Yritä hetken kuluttua uudelleen.',
    'err.network': 'Yhteys ei onnistunut. Tarkista verkkoyhteys ja yritä uudelleen.',
    'err.generic': 'Maksun aloitus epäonnistui. Yritä uudelleen tai ota yhteyttä.',
  },
  en: {
    title: 'Payment link',
    lead: 'Pay for your order by card or online bank. You go to the Visma Pay page, where you see the amount and the order reference before paying. After payment you return to your order.',
    btn: 'Go to payment',
    busy: 'Opening Visma Pay…',
    redirecting: 'Taking you to Visma Pay…',
    amount: 'Amount due: {amount}',
    dryRun: 'Test mode: no payment is charged.',
    contact: 'Questions? Call us:',
    'err.invalid': 'The payment link is invalid. Check that you opened the whole link from the email.',
    'err.not_found': 'The payment link was not found. Check the link or contact us.',
    'err.expired': 'The payment link has expired or has been replaced by a new one. Ask us for a new link.',
    'err.stale': 'The amount due on the order has changed. Ask us for a new payment link.',
    'err.paid': 'This payment has already been paid. Thank you.',
    'err.other': 'The payment has already been started with another payment method.',
    'err.not_payable': 'This order cannot be paid online.',
    'err.off': 'Online payment is not available right now.',
    'err.busy': 'A payment is already being opened. Wait a moment and try again.',
    'err.rate': 'Too many attempts. Please try again in a moment.',
    'err.provider': 'Visma Pay did not respond. Please try again in a moment.',
    'err.network': 'The connection failed. Check your network and try again.',
    'err.generic': 'The payment could not be started. Try again or contact us.',
  },
};

export const plt = (L, k, vars) => {
  const s = (PLT[L] && PLT[L][k]) || PLT.fi[k] || k;
  if (!vars) return s;
  return s.replace(/\{(\w+)\}/g, (_, n) => (vars[n] != null ? String(vars[n]) : `{${n}}`));
};
