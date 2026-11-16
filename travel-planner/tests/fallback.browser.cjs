/** Local fallback review/save smoke test. Every assistant_chat request is blocked. */
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const appUrl = process.env.TRAVEL_APP_URL || 'http://127.0.0.1:8379';
const apiUrl = process.env.TRAVEL_API_URL || appUrl + '/api/server';
const fixture = JSON.parse(readFileSync('/tmp/roam-fallback-smoke-state.json', 'utf8'));

(async () => {
  const browser = await chromium.launch({channel: process.env.TRAVEL_BROWSER_CHANNEL || 'chrome'});
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
  page.setDefaultTimeout(20000);
  const errors = [];
  let aiCalls = 0;
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/function/assistant_chat', route => { aiCalls++; return route.abort(); });
  async function api(name, data) {
    const response = await page.request.post(apiUrl + '/function/' + name, {data});
    const payload = await response.json();
    assert(response.ok() && payload.ok, JSON.stringify(payload));
    return payload.data.result;
  }
  try {
    assert.deepEqual(await api('list_items', {trip_id: fixture.trip_id}), []);
    await page.goto(appUrl);
    await page.locator('.trip-card').filter({hasText: 'Fallback browser regression'}).click();
    await page.getByRole('button', {name: 'AI planner', exact: true}).click();
    const draft = page.locator('.ai-draft');
    await draft.getByRole('heading', {name: 'Basic trip for New York', exact: true}).waitFor();
    assert((await draft.innerText()).includes('A basic estimated itinerary'));
    await draft.getByRole('heading', {name: 'Estimated outbound flight', exact: true}).waitFor();
    await draft.getByRole('heading', {name: 'Estimated return flight', exact: true}).waitFor();
    assert.equal(await page.getByText('Draft needs another pass', {exact: true}).count(), 0);
    assert.equal(await draft.locator('.ai-price-form').count(), 0);
    assert.equal(await draft.locator('.flight-details').count(), 0, 'Estimates must not render empty web flight listings');
    assert(!(await draft.innerText()).includes('undefined'));
    const expectedCount = await draft.locator('.ai-change').count();
    assert(expectedCount >= 7, 'The fallback should include daily plans, lodging and both flights');
    const save = draft.getByRole('button', {name: 'Save this plan', exact: true});
    assert.equal(await save.isEnabled(), false);
    await draft.locator('.ai-ack input').check();
    assert.equal(await save.isEnabled(), true);
    await page.screenshot({path: '/tmp/roam-fallback-draft.png', fullPage: true});
    const accepted = page.waitForResponse(response => response.url().includes('/function/assistant_review'));
    await save.click();
    const response = await accepted;
    assert(response.ok());
    const payload = await response.json();
    assert.equal(payload.ok, true, JSON.stringify(payload));
    await draft.waitFor({state: 'detached'});
    const items = await api('list_items', {trip_id: fixture.trip_id});
    assert.equal(items.length, expectedCount);
    assert(items.some(item => item.title === 'Estimated outbound flight'));
    assert(items.some(item => item.title === 'Estimated return flight'));
    const state = await api('assistant_state', {trip_id: fixture.trip_id});
    assert.equal(state.drafts[0].status, 'accepted');
    assert.equal(aiCalls, 0, 'Review/save must not invoke the AI');
    assert.deepEqual(errors, []);
    console.log('Passed: offline fallback displays a complete estimated trip and saves after review without AI calls.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
