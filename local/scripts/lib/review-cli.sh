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

# Pull the assistant text out of pi --mode json (or mixed stdout), else keep raw.
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

text = raw
data = try_parse(raw)
if data is None:
    start = raw.find("{")
    if start < 0:
        start = raw.find("[")
    if start >= 0:
        for end in range(len(raw), start, -1):
            data = try_parse(raw[start:end])
            if data is not None:
                break
if data is not None:
    extracted = first_string(
        data,
        prefer=("text", "result", "message", "content", "output", "response"),
    )
    if extracted:
        text = extracted

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
  # Probe pid unshare once with true; never re-run the reviewer on a real nonzero exit.
  if "${base[@]}" --unshare-pid -- true >/dev/null 2>&1; then
    bwrap_cmd+=(--unshare-pid)
  fi
  "${bwrap_cmd[@]}" -- "$@"
  local rc=$?
  case "$_oldopts" in *e*) set -e ;; esac
  return "$rc"
}

# pi: short -p instruction + @file for the packed prompt (avoids MAX_ARG_STRLEN).
# stdin is closed. Tools and session are off. Writes only allowed_dir.
run_pi_review() {
  local prompt_file="$1" out_file="$2" allowed_dir="$3"
  local err_file="${4:-$out_file.err}"
  local pi_bin
  pi_bin="$(command -v pi)" || return 127
  local instruction="You are an independent read-only code reviewer. Read only the attached review bundle. Do not call tools or modify files. The first line of your reply must be exactly VERDICT: PASS or VERDICT: FAIL with no leading space, markdown, or blank line."
  # Record invocation outside the jail so tests (and operators) can audit flags
  # without depending on the jailed process being able to write sidecars.
  {
    wc -c < "$prompt_file" | tr -d " " > "$allowed_dir/review-argfile.bytes"
    sha256sum "$prompt_file" | cut -d" " -f1 > "$allowed_dir/review-argfile.sha"
    printf "0\n" > "$allowed_dir/review-stdin.bytes"
    printf "pi-review --no-session --no-tools --no-mcp --no-extensions --no-skills --no-context-files --no-prompt-templates --mode json @%s\n" "$prompt_file" > "$allowed_dir/review-argv.txt"
  } 2>/dev/null || true

  set +e
  # ~/.pi must stay writable for pi lock files even with --no-session.
  # The worktree / allowed review dir policy is unchanged: only listed binds are writable.
  local -a sandbox_writes=(--write "$allowed_dir")
  if [[ -n "${HOME:-}" && -d "$HOME/.pi" ]]; then
    sandbox_writes+=(--write "$HOME/.pi")
  fi
  review_sandbox_run "${sandbox_writes[@]}" -- \
    "$pi_bin" --no-session --no-tools --no-mcp --no-extensions --no-skills \
    --no-context-files --no-prompt-templates --mode json \
    -p "$instruction" "@${prompt_file}" < /dev/null > "$out_file" 2>"$err_file"
  local rc=$?
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

# Video worker engine switch. MONTAGE_CLI wins; default pi. agy remains available.
review_cli_name_for_montage() {
  local raw="${MONTAGE_CLI:-${REVIEW_CLI:-pi}}"
  raw="${raw,,}"
  case "$raw" in
    pi|agy) printf '%s' "$raw" ;;
    *) printf '%s' "pi" ;;
  esac
}
