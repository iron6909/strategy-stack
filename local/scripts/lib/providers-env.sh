#!/usr/bin/env bash
# providers.env 注入：run-worker.sh / run-video-worker.sh 在启动 pi/agy 之前调用。
#
# 契约：
# - 只注入一个受信本地路径 $HOME/.harness/providers.env；不存在即跳过，不算失败。
# - source 失败（含语法错误）返回非零，调用方必须硬失败退出，绝不吞错。
# - 调用前已开启的 allexport 在返回时保持开启。
# - 进程环境里已有的变量优先：注入后复原旧值，文件不覆盖调用方环境。
# - 证据只写路径 / 是否存在 / 权限 / 键名 set|kept，绝不写值。
#
# 调用方必须写成 `inject_providers_env <证据文件> || { ...; exit N; }`：
# 这样 errexit 不会抢在写证据之前退出，source 失败也照样非零退出。

# shortcut: 复原整个进程环境（含 PATH），providers.env 若需扩展 PATH 要改成白名单恢复
inject_providers_env() {
  # 先摘掉 allexport 再声明其余局部变量：否则它们会被导出、混进下面的环境快照与证据
  local pe_allexport=0
  if [[ -o allexport ]]; then
    pe_allexport=1
    set +a
  fi
  # 局部变量统一 pe_ 前缀，避免 source 进来的同名键被本函数的局部作用域吞掉
  local pe_evidence="${1:-}" pe_file="$HOME/.harness/providers.env"
  local -A pe_pre=()
  local -a pe_injected=() pe_kept=()
  local pe_name pe_rc=0 pe_exists=0 pe_mode="none"

  if [[ -e "$pe_file" ]]; then
    pe_exists=1
    pe_mode="$(stat -c '%a' "$pe_file" 2>/dev/null)" || pe_mode="unknown"
    # 只处理常规标识符变量：`_` 与导出函数等由 bash 自己维护，不参与复原
    while IFS= read -r pe_name; do
      [[ "$pe_name" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] && pe_pre[$pe_name]="${!pe_name}"
    done < <(compgen -e)
    set -a
    # 源文件自身可能报错并回显行内容，stderr 一律丢弃：失败只报路径与退出码，绝不回显文件内容
    . "$pe_file" 2>/dev/null
    pe_rc=$?
    set +a
    for pe_name in "${!pe_pre[@]}"; do
      test "${!pe_name-}" = "${pe_pre[$pe_name]}" && continue
      pe_kept+=("$pe_name")
      export "$pe_name=${pe_pre[$pe_name]}"
    done
    while IFS= read -r pe_name; do
      [[ -v "pe_pre[$pe_name]" ]] || pe_injected+=("$pe_name")
    done < <(compgen -e)
  fi

  [[ "$pe_allexport" -eq 1 ]] && set -a
  if [[ -n "$pe_evidence" ]]; then
    {
      printf 'path=%s\n' "$pe_file"
      printf 'exists=%s\n' "$pe_exists"
      printf 'mode=%s\n' "$pe_mode"
      printf 'allexport_before=%s\n' "$pe_allexport"
      if [[ -o allexport ]]; then printf 'allexport_after=1\n'; else printf 'allexport_after=0\n'; fi
      if [[ "$pe_exists" -eq 1 && "$pe_rc" -eq 0 ]]; then printf 'injected=1\n'; else printf 'injected=0\n'; fi
      for pe_name in "${pe_injected[@]}"; do printf 'key=%s:set\n' "$pe_name"; done
      for pe_name in "${pe_kept[@]}"; do printf 'key=%s:kept\n' "$pe_name"; done
    } > "$pe_evidence"
  fi
  unset pe_allexport
  return "$pe_rc"
}
