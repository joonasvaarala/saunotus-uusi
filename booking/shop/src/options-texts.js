// Tuotevalinnan tekstit kaupassa ja tilaussivulla (FI/EN). Avaimet samat molemmilla kielillä (node --test tarkistaa).
export const OPT = {
  fi: {
    defaultLabel: 'Valitse hoito', required: 'Pakollinen', optional: 'Valinnainen',
    hint: 'Valinta on pakollinen. Hinta on sama jokaiselle hoidolle.',
    hintChange: 'Hinta ei muutu hoitoa vaihtaessa.',
    what: 'Hoito', notChosen: 'valitsematta',
    pickToContinue: 'Valitse hoito jatkaaksesi.',
    'err.option_required': 'Valitse hoito ennen kuin jatkat.',
    'err.invalid_option': 'Valittua hoitoa ei voi varata. Valitse hoito uudelleen.',
    notChosenNote: 'Hoitoa ei ole vielä valittu. Valitse hoito alta.',
    notChosenConfirm: 'Hoitoa ei ole vielä valittu. Voit valita sen muuttamalla varausta.',
    changeLabel: 'Vaihda hoito', changeTitle: 'Hoito', changeSave: 'Tallenna hoito', changeSaving: 'Tallennetaan…', changeDone: 'Hoito vaihdettu. Saat vahvistuksen sähköpostiin.',
    changeLead: 'Voit vaihtaa hoitoa viimeistään {date}.', changeClosed: 'Hoidon vaihtoaika on päättynyt. Ota yhteyttä puhelimitse.',
    current: 'Nykyinen valinta', sameChoice: 'Valitse jokin toinen hoito vaihtaaksesi.',
  },
  en: {
    defaultLabel: 'Choose your treatment', required: 'Required', optional: 'Optional',
    hint: 'A choice is required. The price is the same for every treatment.',
    hintChange: 'The price does not change when you switch treatment.',
    what: 'Treatment', notChosen: 'not chosen',
    pickToContinue: 'Choose a treatment to continue.',
    'err.option_required': 'Please choose a treatment before you continue.',
    'err.invalid_option': 'The selected treatment cannot be booked. Please choose again.',
    notChosenNote: 'No treatment has been chosen yet. Please choose one below.',
    notChosenConfirm: 'No treatment has been chosen yet. You can choose one by changing your booking.',
    changeLabel: 'Change treatment', changeTitle: 'Treatment', changeSave: 'Save treatment', changeSaving: 'Saving…', changeDone: 'Treatment changed. You will receive a confirmation by email.',
    changeLead: 'You can change the treatment until {date}.', changeClosed: 'The time for changing the treatment has passed. Please call us.',
    current: 'Current choice', sameChoice: 'Choose a different treatment to switch.',
  },
};
export const optText = (lang, key) => (OPT[lang] || OPT.fi)[key];
