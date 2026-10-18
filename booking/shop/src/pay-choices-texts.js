// Maksuvalinnan tekstit (FI/EN) varausvahvistussivulle ja kassalle: "Maksa MobilePaylla" + "Maksa lahjakortilla". Avaimet samat molemmilla kielillä (node --test tarkistaa). Ei emojeita.
// MobilePay-painikkeen ja lahjakorttilomakkeen omat tekstit tulevat mobilepay-texts.js:stä ja gift-texts.js:stä (sama logiikka kuin tilaussivulla).
export const PT = {
  fi: {
    title: 'Maksa varaus', amountDue: 'Maksettavaa jäljellä: {amount}',
    leadConfirmed: 'Voit maksaa nyt verkossa MobilePaylla tai lahjakortilla. Maksu on mahdollista myös paikan päällä.',
    leadPending: 'Valitse maksutapa.',
    giftBtn: 'Maksa lahjakortilla', giftBtnClose: 'Piilota lahjakortin maksu',
    unpaidOnline: 'Maksamatta', partlyPaid: 'Osittain maksettu',
    noticeTitle: 'Maksu kirjattu',
    checkoutOnline: 'Maksu varauksen jälkeen: MobilePaylla tai lahjakortilla vahvistussivulla.', checkoutOnlineSite: 'Maksu varauksen jälkeen: MobilePaylla tai lahjakortilla vahvistussivulla, tai paikan päällä.',
    checkoutHoldOnline: 'Valitse maksutapa (MobilePay tai lahjakortti) varauksen jälkeen vahvistussivulla.',
    testWarn: 'Testisivusto: MobilePay-maksu menee MobilePayn testipalvelimelle. Älä käytä oikeaa maksukorttia tai oikeaa rahaa.',
  },
  en: {
    title: 'Pay for your booking', amountDue: 'Amount left to pay: {amount}',
    leadConfirmed: 'You can pay online now with MobilePay or a gift card. Paying on site is also possible.',
    leadPending: 'Choose a payment method.',
    giftBtn: 'Pay with a gift card', giftBtnClose: 'Hide gift card payment',
    unpaidOnline: 'Unpaid', partlyPaid: 'Partly paid',
    noticeTitle: 'Payment recorded',
    checkoutOnline: 'Payment after booking: with MobilePay or a gift card on the confirmation page.', checkoutOnlineSite: 'Payment after booking: with MobilePay or a gift card on the confirmation page, or on site.',
    checkoutHoldOnline: 'Choose how to pay (MobilePay or gift card) on the confirmation page after booking.',
    testWarn: 'Test site: MobilePay payments go to MobilePay’s test server. Do not use a real payment card or real money.',
  },
};
export const pt = (lang, key, vars) => String((PT[lang] || PT.fi)[key] ?? PT.fi[key] ?? key).replace(/\{(\w+)\}/g, (_, k) => (vars && vars[k] != null ? vars[k] : `{${k}}`));
