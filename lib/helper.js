/**
 * Compile-once bridge to the native helpers.
 *
 * Two Swift binaries are built from the sources shipped in this package and
 * cached under `~/.dsh/computer-use/bin/`, rebuilt only when a source hash
 * changes:
 *
 * - `dsh-cu` (native/ComputerUse.swift) — the fat helper: screen reading, AX,
 *   windows, OCR. One process per call is fine here.
 * - `dsh-cu-input` (native/CUInput.swift) — CoreGraphics-only input helper.
 *   Latency-critical commands (move/click/key/…) go through a persistent
 *   unix-socket daemon (`serve` mode) for sub-millisecond round trips, with a
 *   one-shot fallback when the daemon cannot start.
 *
 * Compilation needs the Xcode command line tools (`swiftc`); when they are
 * missing every tool reports an actionable error instead of failing silently.
 */
import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { constants as fsConstants } from 'node:fs'
import { access, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import path from 'node:path'
import net from 'node:net'
import { fileURLToPath } from 'node:url'

export const PACKAGE_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
export const SUPPORTED = process.platform === 'darwin'

const CACHE_DIR = path.join(homedir(), '.dsh', 'computer-use')
const BIN_DIR = path.join(CACHE_DIR, 'bin')
const COMPILE_TIMEOUT_MS = 240_000
const RUN_TIMEOUT_MS = 20_000

const TARGETS = {
  main: {
    source: path.join(PACKAGE_ROOT, 'native', 'ComputerUse.swift'),
    binary: path.join(BIN_DIR, 'dsh-cu'),
    stamp: path.join(BIN_DIR, 'dsh-cu.sha1'),
  },
  input: {
    source: path.join(PACKAGE_ROOT, 'native', 'CUInput.swift'),
    binary: path.join(BIN_DIR, 'dsh-cu-input'),
    stamp: path.join(BIN_DIR, 'dsh-cu-input.sha1'),
  },
}

/** Commands served by the low-latency input helper (socket daemon). */
const INPUT_COMMANDS = new Set(['move', 'click', 'hold', 'drag', 'scroll', 'key', 'type', 'sequence', 'cursor'])
/** Input commands the fat helper also understands (one-shot fallback). */
const LEGACY_INPUT_COMMANDS = new Set(['move', 'click', 'drag', 'scroll', 'key', 'type'])

const state = {
  build: undefined,
  version: undefined,
}
const inputState = {
  conn: undefined,
}

function execFileAsync(file, args, options) {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout: 0, maxBuffer: 8 * 1024 * 1024, ...options }, (error, stdout, stderr) => {
      resolve({ error, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') })
    })
  })
}

async function exists(target, mode) {
  try {
    await access(target, mode ?? fsConstants.F_OK)
    return true
  } catch {
    return false
  }
}

async function resolveCompiler() {
  // Invoking the toolchain binary by absolute path skips the SDKROOT the Xcode
  // shims provide and fails with "unable to load standard library"; both the
  // `xcrun swiftc` wrapper and the `/usr/bin/swiftc` shim work.
  for (const candidate of [{ file: 'xcrun', prefix: ['swiftc'] }, { file: 'swiftc', prefix: [] }]) {
    const probe = await execFileAsync(candidate.file, [...candidate.prefix, '--version'], { timeout: 20_000 })
    if (!probe.error) return candidate
  }
  return null
}

async function buildOne(target) {
  await mkdir(BIN_DIR, { recursive: true })
  const source = await readFile(target.source, 'utf8')
  const hash = createHash('sha256').update(source).digest('hex')

  if (await exists(target.binary, fsConstants.X_OK)) {
    const stamp = await readFile(target.stamp, 'utf8').catch(() => '')
    if (stamp.trim() === hash) return { ok: true, path: target.binary, compiled: false, hash }
  }

  const compiler = await resolveCompiler()
  if (!compiler) {
    return {
      ok: false,
      code: 'missing-compiler',
      error: '找不到 Swift 编译器（swiftc）。',
      hint: '安装 Xcode Command Line Tools：`xcode-select --install`，装好后重新调用本工具即可自动编译。',
    }
  }

  const staged = `${target.binary}.new-${process.pid}`
  const started = Date.now()
  const build = await execFileAsync(compiler.file,
    [...compiler.prefix, '-O', '-module-cache-path', path.join(CACHE_DIR, 'module-cache'), '-o', staged, target.source],
    { timeout: COMPILE_TIMEOUT_MS })

  if (build.error) {
    await rm(staged, { force: true }).catch(() => {})
    if (build.error.killed) {
      return { ok: false, code: 'compile-timeout', error: '编译原生助手超时（>240s）。', hint: build.stderr.slice(-800) }
    }
    return {
      ok: false,
      code: 'compile-failed',
      error: '编译原生助手失败。',
      hint: (build.stderr || build.error.message || '').slice(-1200),
    }
  }

  await rename(staged, target.binary)
  await writeFile(target.stamp, `${hash}\n`, 'utf8')
  return { ok: true, path: target.binary, compiled: true, hash, ms: Date.now() - started }
}

