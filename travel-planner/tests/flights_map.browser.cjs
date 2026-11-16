/** Fixture-backed browser verification; this script makes no OpenAI requests. */
const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const appUrl = process.env.TRAVEL_APP_URL || 'http://127.0.0.1:8379';
(async () => {
  const browser = await chromium.launch({channel: process.env.TRAVEL_BROWSER_CHANNEL || 'chrome'});
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
  page.setDefaultTimeout(20000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {
    if (message.type() === 'error' && /ErrorBoundary|TypeError|ReferenceError/.test(message.text())) errors.push(message.text());
  });
  await page.route('**/function/assistant_chat', route => route.abort());
  try {
    await page.goto(appUrl);
    await page.locator('.trip-card').filter({hasText: 'Flight map browser regression'}).click();
    const map = page.getByRole('region', {name: 'Trip map', exact: true});
    const outbound = map.getByRole('button', {name: 'Flight route: Outbound', exact: true});
    const returning = map.getByRole('button', {name: 'Flight route: Return', exact: true});
    await outbound.waitFor(); await returning.waitFor();
    assert.equal(await map.locator('.planning-plane, animateMotion').count(), 0, 'Saved map should use static flight routes');
    await map.getByRole('button', {name: 'Explore Tokyo', exact: true}).click();
    let popup = map.getByRole('dialog');
    await popup.getByRole('button', {name: /Tokyo museum/}).click();
    await popup.getByRole('button', {name: 'Show in itinerary', exact: true}).click();
    const museum = page.locator('.travel-item').filter({hasText: 'Tokyo museum'});
    await museum.waitFor();
    await page.waitForFunction(() => Array.from(document.querySelectorAll('.travel-item')).some(
      item => item.textContent.includes('Tokyo museum') && item.getAttribute('data-place-selected') === 'true'));
    assert.equal(await page.getByRole('button', {name: 'Itinerary', exact: true}).getAttribute('data-active'), 'true');
    const outBox = await outbound.boundingBox(), returnBox = await returning.boundingBox();
    assert(Math.abs(outBox.y - returnBox.y) > 24, 'Outbound and return markers must not cover each other');
    await outbound.click();
    popup = map.getByRole('dialog');
    await popup.getByText('Fixture Air · QA101', {exact: true}).waitFor();
    await popup.getByText('DTW → HND', {exact: true}).waitFor();
    assert.equal(await popup.getByRole('link', {name: 'View flight source ↗'}).getAttribute('href'), 'https://example.com/outbound');
    assert.equal(await popup.getByText('USD 1000.00 · web-listed fare', {exact: true}).count(), 1);
    assert.equal(await page.getByLabel('Search flight listings', {exact: true}).isChecked(), true);
    await page.screenshot({path: '/tmp/roam-flights-map-desktop.png', fullPage: true});
    await popup.getByRole('button', {name: 'Close map details'}).click();
    await page.setViewportSize({width: 390, height: 844});
    await map.getByRole('button', {name: 'Flight route: Return', exact: true}).click();
    await map.getByRole('dialog').getByText('Fixture Air · QA102', {exact: true}).waitFor();
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'Mobile page must not overflow horizontally');
    assert.deepEqual(errors, []);
    console.log('Passed: saved map activities and itinerary navigation, static sourced flight routes, source links, fares, and mobile layout.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
