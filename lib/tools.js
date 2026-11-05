/**
 * The seven Agent-facing tools.
 *
 * Everything visual comes back as an image ContentBlock (through the Host
 * `attachments` service) so a vision-capable model sees the screen directly.
 * When the model or the attachment service cannot take images, the tool still
 * returns the PNG path plus a `read_image` hint instead of failing the call.
 */
import { execFile } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { run, ensureHelper, describeHelper } from './helper.js'
import { captureScreen } from './screen.js'

const jsonObject = { type: 'object', additionalProperties: true }

// Last accessibility snapshot from computer_read, used by computer_act.
let lastSnapshot = null

const DEFAULTS = {
  allowInput: true,
  resolution: 'points',
  blockedApps: ['1Password', 'Keychain Access'],
  defaultDisplay: 1,
  typeMaxChars: 8000,
  clickPauseMs: 60,
  warmup: true,
}

function render(args, value) {
  const source = value && typeof value === 'object' && !Array.isArray(value) ? value : { value }
  const { image, ...rest } = source
  const parts = [{ type: 'text', text: JSON.stringify(rest, null, 2).slice(0, 12_000) }]
  if (image) parts.push({ type: 'image', attachment: image })
  return parts
}

function bounded(value, min, max, fallback) {
  const number = Number(value)
  if (!Number.isFinite(number)) return fallback
  return Math.min(max, Math.max(min, number))
}

function delay(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return Promise.resolve()
  return new Promise((resolve) => setTimeout(resolve, Math.min(ms, 15_000)))
}

function sanitize(value) {
  // Tool results must be lossless JSON: no undefined, functions, or class instances.
  try {
    return JSON.parse(JSON.stringify(value ?? null))
  } catch {
    return null
  }
}

function errorPayload(error) {
  const message = error?.message
    ?? (typeof error?.error === 'string' ? error.error : undefined)
    ?? (typeof error === 'string' ? error : JSON.stringify(error))
  return {
    ok: false,
    error: String(message),
    ...error?.code ? { code: error.code } : {},
    ...error?.hint ? { hint: error.hint } : {},
  }
}

async function attachImage(ctx, exec, file, mediaType = 'image/png') {
  const attachments = ctx.get('attachments')
  if (!attachments || typeof attachments.saveImages !== 'function') {
    return {
      ok: false,
      code: 'attachments-unavailable',
      hint: `宿主的 attachments 服务不可用，图片停留在：${file}。可以用 read_image 工具读它。`,
    }
  }
  const capacity = await modelAcceptsImages(ctx, exec)
  if (capacity.ok === false) {
    return {
      ok: false,
      code: capacity.code,
      hint: `${capacity.hint}图片停留在：${file}。可以用 read_image 工具读它。`,
    }
  }
  try {
    const bytes = await readFile(file)
    const refs = await attachments.saveImages([{ data: bytes, mediaType }])
    const ref = Array.isArray(refs) ? refs[0] : refs
    return ref ? { ok: true, ref } : { ok: false, code: 'attach-empty', hint: `附件服务没有返回引用，图片在：${file}` }
  } catch (error) {
    return {
      ok: false,
      code: 'attach-failed',
      hint: `存图片失败：${error?.message ?? error}；图片在：${file}`,
    }
  }
}

async function modelAcceptsImages(ctx, exec) {
  const llm = ctx.get('llm')
  if (!llm || typeof llm.resolveModelInfo !== 'function') return { ok: true, unverified: true }
  let provider
  let model
  try {
    const header = exec?.agent?.session?.requestHeader?.()
    provider = header?.config?.provider ?? exec?.agent?.options?.provider
    model = header?.config?.model ?? exec?.agent?.options?.model
  } catch {}
  if (!provider || !model) return { ok: true, unverified: true }
  try {
    const info = await llm.resolveModelInfo(provider, model, exec?.signal)
    const modalities = info?.inputModalities
    if (!Array.isArray(modalities)) return { ok: true, unverified: true }
    if (!modalities.includes('image')) {
      return {
        ok: false,
        code: 'model-no-image',
        hint: `当前模型 ${provider}/${model} 没有声明图片输入能力（${modalities.join(',') || '无'}）。`,
      }
    }
    return { ok: true, unverified: false }
  } catch {
    return { ok: true, unverified: true }
  }
}

