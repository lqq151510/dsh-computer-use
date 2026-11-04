/**
 * Compile-once bridge to `native/ComputerUse.swift`.
 *
 * The helper is a ~120 KB Swift binary built from the source shipped in this
 * package. It is cached under `~/.dsh/computer-use/bin/dsh-cu` and rebuilt only
 * when the source hash changes, so a plugin upgrade picks up new commands
 * automatically. Compilation needs the Xcode command line tools (`swiftc`);
 * when they are missing every tool reports an actionable error instead of
 * failing silently.
 */
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { constants as fsConstants } from 'node:fs'
import { access, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const PACKAGE_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
export const SUPPORTED = process.platform === 'darwin'

const SOURCE_PATH = path.join(PACKAGE_ROOT, 'native', 'ComputerUse.swift')
const CACHE_DIR = path.join(homedir(), '.dsh', 'computer-use')
const BIN_DIR = path.join(CACHE_DIR, 'bin')
const BINARY_PATH = path.join(BIN_DIR, 'dsh-cu')
const STAMP_PATH = path.join(BIN_DIR, 'dsh-cu.sha1')
const COMPILE_TIMEOUT_MS = 240_000
const RUN_TIMEOUT_MS = 20_000

const state = {
  build: undefined,
  version: undefined,
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

async function build() {
  await mkdir(BIN_DIR, { recursive: true })
  const source = await readFile(SOURCE_PATH, 'utf8')
  const hash = createHash('sha256').update(source).digest('hex')

  if (await exists(BINARY_PATH, fsConstants.X_OK)) {
    const stamp = await readFile(STAMP_PATH, 'utf8').catch(() => '')
    if (stamp.trim() === hash) return { ok: true, path: BINARY_PATH, compiled: false, hash }
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

  const staged = `${BINARY_PATH}.new-${process.pid}`
  const started = Date.now()
  const build = await execFileAsync(compiler.file,
    [...compiler.prefix, '-O', '-module-cache-path', path.join(CACHE_DIR, 'module-cache'), '-o', staged, SOURCE_PATH],
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

  await rename(staged, BINARY_PATH)
  await writeFile(STAMP_PATH, `${hash}\n`, 'utf8')
  state.version = { compiledAt: new Date().toISOString(), ms: Date.now() - started }
  return { ok: true, path: BINARY_PATH, compiled: true, hash, ms: Date.now() - started }
}

/** Resolve (and if necessary compile) the helper. Concurrent callers share one build. */
export async function ensureHelper() {
  if (!SUPPORTED) {
    return {
      ok: false,
      code: 'unsupported-platform',
      error: `当前系统是 ${process.platform}，这套原生鼠标键盘助手只实现了 macOS。`,
      hint: '在 macOS 上使用；Windows/Linux 需要各自的输入注入实现。',
    }
  }
  if (!state.build) {
    state.build = build().catch((error) => ({
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

/** Run one helper command. Throws an Error carrying `code` on failure. */
export async function run(command, args = {}, options = {}) {
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

/** Cheap health report used by `computer_permissions` and the README. */
export async function describeHelper() {
  const helper = await ensureHelper()
  if (!helper.ok) return helper
  let size = 0
  try {
    size = (await stat(helper.path)).size
  } catch {}
  return {
    ok: true,
    path: helper.path,
    compiled: helper.compiled === true,
    buildMs: helper.ms,
    bytes: size,
    ...state.version ? { lastBuild: state.version } : {},
  }
}
