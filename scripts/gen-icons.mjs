// Rasterizes assets/brand/*.svg into every platform's app-icon set.
// Run from the repo root:  node scripts/gen-icons.mjs
// Idempotent — overwrites outputs deterministically.
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'
import { mkdir, writeFile, unlink } from 'node:fs/promises'
import assert from 'node:assert/strict'
import sharp from 'sharp'
import pngToIco from 'png-to-ico'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')
const BRAND = join(ROOT, 'assets', 'brand')
const SVG = {
  bg: join(BRAND, 'icon-background.svg'),
  fg: join(BRAND, 'icon-foreground.svg'),
  icon: join(BRAND, 'icon.svg'),
}

// Every file we write, with its expected square pixel size — drives the self-check.
const OUT = []

// Rasterize an SVG to a square PNG buffer at `px`. Intrinsic SVG is 1024, so
// this is always a crisp downscale.
async function renderPng(svgPath, px) {
  return sharp(svgPath).resize(px, px, { fit: 'fill' }).png().toBuffer()
}

async function writePng(svgPath, px, outPath) {
  await mkdir(dirname(outPath), { recursive: true })
  const buf = await renderPng(svgPath, px)
  await writeFile(outPath, buf)
  OUT.push({ path: outPath, px })
}

// Composite fg over bg, flattened opaque (iOS requires no alpha).
async function writeOpaqueComposite(px, outPath) {
  await mkdir(dirname(outPath), { recursive: true })
  const bg = await renderPng(SVG.bg, px)
  const fg = await renderPng(SVG.fg, px)
  const buf = await sharp(bg)
    .composite([{ input: fg }])
    .flatten({ background: '#1e1b4b' })
    .png()
    .toBuffer()
  await writeFile(outPath, buf)
  OUT.push({ path: outPath, px })
}

// ── Android adaptive + legacy ────────────────────────────────────────────────
const ANDROID = join(ROOT, 'android', 'res')
// Adaptive layer canvas = 108dp at each density.
const ADAPTIVE_DENSITIES = [
  ['mdpi', 108], ['hdpi', 162], ['xhdpi', 216], ['xxhdpi', 324], ['xxxhdpi', 432],
]
// Legacy flat icon = 48dp (keep the four densities already in the repo).
const LEGACY_DENSITIES = [
  ['mdpi', 48], ['hdpi', 72], ['xhdpi', 96], ['xxhdpi', 144],
]

async function genAndroid() {
  for (const [d, px] of ADAPTIVE_DENSITIES) {
    await writePng(SVG.bg, px, join(ANDROID, `drawable-${d}`, 'ic_launcher_background.png'))
    await writePng(SVG.fg, px, join(ANDROID, `drawable-${d}`, 'ic_launcher_foreground.png'))
  }
  for (const [d, px] of LEGACY_DENSITIES) {
    // Legacy launchers don't mask — use the rounded composite.
    await writePng(SVG.icon, px, join(ANDROID, `drawable-${d}`, 'ic_launcher.png'))
  }
}

// ── iOS app icon set ─────────────────────────────────────────────────────────
const IOS = join(ROOT, 'ios', 'Assets.xcassets', 'AppIcon.appiconset')
// filename -> pixel size. Matches the existing Contents.json exactly.
const IOS_ICONS = [
  ['Icon-App-20x20@1x.png', 20],
  ['Icon-App-20x20@2x.png', 40],
  ['Icon-App-20x20@2x-1.png', 40],
  ['Icon-App-20x20@3x.png', 60],
  ['Icon-App-29x29@1x.png', 29],
  ['Icon-App-29x29@2x.png', 58],
  ['Icon-App-29x29@2x-1.png', 58],
  ['Icon-App-29x29@3x.png', 87],
  ['Icon-App-40x40@1x.png', 40],
  ['Icon-App-40x40@2x.png', 80],
  ['Icon-App-40x40@2x-1.png', 80],
  ['Icon-App-40x40@3x.png', 120],
  ['Icon-App-60x60@2x.png', 120],
  ['Icon-App-60x60@3x.png', 180],
  ['Icon-App-76x76@1x.png', 76],
  ['Icon-App-76x76@2x.png', 152],
  ['Icon-App-83.5x83.5@2x.png', 167],
  ['ItunesArtwork@2x.png', 1024],
]

