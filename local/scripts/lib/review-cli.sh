#!/usr/bin/env bash
# Independent read-only review helpers for run-worker.sh (t40 / MOZ-41).
# REVIEW_CLI=pi (default) or agy. Never prints secrets.
# pi review: fresh process, --no-session, --no-tools, no large argv,
# OS-level write jail via bwrap when available.

review_cli_name() {
  local raw="${REVIEW_CLI:-pi}"
  raw="${raw,,}"
  case "$raw" in
    pi|agy) printf '%s' "$raw" ;;
    *) printf '%s' "pi" ;;
  esac
}

# Video worker engine switch. Default is always pi; MONTAGE_CLI does not
# inherit REVIEW_CLI (so REVIEW_CLI=agy cannot silently switch montage).
review_cli_name_for_montage() {
  local raw="${MONTAGE_CLI:-pi}"
  raw="${raw,,}"
  case "$raw" in
    pi|agy) printf '%s' "$raw" ;;
    *) printf '%s' "pi" ;;
  esac
}

# Pull the assistant text out of pi --mode json / JSONL, else keep raw.
# Writes the review body to $2 and prints the exact first line (no CR, trailing space stripped).
extract_review_text() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PYEXTRACT'
import json, sys
from pathlib import Path

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
raw = src.read_text(encoding="utf-8", errors="replace")

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
    dest.write_text("", encoding="utf-8")
    sys.stdout.write("")
else:
    dest.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
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
