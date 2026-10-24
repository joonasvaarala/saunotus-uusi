// Paketti 11 / booking_144: anonyymi esimerkkiaineisto Kävijät-välilehdelle, vain ?mock=1. Ei verkkoa eikä selaintallennusta. Summat vain esimerkkejä (eivät hintoja).
export function analyticsMock(from, to) {
  const a=new Date(from+'T12:00:00Z'), b=new Date(to+'T12:00:00Z');
  const days=Math.max(1,Math.min(367,Math.floor((b-a)/864e5)+1));
  const series=Array.from({length:days},(_,i)=>{
    const d=new Date(a);d.setUTCDate(d.getUTCDate()+i);
    return {date:d.toISOString().slice(0,10),visitors:65+(i*7)%42,product_views:38+(i*5)%22,checkouts:13+(i*3)%11,purchases:6+(i*2)%6};
  });
  const sum = k => series.reduce((x,v)=>x+v[k],0);
  const visitors=sum('visitors'),buyers=sum('purchases');
  return {from,to,funnel:{visitors,product_viewers:sum('product_views'),checkout_starters:sum('checkouts'),buyers,
    paid_orders:buyers,amount_gross:buyers*42.5,conversion_pct:+(100*buyers/visitors).toFixed(2),page_view_events:visitors,product_view_events:sum('product_views'),checkout_events:sum('checkouts'),purchase_events:buyers},
    sources:[['google_search',35],['google_maps',19],['social',15],['campaign',10],['direct',17],['referral',4]].map(([source_category,pct])=>{const visits=Math.round(visitors*pct/100),purchases=Math.round(buyers*pct/100);return{source_category,visits,checkouts:Math.round(visits*.21),purchases,conversion_pct:+(100*purchases/Math.max(1,visits)).toFixed(2),top_utm_campaign:source_category==='campaign'?'lokakuu':null,top_referrer_domain:source_category==='referral'?'visitfinland.com':null}}),
    top_products:[['Yleinen savusaunavuoro',4,.45],['Perinnesaunotus kahdelle',11,.2],['Turvesauna',8,.14],['Lahjakortti',43,.21]].map(([name,product_id,f],i)=>{const views=Math.round(sum('product_views')*(.38-i*.07)),checkouts=Math.round(views*f),purchases=Math.round(checkouts*.65);return{product_id,name,views,checkouts,purchases,conversion_pct:+(100*purchases/Math.max(1,views)).toFixed(2)}}),
    devices_and_locales:{devices:[{device_type:'mobile',visits:Math.round(visitors*.71),purchases:Math.round(buyers*.68)},{device_type:'desktop',visits:Math.round(visitors*.25),purchases:Math.round(buyers*.29)},{device_type:'tablet',visits:Math.round(visitors*.04),purchases:Math.round(buyers*.03)}],locales:[{locale:'fi',visits:Math.round(visitors*.89),purchases:Math.round(buyers*.92)},{locale:'en',visits:Math.round(visitors*.11),purchases:Math.round(buyers*.08)}]},daily_series:series};
}
