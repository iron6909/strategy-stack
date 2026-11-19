# desktop-env.sh — load whitelist desktop session fields without sourcing files.
# Prefer `systemctl --user show-environment`, then $HOME/.harness/desktop.env.
# Never print values. Never eval. Call after inject_providers_env if used.

_desktop_whitelist="DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP"

_desktop_safe_value() {
  # reject empty or shell metacharacters
  case "$1" in
    ""|*['$'\\\`\;\|\&\<\>\(\)\{\}$'\n'$'\r']*) return 1 ;;
  esac
  return 0
}

_desktop_set_if_empty() {
  local key="$1" value="$2"
  eval "local current=\${$key-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  _desktop_safe_value "$value" || return 0
  printf -v "$key" '%s' "$value"
  export "$key"
}

load_desktop_session_env() {
  local key value line
  local -A from_systemd=()
  local -A from_file=()
  if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"
      value="${line#*=}"
      case " $_desktop_whitelist " in
        *" $key "*) from_systemd[$key]="$value" ;;
      esac
    done < <(systemctl --user show-environment 2>/dev/null || true)
  fi
  local file="${DESKTOP_ENV_FILE:-$HOME/.harness/desktop.env}"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == \#* || -z "$line" ]] && continue
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"
      value="${line#*=}"
      case " $_desktop_whitelist " in
        *" $key "*) from_file[$key]="$value" ;;
      esac
    done < "$file"
  fi
  for key in $_desktop_whitelist; do
    if [[ -n "${from_systemd[$key]-}" ]]; then
      _desktop_set_if_empty "$key" "${from_systemd[$key]}"
    elif [[ -n "${from_file[$key]-}" ]]; then
      _desktop_set_if_empty "$key" "${from_file[$key]}"
    fi
  done
}
