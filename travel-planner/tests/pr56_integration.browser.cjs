const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const appUrl=process.env.TRAVEL_APP_URL || 'http://127.0.0.1:8379';
const apiUrl=process.env.TRAVEL_API_URL || appUrl+'/api/server';
(async()=>{
 const browser=await chromium.launch({channel:'chrome'}),page=await browser.newPage({viewport:{width:1600,height:1000}});page.setDefaultTimeout(20000);
 const errors=[],trips=[];let ai=0;
 page.on('pageerror',e=>errors.push(e.message));
 const api=async(name,data)=>{const r=await page.request.post(apiUrl+'/function/'+name,{data});const p=await r.json();assert(p.ok,JSON.stringify(p));return p.data.result;};
 await page.route('**/function/assistant_chat',r=>{ai++;return r.abort();});
 await page.route('**/function/resolve_trip_map_places',r=>r.fulfill({json:{ok:true,data:{result:{located:0,remaining:0}}}}));
 await page.route('**/function/search_map_places',r=>r.fulfill({json:{ok:true,data:{result:[{label:'Central Park, New York',lat:40.7829,lon:-73.9654}]}}}));
 try{
 const trip=await api('save_trip',{title:'PR56 integration '+Date.now(),destination:'New York',departure_location:'DTW',return_location:'DTW',start_date:'2027-01-01',end_date:'2027-01-03',budget:'5000'});trips.push(trip.id);
 const item=await api('save_item',{trip_id:trip.id,title:'Central Park walk',category:'activity',date:'2027-01-02',time:'10:00',location:'Central Park'});
 await page.goto(appUrl);await page.locator('.trip-card').filter({hasText:trip.title}).click();
 const map=page.getByRole('region',{name:'Trip map',exact:true});await map.locator('.leaflet-container').waitFor();
 await page.waitForFunction(()=>document.querySelectorAll('.map-route-line').length===2);
 await page.locator('.map-stop-card').filter({hasText:item.title}).click();
 const popup=map.getByRole('dialog');await popup.getByRole('button',{name:'Search location',exact:true}).click();await popup.getByRole('button',{name:/Use this location/}).click();
 await popup.getByText('Location saved on your map.',{exact:true}).waitFor();
 assert.equal((await api('load_trip_map',{trip_id:trip.id})).pins[item.id].lat,40.7829);
 await page.reload();await page.locator('.map-stop-card').filter({hasText:item.title}).waitFor();
 await page.getByRole('navigation',{name:'Choose a city'}).getByRole('button',{name:'New York',exact:true}).click();
 await map.getByRole('button',{name:'Explore stop Central Park walk',exact:true}).waitFor();
 await page.locator('.map-filters select').nth(1).selectOption('food');assert.equal(await page.locator('.map-stop-card').count(),0);
 await page.locator('.map-filters select').nth(1).selectOption('activity');assert.equal(await page.locator('.map-stop-card').count(),1);
 await page.getByRole('button',{name:'All cities',exact:true}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.map-route-line').length===2);
 await map.screenshot({path:'/tmp/pr56-map-desktop.png'});
 await page.setViewportSize({width:390,height:844});await page.waitForTimeout(300);
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
 await map.screenshot({path:'/tmp/pr56-map-mobile.png'});
 for(const direction of ['Departure','Return']) {
   const route=map.locator('.map-route-line[data-direction="'+direction+'"]');
   assert(await route.evaluate(p=>{const box=p.getBBox(), svg=p.ownerSVGElement;return box.x>=0 && box.y>=0 && box.x+box.width<=svg.clientWidth && box.y+box.height<=svg.clientHeight;}),'Mobile routes must fit the map');
 }
 assert.equal(await map.locator('.map-track-credit').count(),0,'Do not imply a recorded track exists for an estimate');
 assert.equal(ai,0);assert.deepEqual(errors,[]);
 console.log('Passed: street map, persistent location confirmation, city drill-down, category filters, estimated round-trip lines, mobile layout, and no assistant calls.');
 }finally{for(const id of trips)await api('delete_trip',{trip_id:id});await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