export function createTools(ctx, rawConfig) {
  const cfg = { ...DEFAULTS, ...(rawConfig && typeof rawConfig === 'object' ? rawConfig : {}) }
  const blockedApps = (Array.isArray(cfg.blockedApps) ? cfg.blockedApps : DEFAULTS.blockedApps)
    .map((entry) => String(entry).trim().toLowerCase())
    .filter(Boolean)

  if (cfg.warmup !== false) {
    // Compile in the background so the first screenshot is not held up by swiftc.
    ensureHelper().catch(() => {})
  }

  async function guardTarget() {
    const info = await run('info')
    const frontmost = info.frontmost ?? {}
    const name = String(frontmost.name ?? '').toLowerCase()
    const blocked = blockedApps.find((entry) => name.includes(entry))
    if (blocked) {
      const error = new Error(`前台应用是「${frontmost.name}」，命中 blockedApps 里的「${blocked}」，已拒绝发送输入。`)
      error.code = 'blocked-app'
      error.hint = '先把目标窗口切到前台，或在插件 config 里调整 blockedApps。'
      throw error
    }
    return info
  }

  function assertInputAllowed() {
    if (cfg.allowInput === false) {
      const error = new Error('插件配置里 allowInput=false，鼠标键盘工具已禁用。')
      error.code = 'input-disabled'
      error.hint = '在 cordis.patch.yml 里设置 allowInput: true 再试。'
      throw error
    }
  }

  const tools = [
    {
      name: 'computer_screenshot',
      description: '截取当前屏幕（或某个窗口 / 区域）并直接把图片回给你，用来"看"屏幕上发生了什么。'
        + '默认返回 point 尺寸的图：图上 1 像素 = 屏幕 1 point，可直接作为 computer_mouse 的坐标。'
        + '返回里带你点击时需要的换算：click_x = origin.x + 图_x * pointsPerPixel。',
      parameters: {
        type: 'object',
        properties: {
          window: { type: 'number', description: '窗口 id（先用 computer_windows 拿）。传了就只截这个窗口。' },
          region: {
            type: 'object',
            description: '只截一块区域，单位 point',
            properties: {
              x: { type: 'number' },
              y: { type: 'number' },
              width: { type: 'number' },
              height: { type: 'number' },
            },
            required: ['x', 'y', 'width', 'height'],
          },
          display: { type: 'number', description: `显示器序号，默认 ${DEFAULTS.defaultDisplay}` },
          resolution: { type: 'string', enum: ['points', 'pixels'], description: '默认 points（推荐）：图像 1 像素 = 1 point' },
          delayMs: { type: 'number', description: '截图前等待多少毫秒，用来等动画或加载' },
        },
      },
      output: { schema: jsonObject, render },
      async execute(args = {}, exec) {
        try {
          await delay(args.delayMs)
          const shot = await captureScreen({
            window: Number.isFinite(args.window) ? Number(args.window) : undefined,
            region: args.region && typeof args.region === 'object' ? args.region : undefined,
            display: Number.isFinite(args.display) ? Number(args.display) : cfg.defaultDisplay,
            resolution: args.resolution === 'pixels' ? 'pixels' : cfg.resolution,
          })
          const attached = await attachImage(ctx, exec, shot.file)
          const summary = {
            ok: true,
            file: shot.file,
            image: attached.ok ? attached.ref : undefined,
            imageAttached: attached.ok,
            size: { width: shot.width, height: shot.height },
            pointsPerPixel: shot.pointsPerPixel,
            origin: shot.origin,
            coordinateRule: 'click_x = origin.x + image_x * pointsPerPixel ; click_y = origin.y + image_y * pointsPerPixel',
            capture: shot.capture,
            display: shot.display,
            cursor: shot.cursor,
            frontmost: shot.frontmost,
            capturedAt: shot.capturedAt,
            ...attached.ok ? {} : { imageSkipReason: attached.code, imageHint: attached.hint },
          }
          return summary
        } catch (error) {
          return errorPayload(error)
        }
      },
    },

    {
      name: 'computer_windows',
      description: '列出当前屏幕上的窗口（含 app 名、标题、位置、尺寸）、列出可切换的正在运行的 app，或把某个 app 切到前台。'
        + '截图/点击之前先用它确认目标和窗口 id；`activate` 拿不准名字时先 `apps` 看准确的 app 名。',
      parameters: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['list', 'apps', 'frontmost', 'activate'], description: '默认 list' },
          app: { type: 'string', description: 'action=activate 时要切到前台的 app 名或 bundle id，例如 "Safari"' },
          all: { type: 'boolean', description: 'action=list 时是否连不可见窗口一起列（默认只列屏幕上的）' },
        },
      },
      output: { schema: jsonObject, render },
      async execute(args = {}) {
        try {
          const action = String(args.action ?? 'list')
          if (action === 'activate') {
            const app = String(args.app ?? '').trim()
            if (!app) {
              const error = new Error('action=activate 需要 app 参数。')
              error.code = 'missing-app'
              throw error
            }
            return { ok: true, ...(await run('activate', { app })) }
          }
          if (action === 'frontmost') {
            const info = await run('info')
            return { ok: true, frontmost: info.frontmost, cursor: info.cursor, screens: info.screens }
          }
          if (action === 'apps') {
            const listed = await run('apps')
            return { ok: true, apps: listed.apps, frontmost: listed.frontmost, count: (listed.apps || []).length }
          }
          const listed = await run('windows', { all: args.all === true })
          return { ok: true, windows: listed.windows, frontmost: listed.frontmost, count: (listed.windows || []).length }
        } catch (error) {
          return errorPayload(error)
        }
      },
    },

    {
      name: 'computer_mouse',
      description: '移动／点击／拖拽／滚动鼠标。坐标是屏幕 point 坐标，原点在主屏左上角，可直接用 computer_screenshot 的返回值换算。'
        + '点击前会先检查前台 app（blockedApps 命中就拒绝）。',
      parameters: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['move', 'click', 'double_click', 'right_click', 'middle_click', 'hold', 'drag', 'scroll', 'position'],
            description: '要做的动作；position 只读取当前光标位置；hold 按住鼠标键',
          },
          x: { type: 'number', description: '目标 x（point），move/click/drag/hold 用' },
          y: { type: 'number', description: '目标 y（point）' },
          dx: { type: 'number', description: 'move 的相对位移（point），给了 dx/dy 就忽略 x/y；游戏视角转动用' },
          dy: { type: 'number', description: 'move 的相对位移；scroll 时是纵向滚动量，正值向下；100~600 是一屏的常见量' },
          toX: { type: 'number', description: 'drag 的终点 x' },
          toY: { type: 'number', description: 'drag 的终点 y' },
          button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'click/hold 用，默认 left' },
          holdMs: { type: 'number', description: 'action=hold 的按住时长（毫秒），默认 200' },
          repeat: { type: 'number', description: 'click 连发次数（每次都是独立单击，游戏连点用），默认 1' },
          intervalMs: { type: 'number', description: '连发间隔毫秒，默认普通 80 / game 40' },
          downMs: { type: 'number', description: '按下到抬起的毫秒，默认普通 14 / game 4' },
          durationMs: { type: 'number', description: '移动/拖拽耗时（毫秒），默认点击瞬时、拖拽 400' },
          humanize: { type: 'boolean', description: '拟人移动：贝塞尔轨迹+微抖动+自然节奏（默认关）' },
          game: { type: 'boolean', description: '游戏模式：砍掉事件间隔换取最低延迟（move ~0.2ms、click ~5ms）' },
        },
      },
      output: { schema: jsonObject, render },
      isConcurrencySafe: () => false,
      async execute(args = {}) {
        try {
          assertInputAllowed()
          const action = String(args.action ?? 'click')
          if (action === 'position') {
            const info = await run('info')
            return { ok: true, cursor: info.cursor, frontmost: info.frontmost }
          }
          const target = await guardTarget()
          if (action === 'move') {
            const relative = Number.isFinite(args.dx) || Number.isFinite(args.dy)
            const result = await run('move', relative
              ? {
                  dx: Number(args.dx) || 0,
                  dy: Number(args.dy) || 0,
                  durationMs: bounded(args.durationMs, 0, 5000, 0),
                  humanize: args.humanize === true,
                  game: args.game === true,
                }
              : {
                  x: Number(args.x) || 0,
                  y: Number(args.y) || 0,
                  durationMs: bounded(args.durationMs, 0, 5000, 0),
                  humanize: args.humanize === true,
                  game: args.game === true,
                })
            return { ok: true, action, relative, cursor: { x: result.x, y: result.y }, frontmost: target.frontmost }
          }
          if (action === 'hold') {
            const result = await run('hold', {
              button: String(args.button ?? 'left'),
              holdMs: bounded(args.holdMs, 1, 60_000, 200),
              x: Number.isFinite(args.x) ? Number(args.x) : undefined,
              y: Number.isFinite(args.y) ? Number(args.y) : undefined,
              game: args.game === true,
            })
            return { ok: true, action, button: result.button, holdMs: result.holdMs, cursor: { x: result.x, y: result.y }, frontmost: target.frontmost }
          }
          if (action === 'drag') {
            const result = await run('drag', {
              fromX: Number(args.x) || 0,
              fromY: Number(args.y) || 0,
              toX: Number(args.toX) || 0,
              toY: Number(args.toY) || 0,
              durationMs: bounded(args.durationMs, 50, 10_000, 400),
              humanize: args.humanize === true,
              game: args.game === true,
            })
            return { ok: true, action, cursor: { x: result.x, y: result.y }, frontmost: target.frontmost }
          }
          if (action === 'scroll') {
            const result = await run('scroll', {
              x: Number.isFinite(args.x) ? Number(args.x) : undefined,
              y: Number.isFinite(args.y) ? Number(args.y) : undefined,
              dy: Number(args.dy) || 0,
              dx: Number(args.dx) || 0,
            })
            return { ok: true, action, dy: result.dy, dx: result.dx, frontmost: target.frontmost }
          }
          const preset = action === 'double_click' ? { button: 'left', count: 2 }
            : action === 'right_click' ? { button: 'right', count: 1 }
              : action === 'middle_click' ? { button: 'middle', count: 1 }
                : { button: 'left', count: 1 }
          const result = await run('click', {
            x: Number(args.x) || 0,
            y: Number(args.y) || 0,
            button: preset.button,
            count: preset.count,
            repeat: Number.isFinite(args.repeat) ? Math.floor(args.repeat) : undefined,
            intervalMs: Number.isFinite(args.intervalMs) ? bounded(args.intervalMs, 1, 5000, undefined) : undefined,
            downMs: Number.isFinite(args.downMs) ? bounded(args.downMs, 1, 5000, undefined) : undefined,
            humanize: args.humanize === true,
            game: args.game === true,
          })
          return {
            ok: true,
            action,
            button: preset.button,
            count: preset.count,
            repeat: result.repeat,
            clickedAt: { x: Number(args.x) || 0, y: Number(args.y) || 0 },
            frontmost: target.frontmost,
          }
        } catch (error) {
          return errorPayload(error)
        }
      },
    },

    {
      name: 'computer_keyboard',
      description: '打字或按快捷键。type 直接输入文本（含中文，绕过输入法）；key 按单个键（return/tab/escape/left/f1…）；'
        + 'hotkey 按组合键（如 cmd+shift+t）。默认按键发给当前前台窗口。',
      parameters: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['type', 'key', 'hotkey'], description: '默认 type' },
          text: { type: 'string', description: 'action=type 时要输入的文本' },
          key: { type: 'string', description: 'action=key 的键名，如 return、tab、escape、delete、left、f2' },
          keys: { type: 'array', items: { type: 'string' }, description: 'action=hotkey 的组合键，最后一个是主键，如 ["cmd","shift","t"]' },
          modifiers: { type: 'array', items: { type: 'string' }, description: 'action=key 时可附加的修饰键：cmd/shift/alt/ctrl/fn' },
          holdMs: { type: 'number', description: 'action=key 的按住毫秒，默认普通 14 / game 4；游戏漏检按键时调大' },
          delayMs: { type: 'number', description: '按键后等待毫秒再返回，默认为 0' },
          game: { type: 'boolean', description: '游戏模式：砍掉事件间隔换取最低延迟（key ~10ms）' },
        },
      },
      output: { schema: jsonObject, render },
      isConcurrencySafe: () => false,
      async execute(args = {}) {
        try {
          assertInputAllowed()
          const action = String(args.action ?? 'type')
          const target = await guardTarget()
          if (action === 'type') {
            const text = String(args.text ?? '')
            if (!text) {
              const error = new Error('action=type 需要 text 参数。')
              error.code = 'missing-text'
              throw error
            }
            if (text.length > cfg.typeMaxChars) {
              const error = new Error(`一次最多输入 ${cfg.typeMaxChars} 个字符，当前 ${text.length}。请分段输入。`)
              error.code = 'text-too-long'
              throw error
            }
            const result = await run('type', { text, game: args.game === true })
            await delay(args.delayMs)
            return { ok: true, action, typedLength: result.length, frontmost: target.frontmost }
          }
          if (action === 'hotkey') {
            const keys = Array.isArray(args.keys) ? args.keys.map((entry) => String(entry).trim()).filter(Boolean) : []
            if (keys.length < 2) {
              const error = new Error('action=hotkey 需要至少两个键，例如 ["cmd","t"]。')
              error.code = 'bad-hotkey'
              throw error
            }
            const key = keys[keys.length - 1]
            const modifiers = keys.slice(0, -1)
            const result = await run('key', { key, modifiers, holdMs: args.holdMs, game: args.game === true })
            await delay(args.delayMs)
            return { ok: true, action, key, modifiers, frontmost: target.frontmost }
          }
          const key = String(args.key ?? '')
          if (!key) {
            const error = new Error('action=key 需要 key 参数。')
            error.code = 'missing-key'
            throw error
          }
          const modifiers = Array.isArray(args.modifiers) ? args.modifiers.map((entry) => String(entry)) : []
          const result = await run('key', { key, modifiers, holdMs: args.holdMs, game: args.game === true })
          await delay(args.delayMs)
          return { ok: true, action, key, modifiers, frontmost: target.frontmost }
        } catch (error) {
          return errorPayload(error)
        }
      },
    },


    {
      name: 'computer_sequence',
      description: '把一串输入原语按顺序一次执行（游戏连招/组合操作）。每步 do=move|click|hold|drag|scroll|key|type|wait，'
        + '参数与 computer_mouse/computer_keyboard 同名；afterMs 是该步后的等待。一次调用走完，比逐个工具调用快一个数量级。',
      parameters: {
        type: 'object',
        properties: {
          steps: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                do: { type: 'string', enum: ['move', 'click', 'hold', 'drag', 'scroll', 'key', 'type', 'wait'] },
                afterMs: { type: 'number', description: '该步执行完后的等待毫秒' },
              },
              description: '其余字段与对应原语一致：move{x,y,dx,dy,durationMs,humanize} click{x,y,button,repeat,intervalMs,downMs} hold{button,holdMs} drag{fromX,fromY,toX,toY,durationMs} scroll{dy,dx} key{key,modifiers,holdMs} type{text} wait{ms}',
            },
            description: '步骤列表，按顺序执行',
          },
          stopOnError: { type: 'boolean', description: '某步失败是否停止后续步骤，默认 true' },
          game: { type: 'boolean', description: '默认游戏间隔，单步可用自己的 game 覆盖' },
        },
        required: ['steps'],
      },
      output: { schema: jsonObject, render },
      isConcurrencySafe: () => false,
      async execute(args = {}) {
        try {
          assertInputAllowed()
          const steps = Array.isArray(args.steps) ? args.steps : []
          if (!steps.length) {
            const error = new Error('steps 需要至少一步，例如 [{ do: "key", key: "w", holdMs: 300 }]。')
            error.code = 'missing-steps'
            throw error
          }
          if (steps.length > 64) {
            const error = new Error(`一次最多 64 步，当前 ${steps.length}。`)
            error.code = 'too-many-steps'
            throw error
          }
          const target = await guardTarget()
          const result = await run('sequence', {
            steps,
            stopOnError: args.stopOnError !== false,
            game: args.game === true,
          })
          return {
            ok: true,
            steps: result.steps,
            cursor: { x: result.x, y: result.y },
            executed: result.steps.filter((step) => step.ok !== false).length,
            frontmost: target.frontmost,
          }
        } catch (error) {
          return errorPayload(error)
        }
      },
    },

    {
      name: 'computer_read',
      description: '读懂屏幕：一次调用同时拿到「可交互元素」（辅助功能树，含 role/标题/坐标/index）和「屏幕文字」（OCR，含坐标）。'
        + '这是"看清再动手"的首选：先用它定位按钮/输入框/文字，再用 computer_act 按 index 精确操作，比猜坐标可靠。'
        + '默认读前台窗口；给 app 或 window 可以读后台窗口（截图和元素树都来自它，不用切前台）；scope=screen 读整块屏幕。'
        + '图片默认不返回（文字足够省 token），需要看像素时用 computer_screenshot。',
      parameters: {
        type: 'object',
        properties: {
          scope: { type: 'string', enum: ['window', 'screen'], description: '默认 window＝前台窗口（给了 app/window 时读对应窗口）' },
          app: { type: 'string', description: '要读哪个 app（辅助功能树 + 它最大的可见窗口截图）；默认当前前台 app' },
          window: { type: 'number', description: '直接指定窗口 id（computer_windows action=list 里的 id），优先于 app' },
          elements: { type: 'boolean', description: '是否返回可交互元素，默认 true' },
          text: { type: 'boolean', description: '是否 OCR 识别屏幕文字，默认 true' },
          fast: { type: 'boolean', description: 'OCR 用快速模式（快但中文识别差，默认 false＝精确模式）' },
          maxNodes: { type: 'number', description: '元素上限，默认 120' },
          region: {
            type: 'object',
            description: '只读一块区域（point），给了就忽略 scope',
            properties: { x: { type: 'number' }, y: { type: 'number' }, width: { type: 'number' }, height: { type: 'number' } },
            required: ['x', 'y', 'width', 'height'],
          },
          includeImage: { type: 'boolean', description: '顺便附上截图（默认 false）' },
        },
      },
      output: { schema: jsonObject, render },
      isConcurrencySafe: true,
      async execute(args = {}, exec = {}) {
        try {
          const wantElements = args.elements !== false
          const wantText = args.text !== false
          const scope = args.scope === 'screen' ? 'screen' : 'window'
          const info = await run('info')
          const frontmost = info.frontmost ?? {}
          const wantedApp = typeof args.app === 'string' && args.app.trim() ? args.app.trim() : ''
          const wantedWindow = Number.isFinite(Number(args.window)) && args.window !== undefined ? Number(args.window) : null
          const matchesApp = (entryApp, needle) => {
            if (!entryApp || !needle) return false
            const a = String(entryApp).toLowerCase()
            const b = needle.toLowerCase()
            return a === b || a.includes(b) || b.includes(a)
          }
          let windowId
          let windowApp
          if (scope === 'window' && !args.region) {
            if (wantedWindow !== null) {
              const listed = await run('windows')
              const entry = (listed.windows || []).find((w) => w.id === wantedWindow)
              windowApp = entry?.app
              windowId = wantedWindow
            } else {
              const listed = await run('windows')
              const pool = wantedApp
                ? (listed.windows || []).filter((entry) => matchesApp(entry.app, wantedApp))
                : (listed.windows || []).filter((entry) => entry.app && frontmost.name && entry.app === frontmost.name)
              const biggest = pool.sort((a, b) => (b.width * b.height) - (a.width * a.height))[0]
              if (wantedApp && !biggest) {
                const error = new Error(`没有找到「${wantedApp}」的可见窗口；用 computer_windows action=list 查窗口 id，或省略 app 读前台。`)
                error.code = 'window-not-found'
                throw error
              }
              windowId = biggest?.id
            }
          }
          const shot = await captureScreen({
            window: windowId,
            region: args.region,
            resolution: 'pixels',
          })
          const pointsWidth = shot.capturedWidth / (shot.scale || 1)
          const pointsHeight = shot.capturedHeight / (shot.scale || 1)
          const result = {
            ok: true,
            scope: windowId ? 'window' : (args.region ? 'region' : 'screen'),
            app: wantedApp || windowApp || frontmost.name,
            bundleId: (wantedApp || windowApp) ? undefined : frontmost.bundleId,
            target: windowId
              ? { window: windowId, x: shot.origin.x, y: shot.origin.y, width: Math.round(pointsWidth), height: Math.round(pointsHeight) }
              : { x: shot.origin.x, y: shot.origin.y, width: Math.round(pointsWidth), height: Math.round(pointsHeight) },
            frontmost,
          }

          if (wantElements) {
            const snapshot = await run('ax', {
              app: args.app ?? '',
              maxNodes: bounded(args.maxNodes, 1, 600, 120),
              maxDepth: 12,
              interactive: true,
            })
            const nodes = (snapshot.nodes || []).map((node, index) => ({
              index,
              role: node.role,
              title: node.title,
              value: node.value,
              disabled: node.disabled === true || undefined,
              x: node.x, y: node.y, width: node.width, height: node.height,
              centerX: node.centerX, centerY: node.centerY,
              actions: node.actions,
            }))
            lastSnapshot = { app: args.app ?? '', resolvedApp: snapshot.app, pid: snapshot.pid, nodes: snapshot.nodes, at: Date.now() }
            result.elementsApp = snapshot.app
            result.elements = nodes
            result.elementCount = nodes.length
          }

          if (wantText) {
            const ocr = await run('ocr', {
              file: shot.file,
              pointsWidth,
              pointsHeight,
              originX: shot.origin.x,
              originY: shot.origin.y,
              languages: ['zh-Hans', 'en-US'],
              fast: args.fast === true,
              maxDimension: 5000,
            })
            result.text = (ocr.lines || []).map((line) => ({
              text: line.text,
              x: line.x, y: line.y, width: line.width, height: line.height,
              centerX: line.centerX, centerY: line.centerY,
            }))
            result.textCount = result.text.length
          }

          if (args.includeImage === true) {
            const attached = await attachImage(ctx, exec, shot.file)
            if (attached?.attachment) result.image = attached.attachment
            else result.imageFile = shot.file
          }
          result.howToClick = 'computer_act 用 index；或 computer_mouse 用 centerX/centerY（point 坐标）'
          return sanitize(result)
        } catch (error) {
          return errorPayload(error)
        }
      },
    },

    {
      name: 'computer_act',
      description: '对 computer_read 返回的元素执行动作（走 macOS 辅助功能，比点坐标可靠）：'
        + 'press 按下按钮/链接、focus 聚焦输入框、set_value 直接填值、click 用坐标兜底点一下。'
        + 'target 是 computer_read 里的 index；也可以给 label 按文字/标题模糊匹配。',
      parameters: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['press', 'focus', 'set_value', 'click'], description: '默认 press' },
          target: { type: 'number', description: 'computer_read 返回的元素 index' },
          label: { type: 'string', description: '按元素标题/文字模糊匹配（target 不填时用）' },
          value: { type: 'string', description: 'set_value 要填入的文本' },
          app: { type: 'string', description: '目标 app；默认用上一次 computer_read 的 app' },
        },
      },
      output: { schema: jsonObject, render },
      isConcurrencySafe: false,
      async execute(args = {}) {
        try {
          assertInputAllowed()
          const action = ['press', 'focus', 'set_value', 'click'].includes(String(args.action))
            ? String(args.action)
            : 'press'
          if (!lastSnapshot) {
            const error = new Error('还没有可操作的元素快照。')
            error.code = 'no-snapshot'
            error.hint = '先调 computer_read 拿到 elements 和 index，再调 computer_act。'
            throw error
          }
          const nodes = lastSnapshot.nodes || []
          let node
          if (Number.isFinite(Number(args.target))) {
            node = nodes[Number(args.target)]
          } else if (typeof args.label === 'string' && args.label.trim()) {
            const needle = args.label.trim().toLowerCase()
            node = nodes.find((entry) => String(entry.title ?? '').toLowerCase().includes(needle))
              ?? nodes.find((entry) => String(entry.value ?? '').toLowerCase().includes(needle))
          }
          if (!node) {
            const error = new Error('没找到目标元素。')
            error.code = 'element-not-found'
            error.hint = '重新 computer_read 一次（界面可能变了），或用 computer_mouse 按坐标点。'
            throw error
          }
          const app = String(args.app ?? lastSnapshot.app ?? '')
          const path = node.path
          const fingerprint = {
            role: node.role,
            title: node.title,
            x: node.x,
            y: node.y,
            width: node.width,
            height: node.height,
          }
          let attempt
          if (action === 'click') {
            attempt = await run('click', { x: node.centerX, y: node.centerY, button: 'left' })
          } else if (action === 'set_value') {
            attempt = await run('axact', { app, path, fingerprint, action: 'set_value', value: String(args.value ?? '') })
            if (attempt && attempt.ok && attempt.result !== 'ok') {
              await run('axact', { app, path, fingerprint, action: 'focus' }).catch(() => {})
              await run('key', { key: 'a', modifiers: ['cmd'] }).catch(() => {})
              await run('type', { text: String(args.value ?? '') }).catch(() => {})
              attempt = { ok: true, result: 'typed' }
            }
          } else {
            attempt = await run('axact', { app, path, fingerprint, action })
            if (action === 'press' && attempt && attempt.result !== 'ok') {
              const fallback = await run('click', { x: node.centerX, y: node.centerY, button: 'left' })
              attempt = { ...attempt, fallbackClick: fallback.ok === true }
            }
          }
          return sanitize({
            ok: attempt?.ok !== false,
            action,
            app: attempt?.app ?? lastSnapshot.resolvedApp ?? app,
            element: { index: Number.isFinite(Number(args.target)) ? Number(args.target) : undefined, role: node.role, title: node.title, value: node.value, centerX: node.centerX, centerY: node.centerY },
            result: attempt?.result,
            actions: node.actions,
            ...attempt,
          })
        } catch (error) {
          return errorPayload(error)
        }
      },
    },

    {
      name: 'computer_permissions',
      description: '检查这台 Mac 有没有给 DeepSeek Harness 授权「辅助功能」（发鼠标键盘事件）和「屏幕录制」（截图），'
        + '并给出缺哪一项、去哪里开。第一次用这套工具前先跑一次它。',
      parameters: {
        type: 'object',
        properties: {
          openSettings: { type: 'boolean', description: '缺权限时顺便打开对应的系统设置面板' },
        },
      },
      output: { schema: jsonObject, render },
      async execute(args = {}) {
        try {
          const helper = await describeHelper()
          if (!helper.ok) return { ok: false, ...errorPayload(helper), helper }
          const permissions = await run('permissions')
          const info = await run('info')
          const missing = []
          if (!permissions.accessibility) missing.push('accessibility')
          if (!permissions.screenCapture) missing.push('screenCapture')
          if (missing.length && args.openSettings === true) {
            for (const pane of missing) {
              const target = pane === 'accessibility'
                ? 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
                : 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
              execFile('/usr/bin/open', [target], () => {})
            }
          }
          return {
            ok: missing.length === 0,
            permissions,
            missing,
            ready: missing.length === 0,
            hint: missing.length === 0
              ? '权限齐全，可以直接截图和模拟鼠标键盘。'
              : `缺 ${missing.join(' + ')}：打开 系统设置 → 隐私与安全性，勾选 DeepSeek Harness，然后重启 Harness。`,
            helper: { path: helper.path, bytes: helper.bytes, compiled: helper.compiled },
            screens: info.screens,
            frontmost: info.frontmost,
            platform: info.platform,
          }
        } catch (error) {
          return errorPayload(error)
        }
      },
    },
  ]

  return tools
}
