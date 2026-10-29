// Koko tila varataan kerralla (yksityisvuoro, jälkilöylyt, mode exclusive).
// public_availability.remaining on silloin max_persons, ei vapaiden paikkojen määrä (booking._sessions).
export function wholeSpaceBooking(slot, product) {
  return slot?.mode === 'exclusive' || product?.sale_kind === 'private_shift' || product?.category === 'private_sauna';
}