async function buildAll() {
  const [main, input] = await Promise.all([buildOne(TARGETS.main), buildOne(TARGETS.input)])
  if (!main.ok) return main
  if (!input.ok) {
    // The fat helper still works for everything except the new primitives.
    return { ...main, input: { ok: false, code: input.code, error: input.error, hint: input.hint } }
  }
  return { ...main, input: { ok: true, path: input.path, compiled: input.compiled, hash: input.hash } }
}

/** Resolve (and if necessary compile) both helpers. Concurrent callers share one build. */
export async function ensureHelper() {
  if (!SUPPORTED) {
    return {
      ok: false,
      code: 'unsupported-platform',
      error: `当前系统是 ${process.platform}，这套原生鼠标键盘助手只实现了 macOS。`,
      hint: '在 macOS 上使用；Windows/Linux 需要各自的输入注入实现。',
    }
  }
  // Re-validate periodically so an externally recompiled binary (new sha256
  // stamp → new hash → new socket path) is picked up without a plugin reload.
  if (!state.build || Date.now() - (state.buildAt ?? 0) > 30_000) {
    state.buildAt = Date.now()
    state.build = buildAll().catch((error) => ({
      ok: false,
      code: 'build-crashed',
      error: error?.message ? String(error.message) : String(error),
    }))
    state.build.then((result) => {
      if (!result.ok) state.build = undefined
    })
  }
  return state.build
}

async function ensureInputHelper() {
  const helper = await ensureHelper()
  if (!helper.ok) return helper
  if (!helper.input?.ok) {
    return {
      ok: false,
      code: helper.input?.code ?? 'input-helper-missing',
      error: helper.input?.error ?? '低延迟输入助手不可用。',
      hint: helper.input?.hint,
    }
  }
  return { ok: true, path: helper.input.path, hash: helper.input.hash }
}

// MARK: - Socket transport (low-latency input)

function inputSocketPath(hash) {
  // Hash-scoped: a rebuilt binary never talks to a stale daemon.
  return path.join(BIN_DIR, `cu-input-${hash.slice(0, 8)}.sock`)
}

function connectOnce(sockPath) {
  return new Promise((resolve) => {
    const sock = net.connect(sockPath)
    const timer = setTimeout(() => {
      sock.destroy()
      resolve(null)
    }, 200)
    sock.once('connect', () => {
      clearTimeout(timer)
      resolve(sock)
    })
    sock.once('error', () => {
      clearTimeout(timer)
      resolve(null)
    })
  })
}

/** net.connect makes a single attempt; a just-spawned daemon may not have
 *  bound the socket yet, so poll until the deadline. */
async function tryConnect(sockPath, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const sock = await connectOnce(sockPath)
    if (sock) return sock
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  return null
}

async function getConnection() {
  const build = await ensureInputHelper()
  if (!build.ok) {
    const error = new Error(build.error)
    error.code = build.code
    error.hint = build.hint
    throw error
  }
  if (inputState.conn && !inputState.conn.destroyed) return inputState.conn
  const sockPath = inputSocketPath(build.hash)
  let conn = await tryConnect(sockPath, 250)
  if (!conn) {
    const child = spawn(build.path, ['serve', JSON.stringify({ socket: sockPath, idleSec: 900 })], {
      detached: true,
      stdio: 'ignore',
    })
    child.unref()
    conn = await tryConnect(sockPath, 3_000)
  }
  if (!conn) {
    const error = new Error('低延迟输入助手 daemon 启动失败。')
    error.code = 'daemon-start'
    throw error
  }
  conn.setNoDelay(true)
  conn.cuBuffer = ''
  conn.cuPending = []
  conn.cuQueue = Promise.resolve()
  conn.on('data', (chunk) => {
    conn.cuBuffer += chunk.toString('utf8')
    let index
    while ((index = conn.cuBuffer.indexOf('\n')) >= 0) {
      const line = conn.cuBuffer.slice(0, index)
      conn.cuBuffer = conn.cuBuffer.slice(index + 1)
      const entry = conn.cuPending.shift()
      if (!entry) continue
      clearTimeout(entry.timer)
      let payload
      try {
        payload = JSON.parse(line)
      } catch {
        entry.reject(Object.assign(new Error('输入助手返回了无法解析的输出'), { code: 'bad-output' }))
        continue
      }
      entry.resolve(payload)
    }
  })
  conn.on('close', () => {
    for (const entry of conn.cuPending.splice(0)) {
      clearTimeout(entry.timer)
      entry.reject(Object.assign(new Error('输入助手连接已断开'), { code: 'daemon-closed' }))
    }
    if (inputState.conn === conn) inputState.conn = undefined
  })
  conn.on('error', () => {})
  inputState.conn = conn
  return conn
}

