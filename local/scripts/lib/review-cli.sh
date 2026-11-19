#!/usr/bin/env bash
# Independent read-only review helpers for run-worker.sh (MOZ-41).
# Default REVIEW_CLI/MONTAGE_CLI/WORKER_CLI is codex; pi and agy are
# explicit fallbacks. Never prints secrets.
# Codex review: fresh process, --sandbox read-only --ephemeral, no bypass,
# prompt from stdin to EOF. Parent installs audit outputs with O_NOFOLLOW.
# pi review fallback: --no-session, --no-tools, bwrap write jail when available.

review_cli_name() {
  local raw="${REVIEW_CLI:-codex}"
  raw="${raw,,}"
  case "$raw" in
    codex|pi|agy) printf '%s' "$raw" ;;
    *) printf '%s' "codex" ;;
  esac
}

# Video worker engine switch. Default is always codex; MONTAGE_CLI does not
# inherit REVIEW_CLI (so REVIEW_CLI=agy cannot silently switch montage).
review_cli_name_for_montage() {
  local raw="${MONTAGE_CLI:-codex}"
  raw="${raw,,}"
  case "$raw" in
    codex|pi|agy) printf '%s' "$raw" ;;
    *) printf '%s' "codex" ;;
  esac
}

# Pull the assistant text out of pi --mode json / JSONL, else keep raw.
# Writes the review body to $2 and prints the exact first line (no CR, trailing space stripped).
extract_review_text() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PYEXTRACT'
import errno, json, os, sys
from pathlib import Path

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
raw = src.read_text(encoding="utf-8", errors="replace")

def write_nofollow(path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(path, flags, 0o644)
    except OSError as e:
        sys.exit(91 if e.errno == errno.ELOOP else 1)
    with os.fdopen(fd, "wb") as out:
        out.write(data)

def first_string(obj, prefer=()):
    if isinstance(obj, str) and obj.strip():
        return obj
    if isinstance(obj, dict):
        for key in prefer:
            if key in obj:
                found = first_string(obj[key], prefer)
                if found:
                    return found
        for value in obj.values():
            found = first_string(value, prefer)
            if found:
                return found
    if isinstance(obj, list):
        for item in obj:
            found = first_string(item, prefer)
            if found:
                return found
    return None

def try_parse(blob):
    blob = blob.strip()
    if not blob:
        return None
    try:
        return json.loads(blob)
    except json.JSONDecodeError:
        return None

def text_from_jsonl(blob):
    """Assemble assistant text_delta events; ignore thinking_delta and system text."""
    parts = []
    saw_event = False
    for line in blob.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        ev = try_parse(line)
        if not isinstance(ev, dict):
            continue
        saw_event = True
        inner = ev.get("assistantMessageEvent") if isinstance(ev.get("assistantMessageEvent"), dict) else ev
        typ = inner.get("type") or ev.get("type") or ""
        if typ in ("thinking_delta", "thinking"):
            continue
        if typ in ("text_delta", "content_delta", "text"):
            delta = inner.get("delta") or inner.get("text") or ev.get("delta") or ""
            if isinstance(delta, str) and delta:
                parts.append(delta)
            continue
        # A completed assistant message, if present, wins over earlier deltas.
        msg = ev.get("message")
        if typ in ("message_end", "turn_end") and isinstance(msg, dict):
            role = msg.get("role")
            content = msg.get("content") or msg.get("text") or ""
            if role in (None, "assistant", "model"):
                if isinstance(content, str) and content.strip():
                    return content
                if isinstance(content, list):
                    chunks = []
                    for item in content:
                        if isinstance(item, str):
                            chunks.append(item)
                        elif isinstance(item, dict):
                            if item.get("type") in ("thinking", "thinking_delta"):
                                continue
                            piece = item.get("text") or item.get("delta") or ""
                            if piece:
                                chunks.append(piece)
                    if chunks:
                        return "".join(chunks)
    if parts:
        return "".join(parts)
    return None if saw_event else None

text = raw
data = try_parse(raw)
if data is not None:
    extracted = first_string(
        data,
        prefer=("text", "result", "message", "content", "output", "response"),
    )
    if extracted:
        text = extracted
else:
    jsonl_text = text_from_jsonl(raw)
    if jsonl_text:
        text = jsonl_text

if text.startswith("\ufeff"):
    text = text[1:]
# Whitespace-only reports must stay size-0 so the worker can use empty_report.
if not text.strip():
    write_nofollow(str(dest), b"")
    sys.stdout.write("")
else:
    payload = text if text.endswith("\n") else text + "\n"
    write_nofollow(str(dest), payload.encode("utf-8"))
    first = text.splitlines()[0].replace("\r", "").rstrip()
    sys.stdout.write(first)
PYEXTRACT
}

