// Renders branding/logo.svg into the app icon set and site assets.
// Usage: node scripts/render-logo.mjs   (needs `playwright` + a Chromium)
import { chromium } from "playwright";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const svg = readFileSync("branding/logo.svg", "utf8");
const iconset = "App/Sources/Assets.xcassets/AppIcon.appiconset";
mkdirSync(iconset, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH });
const page = await browser.newPage();

async function png(size, out, html) {
  await page.setViewportSize({ width: size.w ?? size, height: size.h ?? size });
  await page.setContent(html ?? `<body style="margin:0;background:transparent">${svg.replace(/width="1024" height="1024"/, `width="${size}" height="${size}"`)}</body>`);
  writeFileSync(out, await page.screenshot({ omitBackground: true }));
}

const images = [];
for (const base of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const px = base * scale;
    const file = `icon_${base}x${base}${scale === 2 ? "@2x" : ""}.png`;
    await png(px, `${iconset}/${file}`);
    images.push({ size: `${base}x${base}`, idiom: "mac", filename: file, scale: `${scale}x` });
  }
}
writeFileSync(`${iconset}/Contents.json`, JSON.stringify({ images, info: { version: 1, author: "xcode" } }, null, 2));
writeFileSync("App/Sources/Assets.xcassets/Contents.json", JSON.stringify({ info: { version: 1, author: "xcode" } }, null, 2));

await png(180, "site/apple-touch-icon.png");
await png(32, "site/favicon-32.png");

// 1200x630 social card
const card = `<body style="margin:0;width:1200px;height:630px;display:flex;align-items:center;gap:48px;padding:0 90px;box-sizing:border-box;background:linear-gradient(135deg,#0b1226,#13294b);font-family:-apple-system,Helvetica,Arial,sans-serif;color:#f5f5f7">
<div style="width:380px;height:380px;flex:none">${svg.replace(/width="1024" height="1024"/, 'width="380" height="380"')}</div>
<div><div style="font-size:84px;font-weight:700;letter-spacing:-1px">DiskSleuth</div>
<div style="font-size:34px;color:#a9b4cc;margin-top:12px;max-width:560px;line-height:1.3">The disk analyzer that tells you the truth on APFS.</div></div></body>`;
await png({ w: 1200, h: 630 }, "site/og.png", card);
await browser.close();
