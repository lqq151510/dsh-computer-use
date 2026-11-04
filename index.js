/**
 * dsh-computer-use — Host half.
 *
 * Registers five `computer_*` tools on the shared tool registry. Everything the
 * tools need from the Host is optional and read lazily:
 *
 *   - `attachments` turns captured PNG bytes into an image ContentBlock so the
 *     model sees the screen (falls back to returning the file path);
 *   - `llm` is only probed to avoid attaching images to a text-only model;
 *   - `apps`/`fs` are not touched at all: the native helper does the work.
 *
 * The bundle ships `native/ComputerUse.swift`, compiled on first use into
 * `~/.dsh/computer-use/bin/dsh-cu` (see lib/helper.js).
 */
import { createTools } from './lib/tools.js'

/** The tool registry is the only hard dependency. */
export const inject = ['tools']

export function apply(ctx, config) {
  ctx.effect(() => {
    const disposers = createTools(ctx, config).map((definition) => ctx.tools.register(definition))
    return () => {
      for (const dispose of disposers.reverse()) {
        try {
          dispose()
        } catch {}
      }
    }
  }, 'computer-use: tools')
}
