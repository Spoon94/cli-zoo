#!/usr/bin/env bash
# cli-zoo-install.sh - 安装 cli-zoo 提供的工具到 $PREFIX (默认 /usr/local/bin)。
#
# 用法: ./cli-zoo-install.sh <tool>
# 当前支持的 tool: otter

set -u

usage() {
    cat <<'EOF'
Usage: ./cli-zoo-install.sh <tool>
Supported tools: otter

Environment:
  PREFIX  install destination directory (default: /usr/local/bin)
EOF
}

log_err() {
    printf '%s\n' "$*" >&2
}

main() {
    if [[ $# -lt 1 ]]; then
        usage >&2
        exit 2
    fi

    local tool="$1"
    local repo_root prefix target src
    repo_root="$(cd "$(dirname "$0")" && pwd)"
    prefix="${PREFIX:-/usr/local/bin}"

    case "$tool" in
        otter)
            src="$repo_root/zoo-scripts/otter"
            target="$prefix/otter"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_err "unsupported tool: $tool"
            usage >&2
            exit 2
            ;;
    esac

    if [[ ! -f "$src" ]]; then
        log_err "source not found: $src"
        exit 1
    fi

    if [[ ! -x "$src" ]]; then
        chmod +x "$src" || {
            log_err "failed to chmod +x $src"
            exit 1
        }
    fi

    if [[ ! -d "$prefix" ]]; then
        if ! mkdir -p "$prefix" 2>/dev/null; then
            log_err "cannot create $prefix; try: sudo PREFIX=$prefix $0 $tool"
            exit 1
        fi
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        if ! rm -f "$target" 2>/dev/null; then
            log_err "cannot remove existing $target; try: sudo PREFIX=$prefix $0 $tool"
            exit 1
        fi
    fi

    if ! ln -s "$src" "$target" 2>/dev/null; then
        log_err "cannot create symlink $target -> $src; try: sudo PREFIX=$prefix $0 $tool"
        exit 1
    fi

    printf 'installed: %s -> %s\n' "$target" "$src"
}

main "$@"
