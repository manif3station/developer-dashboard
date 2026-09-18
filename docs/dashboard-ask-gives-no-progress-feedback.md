# `dashboard ask` is silent until it finishes — why, on both backend paths

What a caller of `dashboard ask` actually sees while it runs, and why
neither backend surfaces anything before the final answer.

## The two backend paths, and why both are silent

`CLI::Ask.pm` dispatches to one of two backends:

- **Direct-API path** (`_call_claude_api`, the default whenever
  `ANTHROPIC_API_KEY` is set): a single non-streaming POST to the Anthropic
  Messages API. The entire response has to arrive before the call returns —
  there is no SSE wiring, so there is nothing to surface progressively even
  in principle.
- **CLI-fallback path** (`_ask_cli_backend` → `_capture_backend` →
  `_run_cli`): shells out to a backend CLI (`codex`, `copilot`, `gemini`, or
  `claude` with no key set) and captures its entire stdout/stderr with
  `Capture::Tiny`'s `capture { ... }` before returning anything. Whatever
  that CLI prints while it runs — and several of them do print
  incrementally — is buffered and only released once the process exits.

So the silence is not a missing flag or an oversight in one path; it is the
consequence of two genuinely different mechanisms, both of which happen to
be fully buffered.

## Not the same problem as the three streaming readers

`streaming-child-process-output.md` describes a different subsystem
(SkillDispatcher/SkillManager/PageRuntime's `IPC::Open3` + `IO::Select`
readers), where the challenge is draining two pipes without deadlocking.
`CLI::Ask.pm`'s CLI-fallback path uses `Capture::Tiny` instead, which is a
different library with a different default (buffer-then-return, not
stream-as-you-go) — the fix here is not "reuse the reader pattern", it is
either teeing `Capture::Tiny`'s underlying output or switching that one path
to a real streaming capture mechanism.

## How to apply

- Before claiming any `dashboard ask` change gives "live" feedback, check
  which backend path it touches — a fix to the CLI-fallback path does
  nothing for the direct-API path, and vice versa.
- `Capture::Tiny`'s `capture` is buffer-then-return by construction; getting
  incremental output out of it means teeing the underlying filehandle
  yourself, not passing a different option to `capture`.
- Real token-level streaming on the direct-API path requires wiring
  Anthropic's SSE response mode into `_call_claude_api` — a materially
  larger change than teeing an already-spawned CLI's output, and worth
  scoping as its own separate step (see DD-948).
