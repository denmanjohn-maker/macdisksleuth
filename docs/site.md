# Project site

`site/` is published to https://denmanjohn-maker.github.io/macdisksleuth/ by the **Pages** workflow on every push to `main` that touches `site/`.

**One-time setup:** repo Settings → Pages → Source: **GitHub Actions**.

## Logo

The master is `branding/logo.svg`. After editing it, regenerate the app icon set and site assets (needs `playwright` and a Chromium):

```sh
node scripts/render-logo.mjs   # set CHROMIUM_PATH if Playwright can't find a browser
cp branding/logo.svg site/logo.svg && cp branding/logo.svg site/favicon.svg
```
