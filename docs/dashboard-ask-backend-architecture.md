# `dashboard ask`'s two backend shapes, and where a new backend fits

Why some `dashboard ask` backends are a direct HTTP call and others shell
out to a CLI, and which shape a new backend should follow.

## The two existing shapes

- **Direct-API** (`--claude`, the default whenever `ANTHROPIC_API_KEY` is
  set): `_call_claude_api` builds an `LWP::UserAgent` POST directly against
  the provider's own REST endpoint, with a bearer/API-key header and a
  JSON request body, and parses the JSON response itself. No external
  binary is involved.
- **CLI-fallback** (`--codex`, `--copilot`, `--gemini`, or `--claude` with
  no key set): `_ask_cli_backend` shells out to that provider's own
  installed CLI tool (`codex`, `copilot`, `gemini`) via `_capture_backend`/
  `_run_cli`, forwarding the prompt as an argument and reading the tool's
  stdout as the answer.

**Which shape a new backend needs depends on whether the provider exposes
a plain REST endpoint at all.** A provider with only a CLI tool (no public
HTTP API a script can call directly) has no choice but the CLI-fallback
shape. A provider with a real REST API should use the direct-API shape -
it is simpler, has no external-tool dependency, and (as of DD-948) is the
only path that can eventually gain real SSE token-level streaming.

## Amazon Nova (DD-952)

Nova has a plain, standalone REST endpoint -
`https://api.nova.amazon.com/v1/chat/completions` - authenticated with a
bearer token (`NOVA_API_KEY`), taking an OpenAI-chat-completions-style
request body (`{model, messages: [{role, content}]}`). This is
architecturally identical to Claude's own direct-API path, just a
different endpoint, model name, and env var - so `--nova` follows the
direct-API shape (`_call_nova_api`, mirroring `_call_claude_api`), not the
CLI-shellout shape.

**This was nearly built against the wrong API.** The URL first given for
this integration (`nova.amazon.com/apis`) requires an Amazon account login
and is not public documentation - fetching it returns a sign-in page, and
following the trail from there leads to AWS Bedrock's `InvokeModel`/
`Converse` APIs (SigV4-signed, requiring per-region model-access approval
on the AWS console) - a materially different, heavier integration than the
one actually wanted. The real API only became clear from a working `curl`
example. **When a linked "API docs" URL redirects to a login page, that is
a sign the URL is not documentation - verify with a real request/response
example before assuming which API family a provider belongs to**,
especially for a provider (like Amazon) that exposes more than one product
under a similar name.

## How to apply, for the next new backend

1. Get (or ask for) a real, working request example - not just a
   documentation URL - before choosing a backend shape. A redirect to a
   login page or a vague marketing page is not enough to design against.
2. If the provider has a plain REST endpoint, follow the direct-API shape.
   If it only ships a CLI tool, follow the CLI-fallback shape.
3. Name the credential env var and the exact endpoint in the new backend's
   own code comment, the way `_call_claude_api` and `_call_nova_api` both
   do - the next person choosing a shape for the backend after that should
   not have to re-derive it from scratch.

## The direct-API path's repo-search gap, and the tool_use loop that closes it (DD-946)

**The asymmetry.** `dashboard ask`'s CLI-fallback path (no
`ANTHROPIC_API_KEY` set, local `claude` CLI available) answers
repo-specific questions correctly, because the local `claude` CLI IS the
full Claude Code agent - it gets Read/Grep/Bash tool access to its cwd as
an incidental side effect of what that CLI is, not by any deliberate
design in `Ask.pm`. The direct-API path (`_call_claude_api`, the
documented default whenever `ANTHROPIC_API_KEY` IS set) is a single
non-streaming POST to the Anthropic Messages API with no filesystem
access at all - it can only answer from the prompt text, `--file`
attachments, replayed history, and DD-938's static curated
`_docs_context()` blurb. None of that lets it answer a question needing
fine-grained source detail (e.g. "which file/line implements X").

**The fix is a real `tool_use` loop, scoped to two read-only tools.**
Unlike the CLI-fallback path's blanket Bash/Read/Grep access, the
direct-API path gets exactly two tools, both refusing any path outside
the current project root (`PathRegistry`'s project root):

- `read_file` - read one file's contents by path.
- `grep_repo` - search file contents by pattern, scoped to the project
  tree.

No write tool, no exec tool, and no tool at all for the CLI-fallback path
(it already has its own, broader access - adding a second mechanism there
would be redundant, not additive).

**The Anthropic Messages API `tool_use` shape**, the exact contract the
loop implements:

- The request carries a top-level `tools` array:
  `[{name, description, input_schema}, ...]`.
- A response whose `stop_reason` is `tool_use` carries one or more
  content blocks of shape `{type: 'tool_use', id, name, input}`.
- The client executes the named tool locally with `input`, then sends a
  new **user**-role message back with a content block
  `{type: 'tool_result', tool_use_id, content}` (one per `tool_use`
  block in the prior turn).
- The loop repeats - send, inspect `stop_reason`, execute any
  `tool_use` blocks, reply with `tool_result` - until `stop_reason` is
  anything other than `tool_use` (normally `end_turn`), at which point
  the final text content is the answer.

**AC-3's unchanged-behavior requirement falls out of this shape for
free.** A plain question that needs no repo search never causes the model
to emit a `tool_use` block, so the first response already has
`stop_reason != 'tool_use'` and the loop exits after exactly one request
- the same single-POST behavior `_call_claude_api` has today, same
request shape, tools array present but unused.
