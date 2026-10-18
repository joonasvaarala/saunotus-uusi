# Kassan pito-malli – asiakasteksti-ehdotukset (FI/EN)
**Tila: EHDOTUS – ei julkaistu. Joonas hyväksyy ennen käyttöä.** Laskuri näytetään muodossa `mm:ss`.

## Ohjeteksti (laskurin yllä, kassa / vahvistussivu / tilaussivu)
- **FI:** **Varaus täytyy maksaa 15 minuutin sisään, muuten se peruuntuu ja paikka vapautuu.**
- **EN:** **The booking must be paid within 15 minutes, otherwise it is cancelled and your spot is released.**
- Aiempi toistava lause "Paikkavaraus on voimassa 15 minuuttia, kunnes varaus maksetaan tai voimassa olevan lahjakortin tiedot syötetään." / "Your spot is held for 15 minutes, until the booking is paid or the details of a valid gift card are entered." on poistettu (Joonas 18.10.2026); paneelissa on vain yllä oleva lihavoitu ohje ja laskuri.

## Laskuri
- **FI:** Paikkaa pidetään vielä **{mm:ss}**
- **EN:** Your spot is held for **{mm:ss}**

## Maksuvalinta
- **FI:** Valitse maksutapa: MobilePay tai lahjakortti. Lahjakortti voi kattaa osan summasta – loppuosan voit maksaa MobilePayllä.
- **EN:** Choose how to pay: MobilePay or gift card. A gift card can cover part of the amount – you can pay the rest with MobilePay.
- Painike FI: **Maksa MobilePayllä ({remaining} €)** / EN: **Pay with MobilePay (€{remaining})**
- Lahjakortti FI: **Käytä lahjakortti** / EN: **Use a gift card**
- Osamaksun jälkeen FI: Lahjakortilla katettu {amount} €. Maksettavaa jäljellä **{remaining} €**. / EN: Gift card applied: €{amount}. Remaining to pay: **€{remaining}**.

## Tilat
- **Maksua käsitellään** FI: Maksua käsitellään – älä sulje sivua. Paikkasi pysyy varattuna, kunnes maksun tulos on selvillä. / EN: Processing your payment – please keep this page open. Your spot stays reserved until the result is known.
- **Vahvistettu** FI: Kiitos! Varauksesi on vahvistettu. Vahvistus ja kuitti on lähetetty sähköpostiisi. / EN: Thank you! Your booking is confirmed. A confirmation and receipt have been sent to your email.
- **Vanhentunut** FI: Paikkavaraus vanheni, koska maksua ei saatu 15 minuutin kuluessa. Mitään ei ole veloitettu. Lahjakortin käytetty osuus on palautettu kortille. Voit tehdä uuden varauksen. / EN: Your spot hold expired because payment was not received within 15 minutes. You have not been charged. Any gift card amount you applied has been returned to the card. You can make a new booking.
- **Alustava (iso ryhmä)** FI: Varauksesi on alustava. Vahvistamme sen sähköpostitse; paikka on varattu {pvm} asti. / EN: Your booking is provisional. We will confirm it by email; your spot is held until {date}.
- **Yritys (lasku)** FI: Varaus on vahvistettu. Lasku lähetetään yrityksen laskutustietoihin. / EN: Your booking is confirmed. The invoice will be sent to your company's billing details.

## Virheet
- `online_payment_unavailable` FI: Verkkomaksu ei ole tilapäisesti käytettävissä, joten varausta ei voi tehdä juuri nyt. Yritä myöhemmin uudelleen tai ota yhteyttä meihin. / EN: Online payment is temporarily unavailable, so we can't take bookings right now. Please try again later or contact us.
- `order_expired` FI: Paikkavaraus on vanhentunut. Tee uusi varaus. / EN: This hold has expired. Please make a new booking.
- `payment_in_progress` FI: Maksusi on kesken. Odota hetki ja yritä uudelleen. / EN: Your payment is in progress. Please wait a moment and try again.
- `too_many_pending` FI: Sinulla on jo useita maksamattomia varauksia. Maksa tai odota, että ne vanhenevat. / EN: You already have several unpaid bookings. Please pay for them or wait for them to expire.
- MobilePay ei veloittanut (`overpay`/`underpay`) FI: Maksua ei veloitettu. Yritä uudelleen. / EN: You were not charged. Please try again.
- `amount_exceeds_unpaid` FI: Summa on suurempi kuin maksettava määrä. / EN: The amount is larger than what remains to pay.

## Sähköpostit (nykytila)
Asiakas saa vahvistusviestin ja kuitit vasta kun koko summa on katettu. Ennen sitä ei lähde mitään. (Yhden yhdistetyn viestin tekeminen vaatii `send-emails`-mallipohjan muutoksen.)


## Lisäys 18.10.2026 (Joonas): maksuohje ja otsikko

* Maksuohje (tilarivin alla, maksuosion yläpuolella, kun `checkout_state = awaiting_payment`): FI "Varaus täytyy maksaa 15 minuutin sisään, muuten se peruuntuu ja paikka vapautuu." / EN "The booking must be paid within 15 minutes, otherwise it is cancelled and your spot is released."
* Otsikko maksamattomalle varaukselle: FI "Varauksesi odottaa maksua" / EN "Your booking is awaiting payment" (ei "Kiitos varauksesta!" ennen maksua).
* Maksu paikan päällä pitotilassa: vain "Testivaihtoehto: maksu paikan päällä" -nappina, kun palvelin tarjoaa sen (booking_57, lippu `pay_later_test_enabled`); tuotannossa lippu on pois päältä, jolloin nappia ei näy. Loppulause poistettu Joonaksen pyynnöstä 18.10.2026.
* Maksamattoman varauksen peruutusnappi (vahvistussivu, pitotila): FI "Peruuta varaus" / EN "Cancel booking" (aiemmin "Vapauta paikka (peru maksamaton pito)" / "Release spot (cancel unpaid hold)"). Vahvistusdialogi FI "Perutaanko varaus?" / EN "Cancel this booking?"; onnistuminen FI "Varaus peruttu." / EN "Booking cancelled."; virhe (vahvistettu varaus) FI "Vahvistetun varauksen peruutus: ota yhteyttä sähköpostilla." / EN "To cancel a confirmed booking, please contact us by email." Sanasto yhtenäistetty "peruuta varaus" -muotoon (Joonas 18.10.2026).
