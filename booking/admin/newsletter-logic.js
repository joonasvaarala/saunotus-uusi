export const NEWSLETTER_SEGMENTS = ['all','training','treatment','event','session_only','gift_buyers','christmas_gift_buyers'];
export function newsletterPatch(form) {
  return Object.fromEntries(['subject_fi','subject_en','body_fi','body_en','segment','language'].map(k=>[k,form.elements[k].value]));
}
export function newsletterCanSend(preview, draft, dirty=false, now=Date.now()) {
  return !!preview?.preview_token && preview.recipient_count>0 && preview.recipient_count<=5000 && draft.state!=='sent' && !dirty && preview.version===draft.version && now-preview.at<30*60*1000;
}