# Run argv inside a root that is read-only except explicit bind-write dirs.
# /tmp is a fresh tmpfs (not the host /tmp and not the audit path).
# stdout/stderr stay in the caller (redirects are outside the jail).
review_sandbox_run() {
  local -a writes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --write) writes+=("$2"); shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "review_sandbox_missing_bwrap" >&2
    return 90
  fi
  local -a base=(bwrap --die-with-parent --ro-bind / / --dev /dev --proc /proc)
  local dir
  for dir in "${writes[@]}"; do
    [[ -n "$dir" ]] || continue
    mkdir -p "$dir"
    base+=(--bind "$dir" "$dir")
  done
  local _oldopts=$-
  set +e
  local -a bwrap_cmd=("${base[@]}")
  if "${base[@]}" --unshare-pid -- true >/dev/null 2>&1; then
    bwrap_cmd+=(--unshare-pid)
  fi
  "${bwrap_cmd[@]}" -- "$@"
  local rc=$?
  case "$_oldopts" in *e*) set -e ;; esac
  return "$rc"
}

# pi: short -p instruction + @file for the packed prompt (avoids MAX_ARG_STRLEN).
# stdin is closed. Tools and session are off.
# Writable binds are limited to $HOME/.pi/agent (lock files). Audit paths and
# the worktree stay read-only; the parent holds stdout/stderr fds itself.
run_pi_review() {
  local prompt_file="$1" out_file="$2" allowed_dir="$3"
  local err_file="${4:-$out_file.err}"
  local pi_bin
  pi_bin="$(command -v pi)" || return 127
  local instruction="You are an independent read-only code reviewer. Read only the attached review bundle. Do not call tools or modify files. The first line of your reply must be exactly VERDICT: PASS or VERDICT: FAIL with no leading space, markdown, or blank line."
  mkdir -p "$allowed_dir"
  # Record invocation outside the jail so tests (and operators) can audit flags
  # without depending on the jailed process being able to write sidecars.
  {
    wc -c < "$prompt_file" | tr -d " " > "$allowed_dir/review-argfile.bytes"
    sha256sum "$prompt_file" | cut -d" " -f1 > "$allowed_dir/review-argfile.sha"
    printf "0\n" > "$allowed_dir/review-stdin.bytes"
    printf "pi-review --no-session --no-tools --no-mcp --no-extensions --no-skills --no-context-files --no-prompt-templates --mode json @%s\n" "$prompt_file" > "$allowed_dir/review-argv.txt"
  } 2>/dev/null || true

  # Do not tmpfs or overlay /tmp: test and host binaries may live under /tmp.
  # Give pi a private writable TMPDIR instead; the rest of the tree stays ro.
  local tmp_scratch
  tmp_scratch="$(mktemp -d "${TMPDIR:-/var/tmp}/pi-review.XXXXXX")"
  local -a sandbox_writes=(--write "$tmp_scratch")
  if [[ -n "${HOME:-}" ]]; then
    mkdir -p "$HOME/.pi/agent"
    sandbox_writes+=(--write "$HOME/.pi/agent")
  fi
  export TMPDIR="$tmp_scratch"

  local -a timeout_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout -k 10 15m)
  fi

  set +e
  review_sandbox_run "${sandbox_writes[@]}" -- \
    "${timeout_cmd[@]}" \
    "$pi_bin" --no-session --no-tools --no-mcp --no-extensions --no-skills \
    --no-context-files --no-prompt-templates --mode json \
    -p "$instruction" "@${prompt_file}" < /dev/null > "$out_file" 2>"$err_file"
  local rc=$?
  rm -rf "$tmp_scratch" 2>/dev/null || true
  # Leave errexit off until after return; a nonzero return under set -e aborts the worker.
  return "$rc"
}

run_agy_review() {
  local prompt_file="$1" out_file="$2"
  set +e
  env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY -u SSH_AUTH_SOCK \
    agy --disable-slash-commands --dangerously-skip-permissions --print-timeout 15m \
    --input-format text < "$prompt_file" > "$out_file" 2>&1
  local rc=$?
  return "$rc"
}

# Codex engine helpers (t41 / MOZ-41). Sourced at the end of review-cli.sh.
# Defaults are codex. pi and agy remain explicit fallbacks.
# Never prints secrets. Never uses <file < /dev/null (the second redirect wins).

# Copy src onto dest using O_NOFOLLOW (will not write through a symlink dest).
install_nofollow() {
  python3 - "$1" "$2" <<'NFCOPY'
import errno, os, sys
src, dest = sys.argv[1], sys.argv[2]
flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC
try:
    fd = os.open(dest, flags, 0o644)
except OSError as e:
    sys.exit(91 if e.errno == errno.ELOOP else 1)
with os.fdopen(fd, "wb") as out, open(src, "rb") as inp:
    while True:
        chunk = inp.read(1024 * 1024)
        if not chunk:
            break
        out.write(chunk)
NFCOPY
}

