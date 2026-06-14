#!/usr/bin/env bash
# cli-zoo-uninstall.sh - 从 $PREFIX (默认 /usr/local/bin) 卸载 cli-zoo 工具。
#
# 用法: ./cli-zoo-uninstall.sh <tool>
# 当前支持的 tool: otter

set -u

usage() {
    cat <<'EOF'
Usage: ./cli-zoo-uninstall.sh <tool>
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
    local prefix target
    prefix="${PREFIX:-/usr/local/bin}"

    case "$tool" in
        otter)
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

    if [[ -e "$target" || -L "$target" ]]; then
        if ! rm -f "$target" 2>/dev/null; then
            log_err "cannot remove $target; try: sudo PREFIX=$prefix $0 $tool"
            exit 1
        fi
        printf 'uninstalled: %s\n' "$target"
    else
        printf '%s does not exist; nothing to do\n' "$target"
    fi
    exit 0
}

main "$@"
