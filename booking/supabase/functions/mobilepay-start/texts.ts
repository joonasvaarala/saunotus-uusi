// mobilepay-start: asiakkaalle näkyvät virheilmoitukset (maksulinkin GET-virhesivu ja JSON-vastauksen message), sopimus §18.
// Avaimet ui.mobilepay.start_error_<tapaus>: repon oletukset = varateksti; tuotannossa luetaan tietokannasta (_shared/site_texts.ts). Kieli: FI (maksulinkki ei kanna kielitietoa).
import type { TextTable } from "../_shared/site_texts.ts";

export const MOBILEPAY_START_TEXTS: TextTable = {
  "ui.mobilepay.start_error_default": { fi: "Maksun aloitus epäonnistui", en: "Starting the payment failed" },
  "ui.mobilepay.start_error_invalid_param": { fi: "Virheellinen pyyntö", en: "Invalid request" },
  "ui.mobilepay.start_error_off": { fi: "MobilePay-maksu ei ole käytössä", en: "MobilePay payment is not available" },
  "ui.mobilepay.start_error_unavailable": { fi: "MobilePay-maksu ei ole käytettävissä juuri nyt", en: "MobilePay payment is not available right now" },
  "ui.mobilepay.start_error_provider": { fi: "MobilePay-maksun aloitus epäonnistui", en: "Starting the MobilePay payment failed" },
  "ui.mobilepay.start_error_provider_retry": { fi: "MobilePay-maksun aloitus epäonnistui, yritä hetken kuluttua uudelleen", en: "Starting the MobilePay payment failed, please try again in a moment" },
};