# Create or truncate dest as a regular file; never follow a symlink.
truncate_nofollow() {
  python3 - "$1" <<'NFTRUNC'
import errno, os, sys
dest = sys.argv[1]
flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC
try:
    fd = os.open(dest, flags, 0o644)
except OSError as e:
    sys.exit(91 if e.errno == errno.ELOOP else 1)
os.close(fd)
NFTRUNC
}

worker_cli_name() {
  local raw="${WORKER_CLI:-codex}"
  raw="${raw,,}"
  case "$raw" in
    codex|pi|agy) printf '%s' "$raw" ;;
    *) printf '%s' "codex" ;;
  esac
}

ensure_codex_on_path() {
  if command -v codex >/dev/null 2>&1; then
    return 0
  fi
  local d="${HOME:-}/.local/share/mise/installs/node/24.14.0/bin"
  if [[ -x "$d/codex" ]]; then
    PATH="$d:${PATH:-}"
    export PATH
    return 0
  fi
  return 127
}

# Implementation / montage: Codex's own approval+sandbox bypass only.
# Prompt is read from stdin to EOF via a single redirect. Not interactive.
run_codex_exec() {
  local prompt_file="$1" work_dir="$2" out_file="$3"
  local err_file="${4:-$out_file.err}"
  ensure_codex_on_path || return 127
  local bin
  bin="$(command -v codex)" || return 127
  [[ -f "$prompt_file" ]] || return 2
  mkdir -p "$(dirname "$out_file")"
  set +e
  # Single stdin source. Do not append "< /dev/null" after this redirect.
  "$bin" exec --dangerously-bypass-approvals-and-sandbox --color never \
    -C "$work_dir" --json \
    - < "$prompt_file" > "$out_file" 2>"$err_file"
  local rc=$?
  return "$rc"
}

# Independent review: native Codex read-only sandbox. No bypass.
# Fresh process (--ephemeral, no resume). Prompt from stdin file to EOF.
run_codex_review() {
  local prompt_file="$1" out_file="$2" worktree_dir="$3" allowed_dir="${4:-$(dirname "$out_file")}"
  local err_file="${5:-$out_file.err}"
  ensure_codex_on_path || return 127
  local bin
  bin="$(command -v codex)" || return 127
  [[ -f "$prompt_file" ]] || return 2
  mkdir -p "$allowed_dir"

  local priv
  priv="$(mktemp -d "${TMPDIR:-/var/tmp}/codex-audit-out.XXXXXX")"
  local priv_last="$priv/last.txt" priv_json="$priv/out.jsonl" priv_err="$priv/err.txt"
  local priv_extracted="$priv/extracted.txt" priv_meta="$priv/sidecars"
  : > "$priv_last" ; : > "$priv_json" ; : > "$priv_err" ; : > "$priv_extracted"
  mkdir -p "$priv_meta"
  # Sidecars are staged privately, then installed with O_NOFOLLOW so a
  # pre-existing symlink in $allowed_dir cannot be followed by the parent.
  wc -c < "$prompt_file" | tr -d " " > "$priv_meta/review-argfile.bytes"
  sha256sum "$prompt_file" | cut -d" " -f1 > "$priv_meta/review-argfile.sha"
  wc -c < "$prompt_file" | tr -d " " > "$priv_meta/review-stdin.bytes"
  printf 'codex-review exec --sandbox read-only --ephemeral --color never -C %s --output-last-message <stdin-file> -\n' \
    "$worktree_dir" > "$priv_meta/review-argv.txt"
  local side
  for side in review-argfile.bytes review-argfile.sha review-stdin.bytes review-argv.txt; do
    if ! install_nofollow "$priv_meta/$side" "$allowed_dir/$side"; then
      rm -rf "$priv" 2>/dev/null || true
      return 91
    fi
  done

  local -a timeout_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout -k 10 15m)
  fi

  set +e
  # Single stdin source from the SHA-bound pack. No trailing /dev/null.
  "${timeout_cmd[@]}" "$bin" exec --sandbox read-only --ephemeral --color never \
    -C "$worktree_dir" \
    --output-last-message "$priv_last" \
    --json \
    - < "$prompt_file" > "$priv_json" 2>"$priv_err"
  local rc=$?

  if [[ -s "$priv_last" ]]; then
    install_nofollow "$priv_last" "$out_file" || rc=91
  elif [[ -s "$priv_json" ]]; then
    # Never let extract_review_text open $out_file directly; stage then install.
    extract_review_text "$priv_json" "$priv_extracted" >/dev/null || true
    if ! install_nofollow "$priv_extracted" "$out_file"; then
      rc=91
    elif [[ ! -s "$out_file" ]]; then
      rc="${rc:-1}"
    fi
  else
    truncate_nofollow "$out_file" || rc=91
  fi
  # Symlink install failures always become 91, even if Codex itself already
  # returned a non-zero status. The parent must not follow those dests.
  install_nofollow "$priv_json" "$out_file.raw" || rc=91
  install_nofollow "$priv_err" "$err_file" || rc=91
  rm -rf "$priv" 2>/dev/null || true
  return "$rc"
}
