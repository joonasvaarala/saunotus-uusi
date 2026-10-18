// Kassan paikanpito (§17): KAIKKI asiakkaalle näytettävät pitotekstit FI + EN yhdessä paikassa. Tekstit ovat VÄLIAIKAISIA (lopullinen Joonaksen hyväksyntään; docs/KASSA_pito_asiakasteksti_fi.md).
// Avaimet samat molemmilla kielillä (node --test tarkistaa); muuttujat {minutes} {time} {amount} {date} {methods}. Ei emojeita. Pidon pituus tulee palvelimelta (hold_minutes), oletus 15.
export const HT = {
  fi: {
    'title.awaiting': 'Maksa varaus vahvistaaksesi', 'title.processing': 'Maksua käsitellään', 'title.preliminary': 'Alustava varaus', 'title.expired': 'Paikkavaraus vanheni',
    'status.awaiting': 'Varaus odottaa maksua', 'status.processing': 'Maksua käsitellään', 'status.preliminary': 'Alustava varaus', 'status.expired': 'Paikkavaraus vanheni',
    lead: 'Paikkavaraus on voimassa {minutes} minuuttia, kunnes varaus maksetaan tai voimassa olevan lahjakortin tiedot syötetään.',
    confirmRule: 'Varaus vahvistuu, kun koko summa on maksettu.',
    mustPay: 'Varaus täytyy maksaa {minutes} minuutin sisään, muuten se peruuntuu ja paikka vapautuu. Varaus vahvistuu, kun koko summa on maksettu.',
    'h2.awaiting': 'Varauksesi odottaa maksua',
    'testOnSite.title': 'Testivaihtoehto: maksu paikan päällä', 'testOnSite.text': 'Näkyy vain testiympäristössä, ei tuotannossa. Paikka vapautuu silti, ellei varausta makseta verkossa {minutes} minuutin sisään.',
    timerLabel: 'Paikkaa pidetään vielä', timerChecking: 'Tarkistamme paikkavarauksen tilaa…',
    'announce.minutes': 'Paikkaa pidetään vielä {time}.', spoken_min1: '1 minuutti', spoken_min: '{n} minuuttia', spoken_sec: '{n} sekuntia',
    choose: 'Valitse maksutapa: MobilePay tai lahjakortti. Lahjakortti voi kattaa osan summasta – loppuosan voit maksaa MobilePaylla.',
    remaining: 'Maksettavaa jäljellä: {amount}',
    processing: 'Maksua käsitellään – älä sulje sivua. Paikkasi pysyy varattuna, kunnes maksun tulos on selvillä.',
    processingLong: 'Tarkistamme maksua yhä. Saat vahvistuksen sähköpostiin, kun maksu on valmis. Voit myös tarkistaa tilan uudelleen.', recheck: 'Tarkista uudelleen',
    confirmed: 'Kiitos! Varauksesi on vahvistettu. Vahvistus ja kuitti on lähetetty sähköpostiisi.', thanks: 'Kiitos',
    preliminary: 'Varauksesi on alustava. Vahvistamme sen sähköpostitse; paikka on varattu {date} asti.', preliminaryNoDate: 'Varauksesi on alustava. Vahvistamme sen sähköpostitse.',
    expired: 'Paikkavaraus vanheni, koska maksua ei saatu {minutes} minuutin kuluessa. Mitään ei ole veloitettu. Voit tehdä uuden varauksen.',
    expiredGift: 'Lahjakortin käytetty osuus on palautettu kortille.',
    newBooking: 'Tee uusi varaus', pickNew: 'Valitse uusi aika',
    // kassa
    'checkout.button': 'Jatka maksamaan', 'checkout.creating': 'Varataan paikkaa…',
    'checkout.lead': 'Paikka varataan {minutes} minuutiksi, kun jatkat maksamaan. Valitset maksutavan seuraavassa vaiheessa.',
    'checkout.methods': 'Maksutavat: {methods}.', 'checkout.review': 'Tarkista tiedot. Paikka varataan {minutes} minuutiksi, kun painat "Jatka maksamaan". Varaus vahvistuu vasta maksun jälkeen.',
    'method.mobilepay': 'MobilePay', 'method.gift_card': 'lahjakortti', methodsAnd: ' ja ',
    // virheet (§17.3)
    'err.online_payment_unavailable': 'Verkkomaksu ei ole tilapäisesti käytettävissä, joten varausta ei voi tehdä juuri nyt. Yritä myöhemmin uudelleen tai ota yhteyttä meihin.',
    'err.order_expired': 'Paikkavaraus on vanhentunut. Tee uusi varaus.',
    'err.order_preliminary': 'Alustavaa varausta ei makseta ennen kuin olemme vahvistaneet sen. Vahvistamme sen sähköpostitse.',
    'err.payment_in_progress': 'Maksusi on kesken. Odota hetki ja yritä uudelleen.',
    'err.too_many_pending': 'Sinulla on jo useita maksamattomia varauksia. Maksa ne tai odota, että ne vanhenevat.',
    'err.not_charged': 'Maksua ei veloitettu. Yritä uudelleen.',
  },
  en: {
    'title.awaiting': 'Pay to confirm your booking', 'title.processing': 'Processing your payment', 'title.preliminary': 'Provisional booking', 'title.expired': 'Your spot hold expired',
    'status.awaiting': 'Booking awaiting payment', 'status.processing': 'Processing your payment', 'status.preliminary': 'Provisional booking', 'status.expired': 'Your spot hold expired',
    lead: 'Your spot is held for {minutes} minutes, until the booking is paid or the details of a valid gift card are entered.',
    confirmRule: 'The booking is confirmed once the full amount is covered.',
    mustPay: 'The booking must be paid within {minutes} minutes, otherwise it is cancelled and your spot is released. The booking is confirmed once the full amount is paid.',
    'h2.awaiting': 'Your booking is awaiting payment',
    'testOnSite.title': 'Test option: pay on site', 'testOnSite.text': 'Shown in the test environment only, not in production. Your spot is still released unless the booking is paid online within {minutes} minutes.',
    timerLabel: 'Your spot is held for', timerChecking: 'Checking the status of your hold…',
    'announce.minutes': 'Your spot is held for {time} more.', spoken_min1: '1 minute', spoken_min: '{n} minutes', spoken_sec: '{n} seconds',
    choose: 'Choose how to pay: MobilePay or gift card. A gift card can cover part of the amount – you can pay the rest with MobilePay.',
    remaining: 'Amount left to pay: {amount}',
    processing: 'Processing your payment – please keep this page open. Your spot stays reserved until the result is known.',
    processingLong: 'We are still checking your payment. You will receive a confirmation by email when it is done. You can also check the status again.', recheck: 'Check again',
    confirmed: 'Thank you! Your booking is confirmed. A confirmation and receipt have been sent to your email.', thanks: 'Thank you',
    preliminary: 'Your booking is provisional. We will confirm it by email; your spot is held until {date}.', preliminaryNoDate: 'Your booking is provisional. We will confirm it by email.',
    expired: 'Your spot hold expired because payment was not received within {minutes} minutes. You have not been charged. You can make a new booking.',
    expiredGift: 'Any gift card amount you applied has been returned to the card.',
    newBooking: 'Make a new booking', pickNew: 'Choose a new time',
    'checkout.button': 'Continue to payment', 'checkout.creating': 'Reserving your spot…',
    'checkout.lead': 'Your spot is held for {minutes} minutes when you continue to payment. You choose how to pay in the next step.',
    'checkout.methods': 'Payment methods: {methods}.', 'checkout.review': 'Please check the details. Your spot is held for {minutes} minutes when you press "Continue to payment". The booking is confirmed only after payment.',
    'method.mobilepay': 'MobilePay', 'method.gift_card': 'gift card', methodsAnd: ' and ',
    'err.online_payment_unavailable': 'Online payment is temporarily unavailable, so we can’t take bookings right now. Please try again later or contact us.',
    'err.order_expired': 'This hold has expired. Please make a new booking.',
    'err.order_preliminary': 'A provisional booking cannot be paid before we have confirmed it. We will confirm it by email.',
    'err.payment_in_progress': 'Your payment is in progress. Please wait a moment and try again.',
    'err.too_many_pending': 'You already have several unpaid bookings. Please pay for them or wait for them to expire.',
    'err.not_charged': 'You were not charged. Please try again.',
  },
};
const fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v && v[k] != null ? v[k] : `{${k}}`));
export const ht = (lang, key, vars) => fill((HT[lang] || HT.fi)[key] ?? HT.fi[key] ?? key, vars);
export const HOLD_ERROR_CODES = ['online_payment_unavailable', 'order_expired', 'order_preliminary', 'payment_in_progress', 'too_many_pending'];
// Virhekoodi → selkeä teksti (undefined jos koodi ei ole pitovirhe: kutsuja käyttää omaa käsittelyään)
export const holdError = (lang, code) => (HT.fi[`err.${code}`] ? ht(lang, `err.${code}`) : undefined);
// Luettelo "MobilePay ja lahjakortti" palvelimen methods-listasta (code → teksti)
export const methodList = (lang, codes) => { const names = codes.map((c) => ht(lang, `method.${c}`)).filter((x) => !x.startsWith('method.')); return names.length > 1 ? names.slice(0, -1).join(', ') + ht(lang, 'methodsAnd') + names[names.length - 1] : names[0] || ''; };