async function genIos() {
  for (const [name, px] of IOS_ICONS) {
    await writeOpaqueComposite(px, join(IOS, name))
  }
}

// ── Windows .ico + macOS .icns (rounded composite) ───────────────────────────
const WIN_ICO = join(ROOT, 'win', 'app_icon.ico')
const MAC_ICNS = join(ROOT, 'macx', 'app_icon.icns')
const CONTAINERS = []  // {path} — verified by existence, not dimensions

async function genDesktop() {
  // Windows .ico: pack the standard sizes.
  const icoSizes = [16, 32, 48, 256]
  const icoPngs = await Promise.all(icoSizes.map((px) => renderPng(SVG.icon, px)))
  const icoBuf = await pngToIco(icoPngs)
  await writeFile(WIN_ICO, icoBuf)
  CONTAINERS.push({ path: WIN_ICO })

  // macOS .icns: icns-convert auto-generates the full ladder from a 1024 PNG.
  // ponytail: icns-convert 0.0.12 lib has sharp 0.27 conflict; use CLI in subprocess.
  const { execFile } = await import('node:child_process')
  const { promisify } = await import('node:util')
  const execFileAsync = promisify(execFile)
  const tmpPng = join(ROOT, 'scripts', '.icns-tmp.png')
  await writeFile(tmpPng, await renderPng(SVG.icon, 1024))
  await unlink(MAC_ICNS).catch(() => {})  // force self-check to verify a freshly-written file
  await execFileAsync('node', [
    join(ROOT, 'scripts', 'node_modules', '@fiahfy', 'icns-convert', 'dist', 'cli.js'),
    tmpPng,
    MAC_ICNS
  ])
  await unlink(tmpPng)
  CONTAINERS.push({ path: MAC_ICNS })
}

// ── iOS launch-screen wordmark (non-square) ──────────────────────────────────
const WORDMARK_SVG = join(BRAND, 'wordmark.svg')
const IOS_WORDMARK = join(ROOT, 'ios', 'Assets.xcassets', 'Wordmark.imageset')

async function genWordmark() {
  const scales = [['wordmark.png', 1], ['wordmark@2x.png', 2], ['wordmark@3x.png', 3]]
  for (const [name, scale] of scales) {
    await mkdir(IOS_WORDMARK, { recursive: true })
    // Match the 1320x320 (4.125:1) master aspect so letterforms aren't squished.
    // `contain` + transparent pad is self-correcting if the SVG ratio drifts.
    const w = 660 * scale, h = 160 * scale  // display ~660x160 pt
    const buf = await sharp(WORDMARK_SVG)
      .resize(w, h, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png()
      .toBuffer()
    const out = join(IOS_WORDMARK, name)
    await writeFile(out, buf)
    CONTAINERS.push({ path: out })
  }
}

// ── Self-check ───────────────────────────────────────────────────────────────
async function selfCheck() {
  for (const { path, px } of OUT) {
    const meta = await sharp(path).metadata()
    assert.equal(meta.width, px, `width mismatch: ${path} (${meta.width} != ${px})`)
    assert.equal(meta.height, px, `height mismatch: ${path} (${meta.height} != ${px})`)
  }
  const { stat } = await import('node:fs/promises')
  for (const { path } of CONTAINERS) {
    const s = await stat(path)
    assert.ok(s.size > 0, `empty container: ${path}`)
  }
  console.log(`OK: ${OUT.length} PNG outputs + ${CONTAINERS.length} containers verified.`)
}

async function main() {
  await genAndroid()
  await genIos()
  await genDesktop()
  await genWordmark()
  await selfCheck()
  console.log('Done.')
}

main().catch((err) => { console.error(err); process.exit(1) })
