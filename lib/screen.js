/**
 * Screen capture through macOS `screencapture`.
 *
 * `screencapture` inherits the Host application's Screen Recording grant, which
 * is why this package does not link CoreGraphics capture itself. The pixel
 * dimensions of a Retina capture are `points * scale`, so by default the image
 * is downsampled back to point size: one image pixel then equals one point and
 * the model can pass screenshot coordinates straight to `computer_mouse`
 * without arithmetic.
 */
import { execFile } from 'node:child_process'
import { mkdir, readFile, readdir, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { run } from './helper.js'

const CAPTURE_DIR = path.join(tmpdir(), 'dsh-computer-use')
const SCREENCAPTURE = '/usr/sbin/screencapture'
const MAX_AGE_MS = 20 * 60 * 1000

function execFileAsync(file, args, options) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 60_000, maxBuffer: 8 * 1024 * 1024, ...options },
      (error, stdout, stderr) => resolve({ error, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') }))
  })
}

/** Read PNG width/height straight from the IHDR chunk (no image library). */
export function pngSize(buffer) {
  if (buffer.length < 24) return null
  if (buffer.readUInt32BE(0) !== 0x89504e47 || buffer.readUInt32BE(4) !== 0x0d0a1a0a) return null
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) }
}

async function prune() {
  const entries = await readdir(CAPTURE_DIR).catch(() => [])
  const now = Date.now()
  await Promise.all(entries.map(async (name) => {
    const target = path.join(CAPTURE_DIR, name)
    try {
      const info = await stat(target)
      if (now - info.mtimeMs > MAX_AGE_MS) await rm(target, { force: true })
    } catch {}
  }))
}

function captureFailure() {
  const error = new Error('截图失败：screencapture 没有生成文件。')
  error.code = 'capture-failed'
  error.hint = '通常是「屏幕录制」权限没有给 DeepSeek Harness；打开 系统设置 → 隐私与安全性 → 屏幕录制 勾选后重启 Harness。'
  return error
}

/**
 * Capture the screen, a region, or a window.
 *
 * @param {{ window?: number, region?: { x: number, y: number, width: number, height: number }, display?: number, resolution?: 'points'|'pixels' }} options
 */
export async function captureScreen(options = {}) {
  const resolution = options.resolution === 'pixels' ? 'pixels' : 'points'
  const displayIndex = Number.isFinite(options.display) ? Math.max(1, Math.trunc(options.display)) : 1

  await mkdir(CAPTURE_DIR, { recursive: true })
  await prune()

  const info = await run('info')
  const screen = (info.screens || [])[displayIndex - 1] ?? (info.screens || [])[0] ?? { x: 0, y: 0, width: 0, height: 0, scale: 1 }
  const scale = Number(screen.scale) > 0 ? Number(screen.scale) : 1

  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const suffix = Math.random().toString(36).slice(2, 8)
  const file = path.join(CAPTURE_DIR, `shot-${stamp}-${suffix}.png`)

  const args = ['-x', '-o', '-t', 'png']
  let origin = { x: Number(screen.x) || 0, y: Number(screen.y) || 0 }
  let capture

  if (Number.isFinite(options.window)) {
    const listed = await run('windows')
    const target = (listed.windows || []).find((entry) => entry.id === Number(options.window))
    if (!target) {
      const error = new Error(`找不到窗口 id=${options.window}，先用 computer_windows 列一次当前窗口。`)
      error.code = 'window-not-found'
      throw error
    }
    args.push('-l', String(target.id))
    origin = { x: target.x, y: target.y }
    capture = { kind: 'window', window: target.id, app: target.app, title: target.title }
  } else if (options.region && typeof options.region === 'object') {
    const region = options.region
    const x = Math.round(Number(region.x) || 0)
    const y = Math.round(Number(region.y) || 0)
    const width = Math.max(1, Math.round(Number(region.width) || 0))
    const height = Math.max(1, Math.round(Number(region.height) || 0))
    args.push('-R', `${x},${y},${width},${height}`)
    origin = { x, y }
    capture = { kind: 'region', x, y, width, height }
  } else {
    args.push('-D', String(displayIndex))
    capture = { kind: 'display', display: displayIndex }
  }

  args.push(file)
  const shot = await execFileAsync(SCREENCAPTURE, args)
  if (shot.error) throw captureFailure()

  let bytes = await readFile(file).catch(() => null)
  if (!bytes) throw captureFailure()
  const captured = pngSize(bytes)
  if (!captured) {
    const error = new Error('截图文件不是有效的 PNG。')
    error.code = 'bad-capture'
    throw error
  }

  let finalFile = file
  let width = captured.width
  let height = captured.height
  let pointsPerPixel = 1 / scale

  if (resolution === 'points' && scale !== 1) {
    const targetWidth = Math.max(1, Math.round(captured.width / scale))
    const targetHeight = Math.max(1, Math.round(captured.height / scale))
    const resized = file.replace(/\.png$/, '-pt.png')
    const resample = await execFileAsync('/usr/bin/sips', ['-z', String(targetHeight), String(targetWidth), '--out', resized, file])
    if (!resample.error) {
      const resizedBytes = await readFile(resized).catch(() => null)
      if (resizedBytes) {
        await rm(file, { force: true }).catch(() => {})
        bytes = resizedBytes
        finalFile = resized
        pointsPerPixel = 1
        const actual = pngSize(resizedBytes)
        if (actual) {
          width = actual.width
          height = actual.height
        } else {
          width = targetWidth
          height = targetHeight
        }
      }
    }
  }

  return {
    ok: true,
    file: finalFile,
    width,
    height,
    capturedWidth: captured.width,
    capturedHeight: captured.height,
    scale,
    pointsPerPixel,
    origin,
    capture,
    display: { index: displayIndex, width: screen.width, height: screen.height, x: screen.x, y: screen.y },
    cursor: info.cursor,
    frontmost: info.frontmost,
    capturedAt: new Date().toISOString(),
  }
}

export { CAPTURE_DIR }