function roundtrip(conn, request, timeoutMs) {
  return new Promise((resolve, reject) => {
    const entry = {
      resolve,
      reject,
      timer: setTimeout(() => {
        const index = conn.cuPending.indexOf(entry)
        if (index >= 0) conn.cuPending.splice(index, 1)
        conn.destroy() // a timed-out request would desync the response queue
        reject(Object.assign(new Error(`输入助手响应超时（${timeoutMs}ms）`), { code: 'input-timeout' }))
      }, timeoutMs),
    }
    conn.cuPending.push(entry)
    conn.write(`${JSON.stringify(request)}\n`)
  })
}

async function runInput(command, args, options) {
  const timeoutMs = options.timeoutMs ?? (command === 'sequence' ? 120_000 : RUN_TIMEOUT_MS)
  try {
    const conn = await getConnection()
    const request = { command, ...args }
    const queued = (conn.cuQueue = conn.cuQueue.catch(() => {}).then(() => roundtrip(conn, request, timeoutMs)))
    const payload = await queued
    if (payload?.ok === false) {
      const failure = new Error(payload.error ?? `输入助手执行失败（${command}）`)
      failure.code = 'helper-error'
      throw failure
    }
    return payload
  } catch (error) {
    if (error.code === 'helper-error' || error.code === 'input-timeout') throw error
    // Daemon unreachable → one-shot fallback (still much faster than the fat
    // helper because this binary links CoreGraphics only).
    return runOneShotInput(command, args, options)
  }
}

async function runOneShotInput(command, args, options) {
  const build = await ensureInputHelper()
  if (build.ok) {
    const { error, stdout, stderr } = await execFileAsync(build.path, [command, JSON.stringify(args)], {
      timeout: options.timeoutMs ?? (command === 'sequence' ? 120_000 : RUN_TIMEOUT_MS),
    })
    let payload
    try {
      payload = JSON.parse(stdout)
    } catch {
      const failure = new Error(`输入助手返回了无法解析的输出（${command}）`)
      failure.code = 'bad-output'
      failure.hint = (stderr || stdout || error?.message || '').slice(-600)
      throw failure
    }
    if (error || payload?.ok === false) {
      const failure = new Error(payload?.error ?? error?.message ?? `输入助手执行失败（${command}）`)
      failure.code = payload?.error ? 'helper-error' : (error?.killed ? 'helper-timeout' : 'helper-exit')
      failure.hint = stderr.slice(-600) || undefined
      throw failure
    }
    return payload
  }
  // No input binary at all → last resort: the fat helper for legacy commands.
  if (LEGACY_INPUT_COMMANDS.has(command)) {
    return runFat(command, args, options)
  }
  const failure = new Error(build.error ?? '低延迟输入助手不可用。')
  failure.code = build.code ?? 'input-helper-missing'
  failure.hint = build.hint
  throw failure
}

async function runFat(command, args, options) {
  const helper = await ensureHelper()
  if (!helper.ok) {
    const error = new Error(helper.error)
    error.code = helper.code
    error.hint = helper.hint
    throw error
  }
  const { error, stdout, stderr } = await execFileAsync(helper.path, [command, JSON.stringify(args)], {
    timeout: options.timeoutMs ?? RUN_TIMEOUT_MS,
  })
  let payload
  try {
    payload = JSON.parse(stdout)
  } catch {
    const failure = new Error(`原生助手返回了无法解析的输出（${command}）`)
    failure.code = 'bad-output'
    failure.hint = (stderr || stdout || error?.message || '').slice(-600)
    throw failure
  }
  if (error || payload?.ok === false) {
    const failure = new Error(payload?.error ?? error?.message ?? `原生助手执行失败（${command}）`)
    failure.code = payload?.error ? 'helper-error' : (error?.killed ? 'helper-timeout' : 'helper-exit')
    failure.hint = stderr.slice(-600) || undefined
    throw failure
  }
  return payload
}

/** Run one helper command. Throws an Error carrying `code` on failure. */
export async function run(command, args = {}, options = {}) {
  if (INPUT_COMMANDS.has(command)) return runInput(command, args, options)
  return runFat(command, args, options)
}

/** Cheap health report used by `computer_permissions` and the README. */
export async function describeHelper() {
  const helper = await ensureHelper()
  if (!helper.ok) return helper
  const describe = async (target) => {
    try {
      return { bytes: (await stat(target)).size }
    } catch {
      return {}
    }
  }
  const main = await describe(helper.path)
  const input = helper.input?.ok ? await describe(helper.input.path) : {}
  const daemon = helper.input?.ok && inputState.conn && !inputState.conn.destroyed
    ? { daemon: 'connected', socket: inputSocketPath(helper.input.hash) }
    : { daemon: 'idle (starts on first input command)' }
  return {
    ok: true,
    path: helper.path,
    compiled: helper.compiled === true,
    buildMs: helper.ms,
    bytes: main.bytes,
    input: helper.input?.ok
      ? { ok: true, path: helper.input.path, bytes: input.bytes, compiled: helper.input.compiled === true, ...daemon }
      : { ok: false, code: helper.input?.code, error: helper.input?.error },
    ...state.version ? { lastBuild: state.version } : {},
  }
}
