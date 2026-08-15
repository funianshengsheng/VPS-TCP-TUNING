#!/bin/bash
set -o pipefail

SCRIPT_VERSION="6.14.2"
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
MODULES_CONF="/etc/modules-load.d/99-bbr-direct-tune.conf"
PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"
SYSTEMD_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
OPENRC_START="/etc/local.d/bbr-optimize.start"
SYSV_SERVICE="/etc/init.d/bbr-optimize-persist"
SWAP_FILE="/swapfile"
FSTAB_FILE="/etc/fstab"
PROC_SWAPS_FILE="/proc/swaps"
ALPINE_RELEASE_FILE="/etc/alpine-release"
ALPINE_SWAP_START="/etc/local.d/swap.start"
OPENRC_LOCAL_DEFAULT_LINK="/etc/runlevels/default/local"
STATE_DIR="/var/lib/bbr-direct-tune"
SYSCTL_STATE="${STATE_DIR}/sysctl.runtime"
QDISC_STATE="${STATE_DIR}/qdisc.state"
MQ_STATE="${STATE_DIR}/mq.state"
FQ_CODEL_STATE="${STATE_DIR}/fq_codel.state"
RPS_STATE="${STATE_DIR}/rps.state"
ROUTE_STATE="${STATE_DIR}/route.state"
INIT_WINDOW_MARKER="${STATE_DIR}/init-window.owned"
THP_STATE="${STATE_DIR}/thp.state"
PROFILE_STATE="${STATE_DIR}/profile.state"
CONFLICT_STATE="${STATE_DIR}/disabled-sysctl-files.map"
SYSCTL_CONFLICT_PATH_STATE="${STATE_DIR}/sysctl-conflict.path"
SNAPSHOT_MODE="${STATE_DIR}/snapshot.mode"
SNAPSHOT_READY="${STATE_DIR}/snapshot.ready"
SWAP_STATE="${STATE_DIR}/swap.state"
SWAP_HEADER_STATE="${STATE_DIR}/swap.header.before"
SWAP_MANAGED_HEADER_STATE="${STATE_DIR}/swap.header.managed"
SWAP_FSTAB_STATE="${STATE_DIR}/swap.fstab.before"
SWAP_ALPINE_START_STATE="${STATE_DIR}/swap.start.before"
SWAP_SNAPSHOT_READY="${STATE_DIR}/swap.snapshot.ready"
SWAP_MANAGED_STATE="${STATE_DIR}/swap.managed"
OPENRC_LOCAL_STATE="${STATE_DIR}/openrc.local.default.before"
OPENRC_OTHER_START_STATE="${STATE_DIR}/openrc.other-start.before"
DEFAULT_TARGET_RTT_MS=150
RTT_SAMPLE_MIN=""
RTT_SAMPLE_MEDIAN=""
RTT_SAMPLE_AVG=""
RTT_SAMPLE_P95=""
RTT_SAMPLE_MAX=""
RTT_SAMPLE_COUNT=0
RTT_TARGETS_USED=""
INIT_WINDOW_MANAGED=0
MSS_RULE_COMMENT="bbr-direct-tune"
AUTO_MODE="${AUTO_MODE:-0}"
UI_TTY=0
UI_UNICODE=0
OPERATION_LOCK_FILE="/run/lock/bbr-direct-tune.flock"
OPERATION_LOCK_DIR="/run/lock/bbr-direct-tune.lock"
OPERATION_LOCK_HELD=0
OPERATION_LOCK_OWNER_PID=""
OPERATION_LOCK_METHOD=""
MANAGED_TEMP_FILES=()
MANAGED_TEMP_DIRS=()
BBR_CONGESTION_CONTROL=""
SWAP_RESTORE_SWAPPINESS=""

SPEEDTEST_TMP_MARKER="/tmp/bbr-direct-tune-speedtest-dir.$$.${RANDOM}${RANDOM}"
SPEEDTEST_CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/ookla/speedtest-cli.json"
SPEEDTEST_CONFIG_EXISTED=0
SPEEDTEST_BIN=""
[ -e "$SPEEDTEST_CONFIG_FILE" ] && SPEEDTEST_CONFIG_EXISTED=1

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    UI_TTY=1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf-8*|*UTF8*|*utf8*) UI_UNICODE=1 ;;
    esac
fi

if [ "$UI_TTY" -eq 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    # Modern cyberpunk / neon palette
    gl_kjlan=$'\033[38;5;87m'    # electric cyan
    gl_zi=$'\033[38;5;213m'      # hot pink
    gl_lv=$'\033[38;5;82m'       # neon green
    gl_huang=$'\033[38;5;220m'   # gold
    gl_hong=$'\033[38;5;204m'    # crimson
    gl_bai=$'\033[0m'            # reset
    gl_hui=$'\033[38;5;245m'     # cool slate
    gl_bold=$'\033[1m'
    gl_dim=$'\033[2m'
    gl_underline=$'\033[4m'
else
    gl_kjlan=''
    gl_zi=''
    gl_lv=''
    gl_huang=''
    gl_hong=''
    gl_bai=''
    gl_hui=''
    gl_bold=''
    gl_dim=''
    gl_underline=''
fi

if [ "$UI_UNICODE" -eq 1 ]; then
    UI_CARD_TL='╭─'
    UI_CARD_SIDE='│'
    UI_CARD_BOTTOM='╰────────────────────────────────────────'
    UI_CARD_TAIL='──────────────────────────────'
    UI_TITLE_ICON='◆'
    UI_SECTION='▸'
    UI_SECTION_TAIL='┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄'
    UI_STEP_ON='▰'
    UI_STEP_OFF='▱'
    UI_OK='✓'
    UI_WARN='▲'
    UI_ERROR='✕'
    UI_INFO='▶'
    UI_PROMPT='❯'
    UI_LED='●'
    UI_DIV='─'
    UI_LINE='━'
    UI_DOT='·'
    UI_BANNER_ICON='▶'
else
    UI_CARD_TL='+-'
    UI_CARD_SIDE='|'
    UI_CARD_BOTTOM='+---------------------------------------'
    UI_CARD_TAIL='------------------------------'
    UI_TITLE_ICON='#'
    UI_SECTION='>>'
    UI_SECTION_TAIL='----------------'
    UI_STEP_ON='#'
    UI_STEP_OFF='-'
    UI_OK='[OK]'
    UI_WARN='[!]'
    UI_ERROR='[X]'
    UI_INFO='[>]'
    UI_PROMPT='>'
    UI_LED='*'
    UI_DIV='-'
    UI_LINE='='
    UI_DOT='.'
    UI_BANNER_ICON='>'
fi

# 霓虹渐变色带：青 -> 蓝 -> 紫 -> 粉，仅在支持彩色时参与渲染。
UI_GRADIENT_COLORS=(51 45 39 105 141 177 213 219)

TUNED_SYSCTL_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.tcp_window_scaling
    net.ipv4.tcp_moderate_rcvbuf
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.ipv4.ip_local_port_range
    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_abort_on_overflow
    net.core.netdev_max_backlog
    net.ipv4.tcp_timestamps
    net.ipv4.tcp_sack
    net.ipv4.tcp_dsack
    net.ipv4.tcp_ecn
    net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_fin_timeout
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_fastopen_blackhole_timeout_sec
    net.ipv4.udp_rmem_min
    net.ipv4.udp_wmem_min
    net.ipv4.tcp_syncookies
)

# 旧版曾管理这些全局 TCP 行为。新版本默认保留内核或管理员原值，但仍需识别
# 旧快照，确保升级和 restore 能把旧版写入的运行值还原。
RETIRED_SYSCTL_KEYS=(
    net.ipv4.tcp_no_metrics_save
    net.ipv4.tcp_notsent_lowat
    net.ipv4.tcp_retries2
    vm.swappiness
)

ui_gradient_rule() {
    # 8 段渐变分隔线；无彩色环境退化为等宽字符线。
    local rule_char="${1:-$UI_LINE}" segment_width="${2:-6}"
    local segment="" line="" color i

    for ((i = 0; i < segment_width; i++)); do
        segment+="$rule_char"
    done
    if [ -n "$gl_kjlan" ]; then
        for color in "${UI_GRADIENT_COLORS[@]}"; do
            line+=$'\033[38;5;'"${color}m${segment}"
        done
        printf '%s%b\n' "$line" "$gl_bai"
    else
        for ((i = 0; i < ${#UI_GRADIENT_COLORS[@]}; i++)); do
            line+="$segment"
        done
        printf '%s\n' "$line"
    fi
}

ui_card_start() {
    printf '\n%b%s%b%b%s%b %b%s%b %b%s%b\n' \
        "$gl_kjlan" "$UI_CARD_TL" "$gl_bai" \
        "$gl_zi" "$UI_TITLE_ICON" "$gl_bai" \
        "$gl_bold" "$1" "$gl_bai" \
        "$gl_hui$gl_dim" "$UI_CARD_TAIL" "$gl_bai"
}

ui_card_line() {
    local rendered_text="${2:-$1}"
    printf '%b%s%b  %s%b\n' "$gl_dim$gl_kjlan" "$UI_CARD_SIDE" "$gl_bai" "$rendered_text" "$gl_bai"
}

ui_kv() {
    printf '%b%s%b %b%s%b %b%s%b %s%b\n' \
        "$gl_dim$gl_kjlan" "$UI_CARD_SIDE" "$gl_bai" \
        "$gl_zi" "$1" "$gl_bai" \
        "$gl_hui" "$UI_DOT" "$gl_bai" \
        "$2" "$gl_bai"
}

ui_card_end() {
    printf '%b%s%b\n' "$gl_dim$gl_kjlan" "$UI_CARD_BOTTOM" "$gl_bai"
}

ui_banner() {
    printf '\n'
    ui_gradient_rule
    printf '  %b%s%b %bB B R%b %bD I R E C T · T U N E%b  %bv%s%b\n' \
        "$gl_huang" "$UI_BANNER_ICON" "$gl_bai" \
        "$gl_bold$gl_kjlan" "$gl_bai" \
        "$gl_bold$gl_zi" "$gl_bai" \
        "$gl_hui" "$SCRIPT_VERSION" "$gl_bai"
    printf '  %b智能网络调优引擎%b  %b低重传 %s 高突发 %s 跑满带宽 %s 稳定不抖%b\n' \
        "$gl_hui" "$gl_bai" \
        "$gl_kjlan" "$UI_DOT" "$UI_DOT" "$UI_DOT" "$gl_bai"
    ui_gradient_rule "$UI_DIV"
}

ui_section() {
    printf '\n%b%s%s%b %b%s%b %b%s%b\n' \
        "$gl_zi" "$UI_SECTION" "$UI_SECTION" "$gl_bai" \
        "$gl_bold$gl_kjlan" "$1" "$gl_bai" \
        "$gl_hui$gl_dim" "$UI_SECTION_TAIL" "$gl_bai"
}

ui_step() {
    local current_step="$1" total_steps="$2" title="$3"
    local bar="" i

    for ((i = 1; i <= total_steps; i++)); do
        if [ "$i" -le "$current_step" ]; then
            bar+="${gl_lv}${UI_STEP_ON}"
        else
            bar+="${gl_hui}${gl_dim}${UI_STEP_OFF}${gl_bai}"
        fi
    done
    printf '%s%b %b%02d%b%b/%02d%b %b%s%b %b%s%b\n' \
        "$bar" "$gl_bai" \
        "$gl_bold$gl_kjlan" "$current_step" "$gl_bai" \
        "$gl_hui" "$total_steps" "$gl_bai" \
        "$gl_zi" "$UI_SECTION" "$gl_bai" \
        "$gl_bold" "$title" "$gl_bai"
}

ui_success() {
    printf '%b%s %s%b\n' "$gl_lv" "$UI_OK" "$1" "$gl_bai"
}

ui_warn() {
    printf '%b%s %s%b\n' "$gl_huang" "$UI_WARN" "$1" "$gl_bai"
}

ui_error() {
    printf '%b%s %s%b\n' "$gl_hong" "$UI_ERROR" "$1" "$gl_bai"
}

ui_info() {
    printf '%b%s %s%b\n' "$gl_kjlan" "$UI_INFO" "$1" "$gl_bai"
}

ui_clear() {
    [ "$UI_TTY" -eq 1 ] && printf '\033[2J\033[H'
}

confirm_yn() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local auto_answer="${3:-$default_answer}"
    local answer=""
    local suffix="[y/N]"

    [ "$default_answer" = "y" ] && suffix="[Y/n]"
    if [ "$AUTO_MODE" = "1" ]; then
        [ "$auto_answer" = "y" ]
        return
    fi

    while true; do
        if ! read -r -p "$(printf '%b%s%b %s %s: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai" "$prompt" "$suffix")" answer; then
            answer="$default_answer"
        fi
        answer=${answer//$'\r'/}
        answer=${answer:-$default_answer}
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) ui_warn "请输入 y 或 n（大小写均可）" >&2 ;;
        esac
    done
}

normalize_uint() {
    local value="$1"
    local min_value="$2"
    local max_value="$3"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [ "${value#0}" != "$value" ]; do
        value=${value#0}
    done
    [ -n "$value" ] || value=0
    [ "${#value}" -le "${#max_value}" ] || return 1
    [ "$value" -ge "$min_value" ] && [ "$value" -le "$max_value" ] || return 1
    printf '%s\n' "$value"
}

validate_state_directory_path() {
    local owner permissions

    if [ -L "$STATE_DIR" ] || { [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; }; then
        ui_error "恢复保护目录类型异常，为避免覆盖其他数据已停止操作"
        return 1
    fi
    [ -d "$STATE_DIR" ] || return 0
    owner=$(stat -c '%u' "$STATE_DIR" 2>/dev/null || true)
    permissions=$(stat -c '%A' "$STATE_DIR" 2>/dev/null || true)
    if [ "$owner" != "0" ] || [ "${permissions:4:6}" != "------" ]; then
        ui_error "恢复保护目录权限异常，为避免读取不可信状态已停止操作"
        return 1
    fi
}

managed_output_path_is_safe() {
    local path="$1"

    [ ! -L "$path" ] && { [ ! -e "$path" ] || [ -f "$path" ]; }
}

validate_managed_output_paths() {
    local path

    validate_state_directory_path || return 1
    for path in "$SYSCTL_CONF" "$MODULES_CONF" "$PERSIST_SCRIPT" \
        "$SYSTEMD_SERVICE" "$OPENRC_START" "$SYSV_SERVICE"; do
        if ! managed_output_path_is_safe "$path"; then
            ui_error "检测到管理文件路径异常，为避免覆盖其他文件已停止应用"
            return 1
        fi
    done
}

validate_state_file_paths() {
    local path owner permissions
    local paths=(
        "$SYSCTL_STATE" "$QDISC_STATE" "$MQ_STATE" "$FQ_CODEL_STATE" "$RPS_STATE" "$ROUTE_STATE" "$THP_STATE"
        "$PROFILE_STATE" "$CONFLICT_STATE" "$SYSCTL_CONFLICT_PATH_STATE" "$INIT_WINDOW_MARKER"
        "$SNAPSHOT_MODE" "$SNAPSHOT_READY" "$SWAP_STATE" "$SWAP_HEADER_STATE"
        "$SWAP_MANAGED_HEADER_STATE" "$SWAP_FSTAB_STATE" "$SWAP_FSTAB_STATE.absent"
        "$SWAP_ALPINE_START_STATE" "$SWAP_ALPINE_START_STATE.absent"
        "$SWAP_SNAPSHOT_READY" "$SWAP_MANAGED_STATE" "$OPENRC_LOCAL_STATE" "$OPENRC_OTHER_START_STATE"
        "$STATE_DIR/sysctl.conf.before" "$STATE_DIR/sysctl.conf.absent"
    )

    validate_state_directory_path || return 1
    [ -d "$STATE_DIR" ] || return 0
    for path in "${paths[@]}"; do
        if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
            ui_error "恢复保护文件类型异常，为避免读取不可信状态已停止操作"
            return 1
        fi
        [ -e "$path" ] || continue
        case "$path" in
            "$SWAP_FSTAB_STATE"|"$SWAP_ALPINE_START_STATE")
                # 备份位于 root:0700 状态目录内，刻意保留原文件 owner/mode 供精确恢复。
                continue
                ;;
        esac
        owner=$(stat -c '%u' "$path" 2>/dev/null || true)
        permissions=$(stat -c '%A' "$path" 2>/dev/null || true)
        if [ "$owner" != "0" ] || [ "${permissions:5:1}" = "w" ] || [ "${permissions:8:1}" = "w" ]; then
            ui_error "恢复保护文件所有者异常，为避免读取不可信状态已停止操作"
            return 1
        fi
    done
}

prepare_managed_temp_file() {
    local temp_path="$1"

    [ ! -e "$temp_path" ] && [ ! -L "$temp_path" ] || return 1
    if ! (umask 077; set -o noclobber; : > "$temp_path") 2>/dev/null; then
        return 1
    fi
    MANAGED_TEMP_FILES+=("$temp_path")
}

finalize_managed_temp_file() {
    local temp_path="$1"
    local target_path="$2"
    local mode="$3"

    [ -f "$temp_path" ] && [ ! -L "$temp_path" ] || return 1
    managed_output_path_is_safe "$target_path" || return 1
    chown 0:0 "$temp_path" 2>/dev/null || return 1
    chmod "$mode" "$temp_path" 2>/dev/null || return 1
    mv -f -- "$temp_path" "$target_path" 2>/dev/null || return 1
    [ -f "$target_path" ] && [ ! -L "$target_path" ]
}

atomic_replace_file_preserving_metadata() {
    local temp_path="$1"
    local target_path="$2"
    local metadata_source="${3:-$target_path}"
    local mode=644 uid=0 gid=0

    [ -f "$temp_path" ] && [ ! -L "$temp_path" ] || return 1
    if [ -L "$target_path" ] || { [ -e "$target_path" ] && [ ! -f "$target_path" ]; }; then
        return 1
    fi
    if [ -e "$metadata_source" ] || [ -L "$metadata_source" ]; then
        [ -f "$metadata_source" ] && [ ! -L "$metadata_source" ] || return 1
        mode=$(stat -c '%a' "$metadata_source" 2>/dev/null) || return 1
        uid=$(stat -c '%u' "$metadata_source" 2>/dev/null) || return 1
        gid=$(stat -c '%g' "$metadata_source" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
    fi
    chown "$uid:$gid" "$temp_path" 2>/dev/null || return 1
    chmod "$mode" "$temp_path" 2>/dev/null || return 1
    mv -f -- "$temp_path" "$target_path" 2>/dev/null || return 1
    [ -f "$target_path" ] && [ ! -L "$target_path" ]
}

default_route_identity() {
    local route="$1"
    local token gateway="" device="" gateway_count=0 device_count=0
    local expect=""
    local route_tokens=()

    [ -n "$route" ] || return 1
    read -r -a route_tokens <<< "$route"
    for token in "${route_tokens[@]}"; do
        if [ -n "$expect" ]; then
            case "$expect" in
                via)
                    gateway="$token"
                    gateway_count=$((gateway_count + 1))
                    ;;
                dev)
                    device="$token"
                    device_count=$((device_count + 1))
                    ;;
            esac
            expect=""
            continue
        fi
        case "$token" in
            nexthop) return 1 ;;
            via|dev) expect="$token" ;;
        esac
    done
    [ "$device_count" -eq 1 ] && [ "$gateway_count" -le 1 ] || return 1
    printf 'dev=%s|via=%s\n' "$device" "$gateway"
}

acquire_operation_lock() {
    local owner_pid=""

    [ "$OPERATION_LOCK_HELD" -eq 0 ] || return 0
    if ! mkdir -p /run/lock 2>/dev/null; then
        ui_error "无法建立运行锁，已停止操作"
        return 1
    fi
    OPERATION_LOCK_OWNER_PID="${BASHPID:-$$}"

    if command -v flock >/dev/null 2>&1; then
        if [ -L "$OPERATION_LOCK_FILE" ] || \
           { [ -e "$OPERATION_LOCK_FILE" ] && [ ! -f "$OPERATION_LOCK_FILE" ]; }; then
            ui_error "运行锁类型异常，已停止操作"
            OPERATION_LOCK_OWNER_PID=""
            return 1
        fi
        if ! { exec 9>>"$OPERATION_LOCK_FILE"; } 2>/dev/null; then
            ui_error "无法打开运行锁，已停止操作"
            OPERATION_LOCK_OWNER_PID=""
            return 1
        fi
        if ! flock -n 9; then
            exec 9>&-
            OPERATION_LOCK_OWNER_PID=""
            ui_warn "另一项调优或恢复任务正在运行，请稍后重试"
            return 1
        fi
        OPERATION_LOCK_METHOD="flock"
        OPERATION_LOCK_HELD=1
        return 0
    fi

    if mkdir "$OPERATION_LOCK_DIR" 2>/dev/null; then
        if ! (umask 077; printf '%s\n' "$OPERATION_LOCK_OWNER_PID" > "$OPERATION_LOCK_DIR/pid"); then
            rm -f -- "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true
            rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
            OPERATION_LOCK_OWNER_PID=""
            ui_error "无法写入运行锁，已停止操作"
            return 1
        fi
        OPERATION_LOCK_METHOD="mkdir"
        OPERATION_LOCK_HELD=1
        return 0
    fi
    if [ -L "$OPERATION_LOCK_DIR" ] || [ ! -d "$OPERATION_LOCK_DIR" ] || \
       [ ! -f "$OPERATION_LOCK_DIR/pid" ] || [ -L "$OPERATION_LOCK_DIR/pid" ]; then
        ui_error "运行锁类型异常，已停止操作"
        OPERATION_LOCK_OWNER_PID=""
        return 1
    fi
    owner_pid=$(head -n 1 "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true)
    OPERATION_LOCK_OWNER_PID=""
    if [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        ui_warn "另一项调优或恢复任务正在运行，请稍后重试"
    else
        ui_warn "检测到上次任务异常中断；请重启系统后重试"
    fi
    return 1
}

release_operation_lock() {
    local recorded_pid=""

    [ "${OPERATION_LOCK_HELD:-0}" -eq 1 ] || return 0
    if [ "${BASHPID:-$$}" != "$OPERATION_LOCK_OWNER_PID" ]; then
        return 0
    fi
    case "$OPERATION_LOCK_METHOD" in
        flock)
            flock -u 9 2>/dev/null || true
            exec 9>&-
            ;;
        mkdir)
            recorded_pid=$(head -n 1 "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true)
            if [ "$recorded_pid" = "$OPERATION_LOCK_OWNER_PID" ]; then
                rm -f -- "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true
                rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
            fi
            ;;
    esac
    OPERATION_LOCK_HELD=0
    OPERATION_LOCK_OWNER_PID=""
    OPERATION_LOCK_METHOD=""
}

run_locked_operation() {
    local operation="$1"
    local operation_rc

    acquire_operation_lock || return 1
    "$operation"
    operation_rc=$?
    release_operation_lock
    return "$operation_rc"
}

speedtest_marker_is_owned() {
    [ -f "$SPEEDTEST_TMP_MARKER" ] && [ ! -L "$SPEEDTEST_TMP_MARKER" ] && \
        [ "$(stat -c '%u' -- "$SPEEDTEST_TMP_MARKER" 2>/dev/null)" = "$EUID" ]
}

cleanup_runtime_artifacts() {
    local temp_dir=""
    local temp_file=""
    local managed_speedtest=0

    if speedtest_marker_is_owned; then
        managed_speedtest=1
        temp_dir=$(head -n 1 "$SPEEDTEST_TMP_MARKER" 2>/dev/null)
        if [[ "$temp_dir" =~ ^/tmp/bbr-speedtest\.[A-Za-z0-9]{6}$ ]] && \
           [ -d "$temp_dir" ] && [ ! -L "$temp_dir" ] && \
           [ "$(stat -c '%u' -- "$temp_dir" 2>/dev/null)" = "$EUID" ]; then
            rm -rf -- "$temp_dir" 2>/dev/null || true
        fi
        rm -f "$SPEEDTEST_TMP_MARKER" 2>/dev/null || true
    fi

    if [ "$managed_speedtest" -eq 1 ] && [ "$SPEEDTEST_CONFIG_EXISTED" -eq 0 ]; then
        rm -f "$SPEEDTEST_CONFIG_FILE" 2>/dev/null || true
        rmdir "$(dirname "$SPEEDTEST_CONFIG_FILE")" 2>/dev/null || true
    fi

    for temp_file in "${MANAGED_TEMP_FILES[@]}"; do
        [ -n "$temp_file" ] && rm -f -- "$temp_file" 2>/dev/null || true
    done
}

cleanup_test_tools_after_tuning() {
    local speedtest_installed=0
    speedtest_marker_is_owned && speedtest_installed=1
    cleanup_runtime_artifacts
    [ "$speedtest_installed" -eq 0 ] || ui_info "测速完成，已清理脚本本次准备的测速工具与临时文件"
}

cleanup_on_exit() {
    cleanup_runtime_artifacts
    release_operation_lock
}

trap cleanup_on_exit EXIT

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: ${gl_bai}此脚本需要 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

break_end() {
    [ "$AUTO_MODE" = "1" ] && return
    echo ""
    ui_info "按任意键返回主菜单"
    read -n 1 -s -r -p ""
    echo ""
}

ensure_sysctl_snapshot_key() {
    local key="$1"
    local snapshot_mode="legacy"
    local value

    [ -s "$SNAPSHOT_MODE" ] && snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || echo "legacy")
    [ "$snapshot_mode" = "fresh" ] || return 0
    grep -qF "${key}=" "$SYSCTL_STATE" 2>/dev/null && return 0
    value=$(sysctl -n "$key" 2>/dev/null) || return 1
    printf '%s=%s\n' "$key" "$value" >> "$SYSCTL_STATE" || return 1
    chmod 600 "$SYSCTL_STATE" 2>/dev/null || true
}

validate_snapshot_structure() {
    local snapshot_mode state_file

    [ -e "$SNAPSHOT_READY" ] || [ -L "$SNAPSHOT_READY" ] || return 0
    if [ ! -f "$SNAPSHOT_READY" ] || [ -L "$SNAPSHOT_READY" ] || [ ! -s "$SNAPSHOT_MODE" ] || \
       [ ! -f "$CONFLICT_STATE" ] || [ -L "$CONFLICT_STATE" ] || \
       [ ! -s "$OPENRC_LOCAL_STATE" ] || [ -L "$OPENRC_LOCAL_STATE" ] || \
       ! grep -Eq '^[01]$' "$OPENRC_LOCAL_STATE" 2>/dev/null; then
        ui_error "恢复快照不完整，已停止操作以避免失去还原能力"
        return 1
    fi
    snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || true)
    case "$snapshot_mode" in
        fresh)
            for state_file in "$SYSCTL_STATE" "$QDISC_STATE" "$ROUTE_STATE"; do
                if [ ! -s "$state_file" ] || [ -L "$state_file" ]; then
                    ui_error "恢复快照不完整，已停止操作以避免失去还原能力"
                    return 1
                fi
            done
            if [ -e "$MQ_STATE" ] && ! mq_state_file_is_valid; then
                ui_error "mq 恢复快照无效，已停止操作"
                return 1
            fi
            if [ -e "$FQ_CODEL_STATE" ] && ! fq_codel_state_file_is_valid; then
                ui_error "fq_codel 恢复快照无效，已停止操作"
                return 1
            fi
            ;;
        legacy) ;;
        *)
            ui_error "恢复快照状态无效，已停止操作"
            return 1
            ;;
    esac
}

cleanup_uncommitted_network_snapshot() {
    local sysctl_conf_path=""
    local openrc_local_default=""
    local path
    local network_state_files=(
        "$SYSCTL_STATE" "$QDISC_STATE" "$MQ_STATE" "$FQ_CODEL_STATE" "$RPS_STATE" "$ROUTE_STATE" "$THP_STATE"
        "$PROFILE_STATE" "$CONFLICT_STATE" "$SYSCTL_CONFLICT_PATH_STATE" "$SNAPSHOT_MODE" "$OPENRC_OTHER_START_STATE"
        "$INIT_WINDOW_MARKER"
        "$STATE_DIR/sysctl.conf.before" "$STATE_DIR/sysctl.conf.absent"
    )

    [ ! -e "$SNAPSHOT_READY" ] && [ ! -L "$SNAPSHOT_READY" ] || return 1

    # 旧进程可能在提交快照标记前中断；先恢复已记录的冲突文件，再丢弃未提交状态。
    if [ -s "$CONFLICT_STATE" ] && ! restore_disabled_sysctl_files >/dev/null 2>&1; then
        ui_error "未提交的冲突恢复记录无法安全清理"
        return 1
    fi
    if [ -s "$SYSCTL_CONFLICT_PATH_STATE" ]; then
        sysctl_conf_path=$(cat "$SYSCTL_CONFLICT_PATH_STATE" 2>/dev/null || true)
        case "$sysctl_conf_path" in
            /etc/*) ;;
            *)
                ui_error "未提交的 sysctl 恢复记录无效"
                return 1
                ;;
        esac
        case "$sysctl_conf_path" in *$'\n'*|*$'\r'*) return 1 ;; esac
        if [ -e "$sysctl_conf_path" ] || [ -L "$sysctl_conf_path" ]; then
            if [ ! -f "$sysctl_conf_path" ] || [ -L "$sysctl_conf_path" ]; then
                ui_error "未提交的 sysctl 冲突标记无法安全恢复"
                return 1
            fi
            if grep -q '^# bbr-direct-tune disabled: ' "$sysctl_conf_path" 2>/dev/null && \
               ! sed -i 's/^# bbr-direct-tune disabled: //' "$sysctl_conf_path" 2>/dev/null; then
                ui_error "未提交的 sysctl 冲突标记无法安全恢复"
                return 1
            fi
        fi
    fi
    for path in "${network_state_files[@]}"; do
        rm -f -- "$path" 2>/dev/null || return 1
    done
    # OpenRC 注册态同时供 Swap 使用；有效 Swap 事务存在时从其原始快照恢复该值。
    if [ -f "$SWAP_SNAPSHOT_READY" ]; then
        if [ ! -s "$OPENRC_LOCAL_STATE" ]; then
            openrc_local_default=$(awk -F= '$1 == "openrc_local_default" {print $2}' "$SWAP_STATE" 2>/dev/null)
            case "$openrc_local_default" in 0|1) ;; *) return 1 ;; esac
            printf '%s\n' "$openrc_local_default" > "$OPENRC_LOCAL_STATE" || return 1
            chmod 600 "$OPENRC_LOCAL_STATE" 2>/dev/null || return 1
        fi
    else
        rm -f -- "$OPENRC_LOCAL_STATE" 2>/dev/null || return 1
    fi
}

snapshot_network_ownership_state() {
    local dev qdisc_line qdisc_kind current_route clean_route route_identity initcwnd initrwnd

    : > "$QDISC_STATE" || return 1
    printf '%s\n' "# qdisc-state-v2" >> "$QDISC_STATE" || return 1
    printf '%s\n' "# mq-state-v2" > "$MQ_STATE" || return 1
    printf '%s\n' "# fq-codel-state-v1" > "$FQ_CODEL_STATE" || return 1
    if command -v tc >/dev/null 2>&1; then
        for dev in $(eligible_ifaces); do
            qdisc_line=$(tc qdisc show dev "$dev" root 2>/dev/null) || return 1
            qdisc_kind=$(awk 'NR==1 {print $2}' <<< "$qdisc_line")
            printf '%s|%s\n' "$dev" "${qdisc_kind:-none}" >> "$QDISC_STATE" || return 1
            if [ "$qdisc_kind" = "mq" ] && ! save_mq_snapshot_for_iface "$dev"; then
                return 1
            fi
            if [ "$qdisc_kind" = "fq_codel" ] && ! save_fq_codel_snapshot_for_iface "$dev"; then
                # 未知扩展参数不能安全重放；保留类型快照，restore 将按已验证信息处理。
                ui_warn "网卡 $dev 的 fq_codel 参数无法完整保存，恢复时将采用保守处理"
            fi
        done
    fi

    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    route_identity=$(default_route_identity "$clean_route" 2>/dev/null || true)
    printf 'initcwnd=%s\ninitrwnd=%s\nroute_identity=%s\nroute=%s\n' \
        "$initcwnd" "$initrwnd" "$route_identity" "$clean_route" > "$ROUTE_STATE" || return 1
    chown 0:0 "$QDISC_STATE" "$MQ_STATE" "$FQ_CODEL_STATE" "$ROUTE_STATE" 2>/dev/null || return 1
    chmod 600 "$QDISC_STATE" "$MQ_STATE" "$FQ_CODEL_STATE" "$ROUTE_STATE" 2>/dev/null || return 1
}

snapshot_initial_state() {
    local key value snapshot_mode state_file ready_tmp

    validate_state_file_paths || return 1
    if [ -e "$SNAPSHOT_READY" ] || [ -L "$SNAPSHOT_READY" ]; then
        validate_snapshot_structure || return 1
        if [ ! -s "$OPENRC_OTHER_START_STATE" ]; then
            snapshot_openrc_local_state || return 1
        fi
        snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || true)
        if [ "$snapshot_mode" = "legacy" ] && \
           { [ ! -s "$QDISC_STATE" ] || [ ! -s "$ROUTE_STATE" ]; }; then
            snapshot_network_ownership_state || return 1
        fi
        ensure_mq_snapshot_state || return 1
        return 0
    fi
    if ! mkdir -p "$STATE_DIR" || ! chmod 700 "$STATE_DIR"; then
        ui_error "无法创建恢复快照目录 $STATE_DIR"
        return 1
    fi
    for state_file in "$SNAPSHOT_MODE" "$CONFLICT_STATE" "$SYSCTL_STATE" "$QDISC_STATE" "$MQ_STATE" "$FQ_CODEL_STATE" \
        "$ROUTE_STATE" "$SYSCTL_CONFLICT_PATH_STATE" "$OPENRC_LOCAL_STATE" "$OPENRC_OTHER_START_STATE" "$INIT_WINDOW_MARKER"; do
        if ! managed_output_path_is_safe "$state_file"; then
            ui_error "恢复快照文件类型异常，已停止应用"
            return 1
        fi
    done
    if ! cleanup_uncommitted_network_snapshot; then
        ui_error "未提交的恢复状态清理失败，已停止应用"
        return 1
    fi
    if ! snapshot_openrc_local_state; then
        ui_error "无法保存 OpenRC local 服务原始注册状态"
        return 1
    fi

    touch "$CONFLICT_STATE" || return 1
    if [ -f "$SYSCTL_CONF" ] || [ -f "$PERSIST_SCRIPT" ] || [ -f "$SYSTEMD_SERVICE" ] || \
       [ -f "$OPENRC_START" ] || [ -f "$SYSV_SERVICE" ] || [ -f "$MODULES_CONF" ]; then
        printf '%s\n' "legacy" > "$SNAPSHOT_MODE" || return 1
        snapshot_network_ownership_state || return 1
        chmod 600 "$SNAPSHOT_MODE" "$CONFLICT_STATE" "$OPENRC_LOCAL_STATE" "$OPENRC_OTHER_START_STATE" 2>/dev/null || return 1
        ready_tmp="${SNAPSHOT_READY}.tmp.$$"
        prepare_managed_temp_file "$ready_tmp" || return 1
        finalize_managed_temp_file "$ready_tmp" "$SNAPSHOT_READY" 600 || return 1
        ui_warn "检测到旧版调优痕迹：没有执行前快照，恢复时将采用安全兼容模式"
        return 0
    fi

    printf '%s\n' "fresh" > "$SNAPSHOT_MODE" || return 1
    : > "$CONFLICT_STATE" || return 1
    : > "$SYSCTL_STATE" || return 1
    for key in "${TUNED_SYSCTL_KEYS[@]}"; do
        sysctl_key_is_managed "$key" || continue
        if ! value=$(sysctl -n "$key" 2>/dev/null); then
            ui_error "无法读取必要的调优前状态，已停止应用"
            return 1
        fi
        printf '%s=%s\n' "$key" "$value" >> "$SYSCTL_STATE" || return 1
    done

    snapshot_network_ownership_state || return 1

    if [ -f /etc/sysctl.conf ]; then
        rm -f -- "$STATE_DIR/sysctl.conf.absent" 2>/dev/null || return 1
        cp -p /etc/sysctl.conf "$STATE_DIR/sysctl.conf.before" 2>/dev/null || return 1
    else
        rm -f -- "$STATE_DIR/sysctl.conf.before" 2>/dev/null || return 1
        touch "$STATE_DIR/sysctl.conf.absent" || return 1
    fi

    for state_file in "$SNAPSHOT_MODE" "$CONFLICT_STATE" "$SYSCTL_STATE" "$QDISC_STATE" "$MQ_STATE" "$FQ_CODEL_STATE" \
        "$ROUTE_STATE" "$OPENRC_LOCAL_STATE" "$OPENRC_OTHER_START_STATE" "$STATE_DIR/sysctl.conf.before" \
        "$STATE_DIR/sysctl.conf.absent"; do
        [ -e "$state_file" ] || continue
        [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
        chown 0:0 "$state_file" 2>/dev/null || return 1
        chmod 600 "$state_file" 2>/dev/null || return 1
    done
    ready_tmp="${SNAPSHOT_READY}.tmp.$$"
    prepare_managed_temp_file "$ready_tmp" || return 1
    finalize_managed_temp_file "$ready_tmp" "$SNAPSHOT_READY" 600 || return 1
    ui_success "已保存调优前状态，可从主菜单安全恢复"
}

cleanup_legacy_runtime_before_apply() {
    local snapshot_mode="legacy"
    local key setting restored_count=0 cleanup_failed=0
    local legacy_keys=(
        net.ipv4.tcp_keepalive_time
        net.ipv4.tcp_keepalive_intvl
        net.ipv4.tcp_keepalive_probes
        net.ipv4.tcp_tw_reuse
        net.ipv4.tcp_no_metrics_save
        net.ipv4.tcp_notsent_lowat
        net.ipv4.tcp_retries2
        net.ipv4.tcp_ecn
        vm.swappiness
        vm.dirty_ratio
        vm.dirty_background_ratio
        vm.overcommit_memory
        vm.min_free_kbytes
        vm.vfs_cache_pressure
        kernel.sched_autogroup_enabled
        kernel.numa_balancing
    )

    [ -s "$SNAPSHOT_MODE" ] && snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || echo "legacy")
    if [ "$snapshot_mode" = "fresh" ] && [ -s "$SYSCTL_STATE" ]; then
        for key in "${legacy_keys[@]}"; do
            setting=$(grep -F -m1 "${key}=" "$SYSCTL_STATE" 2>/dev/null) || continue
            if sysctl -w "$setting" >/dev/null 2>&1; then
                restored_count=$((restored_count + 1))
            else
                cleanup_failed=1
            fi
        done
        if [ -s "$RPS_STATE" ]; then
            if restore_rps_snapshot >/dev/null 2>&1; then
                rm -f -- "$RPS_STATE" 2>/dev/null || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        fi
        if [ -s "$THP_STATE" ]; then
            if restore_thp_snapshot >/dev/null 2>&1; then
                rm -f -- "$THP_STATE" 2>/dev/null || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        fi
        [ "$restored_count" -gt 0 ] && ui_success "已完成旧版运行状态清理"
    elif { [ -s "$SYSCTL_CONF" ] || [ -s "$PERSIST_SCRIPT" ]; } && \
         grep -qE '(vm\.|kernel\.numa_balancing|kernel\.sched_autogroup_enabled|tcp_keepalive|tcp_tw_reuse|tcp_no_metrics_save|tcp_notsent_lowat|tcp_retries2|tcp_ecn|transparent_hugepage|rps_cpus|rps_flow_cnt)' \
             "$SYSCTL_CONF" "$PERSIST_SCRIPT" 2>/dev/null; then
        ui_warn "检测到旧版额外 TCP/VM/THP/RPS 调优，但没有精确快照；本次不猜测原值"
        ui_info "新配置会停止持久化这些参数，建议应用后安排一次维护重启清除旧运行态"
    fi

    if [ -f /etc/security/limits.conf ] && grep -q "^# BBR - 文件描述符优化$" /etc/security/limits.conf 2>/dev/null; then
        if cp -p /etc/security/limits.conf "/etc/security/limits.conf.bak.bbr-upgrade.$(date +%Y%m%d_%H%M%S)" 2>/dev/null && \
           sed -i '/^# BBR - 文件描述符优化$/,+2d' /etc/security/limits.conf 2>/dev/null; then
            ui_success "已移除旧版脚本写入的全局文件描述符块"
        else
            ui_error "旧版配置清理未完成"
            cleanup_failed=1
        fi
    fi
    [ "$cleanup_failed" -eq 0 ]
}

swapfile_is_active() {
    awk -v swap_file="$SWAP_FILE" 'NR > 1 && $1 == swap_file {found=1} END {exit !found}' "$PROC_SWAPS_FILE" 2>/dev/null
}

swapfile_priority() {
    awk -v swap_file="$SWAP_FILE" 'NR > 1 && $1 == swap_file {print $5; exit}' "$PROC_SWAPS_FILE" 2>/dev/null
}

openrc_local_is_enabled() {
    [ -e "$OPENRC_LOCAL_DEFAULT_LINK" ] || [ -L "$OPENRC_LOCAL_DEFAULT_LINK" ]
}

openrc_other_start_files_exist() {
    local start_file

    for start_file in /etc/local.d/*.start; do
        [ -e "$start_file" ] || [ -L "$start_file" ] || continue
        case "$start_file" in
            "$OPENRC_START"|"$ALPINE_SWAP_START") continue ;;
            *) return 0 ;;
        esac
    done
    return 1
}

snapshot_openrc_local_state() {
    local enabled=0 other_start_present=0

    if [ -e "$OPENRC_LOCAL_STATE" ] || [ -L "$OPENRC_LOCAL_STATE" ]; then
        if [ ! -s "$OPENRC_LOCAL_STATE" ] || [ -L "$OPENRC_LOCAL_STATE" ] || \
           ! grep -Eq '^[01]$' "$OPENRC_LOCAL_STATE" 2>/dev/null; then
            return 1
        fi
    else
        openrc_local_is_enabled && enabled=1
        printf '%s\n' "$enabled" > "$OPENRC_LOCAL_STATE" || return 1
        chmod 600 "$OPENRC_LOCAL_STATE" 2>/dev/null || return 1
    fi

    if [ -e "$OPENRC_OTHER_START_STATE" ] || [ -L "$OPENRC_OTHER_START_STATE" ]; then
        [ -s "$OPENRC_OTHER_START_STATE" ] && [ ! -L "$OPENRC_OTHER_START_STATE" ] && \
            grep -Eq '^[01]$' "$OPENRC_OTHER_START_STATE" 2>/dev/null
        return
    fi
    openrc_other_start_files_exist && other_start_present=1
    printf '%s\n' "$other_start_present" > "$OPENRC_OTHER_START_STATE" || return 1
    chmod 600 "$OPENRC_OTHER_START_STATE" 2>/dev/null || return 1
}

restore_openrc_local_state() {
    local original_state="${1:-}" other_start_before="${2:-}" current_state=0

    if [ -z "$original_state" ]; then
        if [ -s "$OPENRC_LOCAL_STATE" ]; then
            original_state=$(head -n 1 "$OPENRC_LOCAL_STATE" 2>/dev/null || true)
        elif [ -s "$SWAP_STATE" ]; then
            original_state=$(awk -F= '$1 == "openrc_local_default" {print $2}' "$SWAP_STATE")
        fi
    fi
    case "$original_state" in
        0|1) ;;
        *) return 0 ;;
    esac
    if [ -z "$other_start_before" ] && [ -s "$OPENRC_OTHER_START_STATE" ]; then
        other_start_before=$(head -n 1 "$OPENRC_OTHER_START_STATE" 2>/dev/null || true)
    fi
    case "$other_start_before" in 0|1) ;; *) other_start_before="" ;; esac

    openrc_local_is_enabled && current_state=1
    [ "$current_state" = "$original_state" ] && return 0
    if ! command -v rc-update >/dev/null 2>&1; then
        ui_warn "缺少 rc-update，无法恢复 OpenRC local 服务原始注册状态"
        return 1
    fi
    if [ "$original_state" = "1" ]; then
        rc-update add local default >/dev/null 2>&1 || return 1
        openrc_local_is_enabled || return 1
    else
        # 应用前没有其他任务、之后新增时保留 local，避免禁用用户后续任务。
        if openrc_other_start_files_exist; then
            if [ "$other_start_before" = "0" ]; then
                return 0
            fi
            if [ -z "$other_start_before" ]; then
                ui_warn "旧版快照缺少 OpenRC 任务基线，已保留当前 local 注册状态"
                return 0
            fi
        fi
        rc-update del local default >/dev/null 2>&1 || return 1
        if openrc_local_is_enabled; then
            return 1
        fi
    fi
    return 0
}

swap_header_bytes() {
    local page_size

    page_size=$(getconf PAGESIZE 2>/dev/null || true)
    if ! [[ "$page_size" =~ ^[0-9]+$ ]] || [ "$page_size" -lt 4096 ] || [ "$page_size" -gt 1048576 ]; then
        page_size=4096
    fi
    echo "$page_size"
}

save_swap_header() {
    local source_file="$1"
    local target_file="$2"
    local header_bytes="$3"

    [ -f "$source_file" ] || return 1
    [[ "$header_bytes" =~ ^[0-9]+$ ]] && [ "$header_bytes" -gt 0 ] || return 1
    head -c "$header_bytes" "$source_file" > "$target_file"
}

swap_header_matches() {
    local current_file="$1"
    local saved_header="$2"
    local header_bytes="$3"

    [ -f "$current_file" ] && [ -s "$saved_header" ] || return 1
    [[ "$header_bytes" =~ ^[0-9]+$ ]] && [ "$header_bytes" -gt 0 ] || return 1
    [ "$(stat -c '%s' "$saved_header" 2>/dev/null)" = "$header_bytes" ] || return 1
    head -c "$header_bytes" "$current_file" 2>/dev/null | cmp - "$saved_header" >/dev/null 2>&1
}

alpine_swap_start_is_managed() {
    [ -f "$ALPINE_SWAP_START" ] && [ ! -L "$ALPINE_SWAP_START" ] || return 1
    printf 'swapon %s\n' "$SWAP_FILE" | cmp - "$ALPINE_SWAP_START" >/dev/null 2>&1
}

write_swap_managed_state() {
    local status="$1"
    local managed_uuid="$2"
    local managed_header_bytes="$3"
    local state_tmp="${SWAP_MANAGED_STATE}.tmp"

    case "$status" in
        changing|managed|restoring) ;;
        *) return 1 ;;
    esac
    [[ "$managed_header_bytes" =~ ^[0-9]+$ ]] || return 1
    if ! printf 'transaction_version=2\nstatus=%s\nmanaged_uuid=%s\nmanaged_header_bytes=%s\n' \
        "$status" "$managed_uuid" "$managed_header_bytes" > "$state_tmp" || \
       ! chmod 600 "$state_tmp" || ! mv -f "$state_tmp" "$SWAP_MANAGED_STATE"; then
        rm -f -- "$state_tmp"
        return 1
    fi
}

commit_swap_snapshot_ready() {
    local ready_tmp="${SWAP_SNAPSHOT_READY}.tmp.$$"

    if [ -e "$SWAP_SNAPSHOT_READY" ] || [ -L "$SWAP_SNAPSHOT_READY" ]; then
        [ -f "$SWAP_SNAPSHOT_READY" ] && [ ! -L "$SWAP_SNAPSHOT_READY" ]
        return
    fi
    prepare_managed_temp_file "$ready_tmp" || return 1
    finalize_managed_temp_file "$ready_tmp" "$SWAP_SNAPSHOT_READY" 600
}

create_swapfile_storage() {
    local size_bytes="$1"
    local filesystem_type

    [[ "$size_bytes" =~ ^[0-9]+$ ]] && [ "$size_bytes" -gt 0 ] || return 1
    : > "$SWAP_FILE" || return 1
    filesystem_type=$(stat -f -c '%T' "$(dirname "$SWAP_FILE")" 2>/dev/null || true)
    if [ "$filesystem_type" = "btrfs" ]; then
        command -v chattr >/dev/null 2>&1 || return 1
        chattr +C "$SWAP_FILE" 2>/dev/null || return 1
    fi
    if fallocate -l "$size_bytes" "$SWAP_FILE" 2>/dev/null; then
        return 0
    fi
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$(( (size_bytes + 1048575) / 1048576 )) >/dev/null 2>&1 || return 1
    truncate -s "$size_bytes" "$SWAP_FILE"
}

snapshot_swap_state() {
    local allow_rebaseline="${1:-0}"
    local existed=0 active=0 size_bytes=0 mode="" uid="" gid="" priority="" swap_type="" swap_uuid="" swap_label="" header_bytes=0
    local swappiness=""
    local managed_status managed_uuid managed_header_bytes transaction_version current_uuid current_type openrc_local_default=0 openrc_other_start=0
    local existed_snapshot active_snapshot size_snapshot header_bytes_snapshot openrc_snapshot
    local fstab_markers=0 alpine_markers=0 state_file live_path

    case "$allow_rebaseline" in 0|1) ;; *) allow_rebaseline=0 ;; esac

    validate_state_file_paths || return 1
    if [ ! -e "$SWAP_SNAPSHOT_READY" ] && [ ! -L "$SWAP_SNAPSHOT_READY" ] && \
       [ -s "$SWAP_MANAGED_STATE" ]; then
        managed_status=$(awk -F= '$1 == "status" {print $2}' "$SWAP_MANAGED_STATE")
        transaction_version=$(awk -F= '$1 == "transaction_version" {print $2}' "$SWAP_MANAGED_STATE")
        managed_uuid=$(awk -F= '$1 == "managed_uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_MANAGED_STATE")
        managed_header_bytes=$(awk -F= '$1 == "managed_header_bytes" {print $2}' "$SWAP_MANAGED_STATE")
        if [ "$managed_status" = "changing" ] && [ "$transaction_version" = "2" ] && \
           [ -z "$managed_uuid" ] && [ "$managed_header_bytes" = "0" ]; then
            cleanup_swap_snapshot_files || return 1
        else
            ui_error "Swap 事务状态不完整，已停止再次调整"
            return 1
        fi
    fi
    if [ -e "$SWAP_SNAPSHOT_READY" ] || [ -L "$SWAP_SNAPSHOT_READY" ]; then
        if [ ! -f "$SWAP_SNAPSHOT_READY" ] || [ -L "$SWAP_SNAPSHOT_READY" ]; then
            ui_error "Swap 快照标记异常，已停止再次调整"
            return 1
        fi
        if [ ! -s "$SWAP_STATE" ] || [ ! -s "$SWAP_MANAGED_STATE" ] || \
           [ ! -s "$SWAP_MANAGED_HEADER_STATE" ]; then
            ui_error "Swap 快照不完整，已停止再次调整"
            return 1
        fi
        existed_snapshot=$(awk -F= '$1 == "existed" {print $2}' "$SWAP_STATE")
        active_snapshot=$(awk -F= '$1 == "active" {print $2}' "$SWAP_STATE")
        size_snapshot=$(awk -F= '$1 == "size_bytes" {print $2}' "$SWAP_STATE")
        header_bytes_snapshot=$(awk -F= '$1 == "header_bytes" {print $2}' "$SWAP_STATE")
        openrc_snapshot=$(awk -F= '$1 == "openrc_local_default" {print $2}' "$SWAP_STATE")
        case "$existed_snapshot:$active_snapshot:$openrc_snapshot" in
            0:0:0|0:0:1|0:1:0|0:1:1|1:0:0|1:0:1|1:1:0|1:1:1) ;;
            *)
                ui_error "Swap 快照不完整，已停止再次调整"
                return 1
                ;;
        esac
        if { [ "$existed_snapshot" = "1" ] && [ ! -s "$SWAP_HEADER_STATE" ]; } || \
           { [ "$existed_snapshot" = "0" ] && [ ! -f "$SWAP_HEADER_STATE" ]; }; then
            ui_error "Swap 快照不完整，已停止再次调整"
            return 1
        fi
        if [ "$existed_snapshot" = "1" ] && \
           { ! [[ "$size_snapshot" =~ ^[0-9]+$ ]] || [ "$size_snapshot" -le 0 ] || \
             ! [[ "$header_bytes_snapshot" =~ ^[0-9]+$ ]] || [ "$header_bytes_snapshot" -le 0 ] || \
             [ "$(stat -c '%s' "$SWAP_HEADER_STATE" 2>/dev/null)" != "$header_bytes_snapshot" ]; }; then
            ui_error "Swap 快照不完整，已停止再次调整"
            return 1
        fi
        [ -f "$SWAP_FSTAB_STATE" ] && fstab_markers=$((fstab_markers + 1))
        [ -f "$SWAP_FSTAB_STATE.absent" ] && fstab_markers=$((fstab_markers + 1))
        [ -f "$SWAP_ALPINE_START_STATE" ] && alpine_markers=$((alpine_markers + 1))
        [ -f "$SWAP_ALPINE_START_STATE.absent" ] && alpine_markers=$((alpine_markers + 1))
        if [ "$fstab_markers" -ne 1 ] || [ "$alpine_markers" -ne 1 ]; then
            ui_error "Swap 快照不完整，已停止再次调整"
            return 1
        fi
        managed_status=$(awk -F= '$1 == "status" {print $2}' "$SWAP_MANAGED_STATE")
        managed_uuid=$(awk -F= '$1 == "managed_uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_MANAGED_STATE")
        managed_header_bytes=$(awk -F= '$1 == "managed_header_bytes" {print $2}' "$SWAP_MANAGED_STATE")
        current_uuid=$(blkid -s UUID -o value "$SWAP_FILE" 2>/dev/null || true)
        current_type=$(blkid -s TYPE -o value "$SWAP_FILE" 2>/dev/null || true)
        if [ "$managed_status" != "managed" ] || \
           [ "$current_type" != "swap" ] || \
           ! swap_header_matches "$SWAP_FILE" "$SWAP_MANAGED_HEADER_STATE" "$managed_header_bytes" || \
           { [ -n "$managed_uuid" ] && [ "$current_uuid" != "$managed_uuid" ]; }; then
            if [ "$allow_rebaseline" != "1" ]; then
                ui_error "$SWAP_FILE 已不再是本脚本管理的 Swap，已拒绝覆盖"
                return 1
            fi
            if ! command -v blkid >/dev/null 2>&1; then
                ui_error "缺少 blkid，无法安全重新建立 Swap 恢复基线"
                return 1
            fi
            if [ -e "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
                if [ ! -f "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ] || [ "$current_type" != "swap" ]; then
                    ui_error "$SWAP_FILE 不是可安全覆盖的普通 Swap 文件"
                    return 1
                fi
            fi
            for live_path in "$FSTAB_FILE" "$ALPINE_SWAP_START"; do
                [ -e "$live_path" ] || [ -L "$live_path" ] || continue
                if [ ! -f "$live_path" ] || [ -L "$live_path" ]; then
                    ui_error "$live_path 不是普通文件，无法重新建立 Swap 恢复基线"
                    return 1
                fi
            done
            ui_warn "旧 Swap 恢复基线与当前状态不一致，将以本次确认前的状态重新建立恢复保护"
            cleanup_swap_snapshot_files || {
                ui_error "旧 Swap 恢复状态清理失败，已停止覆盖"
                return 1
            }
        else
            return 0
        fi
    fi
    if ! command -v blkid >/dev/null 2>&1; then
        ui_error "缺少 blkid，无法安全识别和恢复 Swap"
        return 1
    fi
    if ! mkdir -p "$STATE_DIR" || ! chmod 700 "$STATE_DIR"; then
        ui_error "无法创建 Swap 快照目录 $STATE_DIR"
        return 1
    fi

    if [ -e "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
        if [ ! -f "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
            ui_error "$SWAP_FILE 不是普通文件，为避免数据丢失已拒绝覆盖"
            return 1
        fi
        swap_type=$(blkid -s TYPE -o value "$SWAP_FILE" 2>/dev/null || true)
        if [ "$swap_type" != "swap" ]; then
            ui_error "$SWAP_FILE 不是有效 Swap 文件，为避免数据丢失已拒绝覆盖"
            return 1
        fi
        existed=1
        size_bytes=$(stat -c '%s' "$SWAP_FILE" 2>/dev/null || true)
        mode=$(stat -c '%a' "$SWAP_FILE" 2>/dev/null || true)
        uid=$(stat -c '%u' "$SWAP_FILE" 2>/dev/null || true)
        gid=$(stat -c '%g' "$SWAP_FILE" 2>/dev/null || true)
        swap_uuid=$(blkid -s UUID -o value "$SWAP_FILE" 2>/dev/null || true)
        swap_label=$(blkid -s LABEL -o value "$SWAP_FILE" 2>/dev/null || true)
        header_bytes=$(swap_header_bytes)
        if ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -lt "$header_bytes" ]; then
            ui_error "$SWAP_FILE 大小小于有效 Swap 头部，已拒绝覆盖"
            return 1
        fi
        if ! save_swap_header "$SWAP_FILE" "$SWAP_HEADER_STATE" "$header_bytes"; then
            ui_error "无法保存原 Swap 头部，已停止调整"
            return 1
        fi
    else
        : > "$SWAP_HEADER_STATE" || return 1
    fi

    if swapfile_is_active; then
        active=1
        priority=$(swapfile_priority)
    fi

    if [ -e "$FSTAB_FILE" ] || [ -L "$FSTAB_FILE" ]; then
        if [ ! -f "$FSTAB_FILE" ] || [ -L "$FSTAB_FILE" ]; then
            ui_error "$FSTAB_FILE 不是普通文件，已停止调整"
            return 1
        fi
        rm -f -- "$SWAP_FSTAB_STATE.absent" || return 1
        cp -p "$FSTAB_FILE" "$SWAP_FSTAB_STATE" || {
            ui_error "无法保存 $FSTAB_FILE，已停止调整"
            return 1
        }
    else
        rm -f -- "$SWAP_FSTAB_STATE" || return 1
        : > "${SWAP_FSTAB_STATE}.absent" || return 1
    fi

    if [ -e "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; then
        if [ ! -f "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; then
            ui_error "$ALPINE_SWAP_START 不是普通文件，已停止调整"
            return 1
        fi
        rm -f -- "$SWAP_ALPINE_START_STATE.absent" || return 1
        cp -p "$ALPINE_SWAP_START" "$SWAP_ALPINE_START_STATE" || {
            ui_error "无法保存 $ALPINE_SWAP_START，已停止调整"
            return 1
        }
    else
        rm -f -- "$SWAP_ALPINE_START_STATE" || return 1
        : > "${SWAP_ALPINE_START_STATE}.absent" || return 1
    fi

    openrc_local_is_enabled && openrc_local_default=1
    openrc_other_start_files_exist && openrc_other_start=1
    swappiness=$(sysctl -n vm.swappiness 2>/dev/null || true)
    normalize_uint "$swappiness" 0 200 >/dev/null 2>&1 || swappiness=""
    printf 'existed=%s\nactive=%s\nsize_bytes=%s\nmode=%s\nuid=%s\ngid=%s\npriority=%s\nuuid=%s\nlabel=%s\nheader_bytes=%s\nopenrc_local_default=%s\nopenrc_other_start=%s\nswappiness=%s\n' \
        "$existed" "$active" "$size_bytes" "$mode" "$uid" "$gid" "$priority" "$swap_uuid" "$swap_label" "$header_bytes" \
        "$openrc_local_default" "$openrc_other_start" "$swappiness" > "$SWAP_STATE" || return 1
    # 原 fstab/OpenRC 启动文件的备份保留原权限；状态目录本身已是 0700。
    for state_file in "$SWAP_STATE" "$SWAP_HEADER_STATE" "$SWAP_FSTAB_STATE.absent" \
        "$SWAP_ALPINE_START_STATE.absent"; do
        [ -e "$state_file" ] || continue
        chmod 600 "$state_file" 2>/dev/null || return 1
    done
    return 0
}

restore_swap_state() {
    local existed active size_bytes mode uid gid priority swap_uuid swap_label header_bytes openrc_local_default openrc_other_start
    local swappiness=""
    local managed_status managed_uuid managed_header_bytes transaction_version current_uuid="" current_type="" current_size="" current_priority=""
    local file_state="absent" restore_failed=0 fstab_failed=0 alpine_failed=0
    local fstab_tmp="${FSTAB_FILE}.bbr-direct-tune.restore.tmp.$$"
    local fstab_input="/dev/null"
    local fstab_metadata_source="$FSTAB_FILE"

    SWAP_RESTORE_SWAPPINESS=""
    if [ -s "$SWAP_STATE" ]; then
        swappiness=$(awk -F= '$1 == "swappiness" {print $2}' "$SWAP_STATE")
        if normalize_uint "$swappiness" 0 200 >/dev/null 2>&1; then
            SWAP_RESTORE_SWAPPINESS="$swappiness"
        fi
    fi

    if [ ! -f "$SWAP_MANAGED_STATE" ]; then
        if [ -f "$SWAP_SNAPSHOT_READY" ]; then
            ui_warn "Swap 管理状态缺失，无法安全判断 $SWAP_FILE 的归属"
            ui_info "已保留当前 Swap 与启动配置；网络恢复和脚本残留清理将继续"
            return 2
        fi
        restore_openrc_local_state
        return $?
    fi
    if [ ! -f "$SWAP_SNAPSHOT_READY" ]; then
        managed_status=$(awk -F= '$1 == "status" {print $2}' "$SWAP_MANAGED_STATE")
        transaction_version=$(awk -F= '$1 == "transaction_version" {print $2}' "$SWAP_MANAGED_STATE")
        managed_uuid=$(awk -F= '$1 == "managed_uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_MANAGED_STATE")
        managed_header_bytes=$(awk -F= '$1 == "managed_header_bytes" {print $2}' "$SWAP_MANAGED_STATE")
        if [ "$managed_status" = "changing" ] && [ "$transaction_version" = "2" ] && \
           [ -z "$managed_uuid" ] && [ "$managed_header_bytes" = "0" ]; then
            if restore_openrc_local_state && cleanup_swap_snapshot_files; then
                ui_success "已清理未开始修改的 Swap 恢复状态"
                return 0
            fi
        fi
        ui_warn "Swap 事务状态不完整，恢复快照已保留"
        return 1
    fi
    if [ ! -s "$SWAP_STATE" ] || [ ! -f "$SWAP_SNAPSHOT_READY" ]; then
        ui_warn "缺少 Swap 快照，无法确认 $SWAP_FILE 是否由本脚本创建"
        return 1
    fi

    existed=$(awk -F= '$1 == "existed" {print $2}' "$SWAP_STATE")
    active=$(awk -F= '$1 == "active" {print $2}' "$SWAP_STATE")
    size_bytes=$(awk -F= '$1 == "size_bytes" {print $2}' "$SWAP_STATE")
    mode=$(awk -F= '$1 == "mode" {print $2}' "$SWAP_STATE")
    uid=$(awk -F= '$1 == "uid" {print $2}' "$SWAP_STATE")
    gid=$(awk -F= '$1 == "gid" {print $2}' "$SWAP_STATE")
    priority=$(awk -F= '$1 == "priority" {print $2}' "$SWAP_STATE")
    swap_uuid=$(awk -F= '$1 == "uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_STATE")
    swap_label=$(awk -F= '$1 == "label" {sub(/^[^=]*=/, ""); print}' "$SWAP_STATE")
    header_bytes=$(awk -F= '$1 == "header_bytes" {print $2}' "$SWAP_STATE")
    openrc_local_default=$(awk -F= '$1 == "openrc_local_default" {print $2}' "$SWAP_STATE")
    openrc_other_start=$(awk -F= '$1 == "openrc_other_start" {print $2}' "$SWAP_STATE")
    managed_status=$(awk -F= '$1 == "status" {print $2}' "$SWAP_MANAGED_STATE")
    managed_uuid=$(awk -F= '$1 == "managed_uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_MANAGED_STATE")
    managed_header_bytes=$(awk -F= '$1 == "managed_header_bytes" {print $2}' "$SWAP_MANAGED_STATE")

    case "$managed_status" in
        managed|changing|restoring) ;;
        *)
            ui_warn "Swap 所有权状态无效，已停止恢复"
            return 1
            ;;
    esac
    case "$existed:$active" in
        0:0|0:1|1:0|1:1) ;;
        *)
            ui_warn "原 Swap 状态快照无效，已停止恢复"
            return 1
            ;;
    esac
    if [ "$existed" = "1" ] && \
       { ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -le 0 ] || \
         ! [[ "$header_bytes" =~ ^[0-9]+$ ]] || [ "$header_bytes" -le 0 ] || [ ! -s "$SWAP_HEADER_STATE" ]; }; then
        ui_warn "原 Swap 文件快照不完整，已停止恢复"
        return 1
    fi

    if [ -e "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
        if [ ! -f "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
            ui_warn "$SWAP_FILE 已变成非普通文件，为避免误删已原样保留"
            ui_info "脚本将放弃 Swap 恢复管理；网络恢复和脚本残留清理将继续"
            return 2
        fi
        file_state="other"
        current_type=$(blkid -s TYPE -o value "$SWAP_FILE" 2>/dev/null || true)
        current_uuid=$(blkid -s UUID -o value "$SWAP_FILE" 2>/dev/null || true)
        current_size=$(stat -c '%s' "$SWAP_FILE" 2>/dev/null || true)
        if [ "$current_type" = "swap" ] && [[ "$managed_header_bytes" =~ ^[0-9]+$ ]] && \
           [ "$managed_header_bytes" -gt 0 ] && \
           swap_header_matches "$SWAP_FILE" "$SWAP_MANAGED_HEADER_STATE" "$managed_header_bytes" && \
           { [ -z "$managed_uuid" ] || [ "$current_uuid" = "$managed_uuid" ]; }; then
            file_state="managed"
        elif [ "$existed" = "1" ] && [ "$current_type" = "swap" ] && [ "$current_size" = "$size_bytes" ] && \
             swap_header_matches "$SWAP_FILE" "$SWAP_HEADER_STATE" "$header_bytes" && \
             { [ -z "$swap_uuid" ] || [ "$current_uuid" = "$swap_uuid" ]; }; then
            file_state="original"
        fi
    fi
    if [ "$file_state" = "other" ]; then
        ui_warn "$SWAP_FILE 已不再匹配脚本 Swap 或原 Swap，为避免覆盖用户修改已原样保留"
        ui_info "Swap 文件及相关启动配置不会被改动；网络恢复和脚本残留清理将继续"
        return 2
    fi
    if ! write_swap_managed_state "restoring" "$managed_uuid" "$managed_header_bytes"; then
        ui_warn "无法记录 Swap 恢复进度，未执行文件修改"
        return 1
    fi

    if [ "$file_state" = "managed" ]; then
        if swapfile_is_active && ! swapoff "$SWAP_FILE"; then
            ui_warn "无法停用 $SWAP_FILE；可能可用内存不足，已保留当前 Swap 与恢复快照"
            return 1
        fi
        if ! rm -f -- "$SWAP_FILE"; then
            ui_warn "无法删除脚本创建的 $SWAP_FILE，已保留恢复快照"
            return 1
        fi
        file_state="absent"
    elif [ "$file_state" = "absent" ] && swapfile_is_active; then
        if ! swapoff "$SWAP_FILE"; then
            ui_warn "无法停用已删除但仍激活的 $SWAP_FILE，已停止恢复"
            return 1
        fi
    fi

    if [ "$existed" = "1" ]; then
        if [ "$file_state" = "absent" ]; then
            if ! create_swapfile_storage "$size_bytes"; then
                rm -f -- "$SWAP_FILE"
                ui_warn "无法重建原 Swap 文件，已保留恢复快照"
                return 1
            fi
            if ! dd if="$SWAP_HEADER_STATE" of="$SWAP_FILE" bs="$header_bytes" count=1 conv=notrunc >/dev/null 2>&1; then
                rm -f -- "$SWAP_FILE"
                ui_warn "无法写回原 Swap 签名，已保留恢复快照"
                return 1
            fi
        fi

        if [ -n "$mode" ] && ! chmod "$mode" "$SWAP_FILE" 2>/dev/null; then
            ui_warn "未能恢复 $SWAP_FILE 的原权限"
            restore_failed=1
        fi
        if [ -n "$uid" ] && [ -n "$gid" ] && ! chown "$uid:$gid" "$SWAP_FILE" 2>/dev/null; then
            ui_warn "未能恢复 $SWAP_FILE 的原所有者"
            restore_failed=1
        fi
        current_type=$(blkid -s TYPE -o value "$SWAP_FILE" 2>/dev/null || true)
        current_uuid=$(blkid -s UUID -o value "$SWAP_FILE" 2>/dev/null || true)
        if [ "$current_type" != "swap" ] || \
           ! swap_header_matches "$SWAP_FILE" "$SWAP_HEADER_STATE" "$header_bytes" || \
           { [ -n "$swap_uuid" ] && [ "$current_uuid" != "$swap_uuid" ]; }; then
            ui_warn "原 Swap 签名未能恢复，已保留快照"
            return 1
        fi

        if [ "$active" = "1" ]; then
            if swapfile_is_active; then
                current_priority=$(swapfile_priority)
                if [ -n "$priority" ] && [ "$current_priority" != "$priority" ]; then
                    if ! swapoff "$SWAP_FILE"; then
                        ui_warn "无法按原优先级重新启用 $SWAP_FILE"
                        restore_failed=1
                    fi
                fi
            fi
            if ! swapfile_is_active; then
                if [[ "$priority" =~ ^[0-9]+$ ]]; then
                    swapon -p "$priority" "$SWAP_FILE" || restore_failed=1
                else
                    # 内核的默认负优先级不能作为 swapon -p 参数，交给内核重新分配。
                    swapon "$SWAP_FILE" || restore_failed=1
                fi
            fi
        elif swapfile_is_active && ! swapoff "$SWAP_FILE"; then
            ui_warn "未能恢复 $SWAP_FILE 的原停用状态"
            restore_failed=1
        fi
    fi

    if [ -e "$FSTAB_FILE" ] || [ -L "$FSTAB_FILE" ]; then
        if [ ! -f "$FSTAB_FILE" ] || [ -L "$FSTAB_FILE" ]; then
            fstab_failed=1
        else
            fstab_input="$FSTAB_FILE"
        fi
    elif [ -f "$SWAP_FSTAB_STATE" ]; then
        fstab_input="$SWAP_FSTAB_STATE"
        fstab_metadata_source="$SWAP_FSTAB_STATE"
    fi
    if [ "$fstab_failed" -eq 0 ] && ! prepare_managed_temp_file "$fstab_tmp"; then
        fstab_failed=1
    fi
    if [ "$fstab_failed" -eq 0 ]; then
        SWAPFILE_MANAGED_UUID="$managed_uuid"
        SWAPFILE_ORIGINAL_UUID="$swap_uuid"
        SWAPFILE_ORIGINAL_LABEL="$swap_label"
        export SWAPFILE_MANAGED_UUID SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL
        awk -v swap_file="$SWAP_FILE" '
            {
                source=$1
                target=$2
                type=$3
                if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ && \
                    (source == swap_file || target == swap_file || \
                     (ENVIRON["SWAPFILE_MANAGED_UUID"] != "" && source == "UUID=" ENVIRON["SWAPFILE_MANAGED_UUID"] && (target == "none" || type == "swap")) || \
                     (ENVIRON["SWAPFILE_ORIGINAL_UUID"] != "" && source == "UUID=" ENVIRON["SWAPFILE_ORIGINAL_UUID"] && (target == "none" || type == "swap")) || \
                     (ENVIRON["SWAPFILE_ORIGINAL_LABEL"] != "" && source == "LABEL=" ENVIRON["SWAPFILE_ORIGINAL_LABEL"] && (target == "none" || type == "swap")))) next
                print
            }
        ' "$fstab_input" > "$fstab_tmp" || fstab_failed=1
    fi
    if [ "$fstab_failed" -eq 0 ] && [ -f "$SWAP_FSTAB_STATE" ]; then
        awk -v swap_file="$SWAP_FILE" '
            {
                source=$1
                target=$2
                type=$3
                if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ && \
                    (source == swap_file || target == swap_file || \
                     (ENVIRON["SWAPFILE_ORIGINAL_UUID"] != "" && source == "UUID=" ENVIRON["SWAPFILE_ORIGINAL_UUID"] && (target == "none" || type == "swap")) || \
                     (ENVIRON["SWAPFILE_ORIGINAL_LABEL"] != "" && source == "LABEL=" ENVIRON["SWAPFILE_ORIGINAL_LABEL"] && (target == "none" || type == "swap")))) print
            }
        ' "$SWAP_FSTAB_STATE" >> "$fstab_tmp" || fstab_failed=1
    fi
    if [ "$fstab_failed" -eq 0 ]; then
        if [ -f "$SWAP_FSTAB_STATE.absent" ] && ! grep -q '[^[:space:]]' "$fstab_tmp"; then
            rm -f -- "$FSTAB_FILE" "$fstab_tmp" || fstab_failed=1
        elif ! atomic_replace_file_preserving_metadata "$fstab_tmp" "$FSTAB_FILE" "$fstab_metadata_source"; then
            fstab_failed=1
        fi
    fi
    unset SWAPFILE_MANAGED_UUID SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL
    if [ "$fstab_failed" -ne 0 ]; then
        rm -f -- "$fstab_tmp"
        ui_warn "未能完整恢复 $FSTAB_FILE 中的 Swap 配置"
        restore_failed=1
    fi

    if [ -f "$SWAP_ALPINE_START_STATE" ]; then
        if [ ! -e "$ALPINE_SWAP_START" ] && [ ! -L "$ALPINE_SWAP_START" ]; then
            ui_warn "Alpine Swap 启动文件已被后续删除，未自动重建"
            alpine_failed=1
        elif [ ! -f "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; then
            ui_warn "$ALPINE_SWAP_START 已变成非普通文件，为避免覆盖已保留"
            alpine_failed=1
        elif cmp -s "$ALPINE_SWAP_START" "$SWAP_ALPINE_START_STATE"; then
            :
        elif alpine_swap_start_is_managed; then
            if ! mkdir -p "$(dirname "$ALPINE_SWAP_START")" || \
               ! cp -p "$SWAP_ALPINE_START_STATE" "$ALPINE_SWAP_START"; then
                alpine_failed=1
            fi
        else
            ui_warn "Alpine Swap 启动文件已被后续修改，未自动覆盖"
            alpine_failed=1
        fi
    elif [ -f "$SWAP_ALPINE_START_STATE.absent" ]; then
        if [ ! -e "$ALPINE_SWAP_START" ] && [ ! -L "$ALPINE_SWAP_START" ]; then
            :
        elif [ ! -f "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; then
            ui_warn "$ALPINE_SWAP_START 已变成非普通文件，为避免误删已保留"
            alpine_failed=1
        elif alpine_swap_start_is_managed; then
            rm -f -- "$ALPINE_SWAP_START" || alpine_failed=1
        else
            ui_warn "Alpine Swap 启动文件已被后续修改，未自动删除"
            alpine_failed=1
        fi
    fi
    if [ "$alpine_failed" -ne 0 ]; then
        ui_warn "未能恢复 Alpine Swap 启动文件"
        restore_failed=1
    elif ! restore_openrc_local_state "$openrc_local_default" "$openrc_other_start"; then
        ui_warn "未能恢复 OpenRC local 服务原始注册状态"
        restore_failed=1
    fi

    if [ "$restore_failed" -eq 0 ]; then
        ui_success "已恢复脚本调整前的 Swap、fstab 与启动配置"
        return 0
    fi
    ui_warn "Swap 部分状态未能完整恢复"
    return 1
}

cleanup_swap_snapshot_files() {
    local cleanup_failed=0

    rm -f -- "$SWAP_STATE" "$SWAP_HEADER_STATE" "$SWAP_MANAGED_HEADER_STATE" "$SWAP_FSTAB_STATE" "$SWAP_FSTAB_STATE.absent" \
        "$SWAP_ALPINE_START_STATE" "$SWAP_ALPINE_START_STATE.absent" "$SWAP_SNAPSHOT_READY" "$SWAP_MANAGED_STATE" \
        "${SWAP_MANAGED_STATE}.tmp" "${SWAP_MANAGED_HEADER_STATE}.new" "${FSTAB_FILE}.bbr-direct-tune.tmp" || cleanup_failed=1
    rm -f -- "${FSTAB_FILE}.bbr-direct-tune.apply.tmp."* "${FSTAB_FILE}.bbr-direct-tune.restore.tmp."* \
        "${ALPINE_SWAP_START}.bbr-direct-tune.tmp."* 2>/dev/null || true
    [ "$cleanup_failed" -eq 0 ]
}

rollback_swap_change() {
    rm -f -- "${SWAP_MANAGED_STATE}.tmp" "${SWAP_MANAGED_HEADER_STATE}.new" "${FSTAB_FILE}.bbr-direct-tune.tmp" \
        "${FSTAB_FILE}.bbr-direct-tune.apply.tmp."* "${FSTAB_FILE}.bbr-direct-tune.restore.tmp."* \
        "${ALPINE_SWAP_START}.bbr-direct-tune.tmp."* 2>/dev/null || true
    if restore_swap_state; then
        if cleanup_swap_snapshot_files; then
            ui_success "Swap 调整失败，已恢复原状态"
            return 0
        fi
        ui_warn "Swap 已恢复，但临时恢复状态未能清理"
        return 1
    fi
    ui_error "Swap 调整失败且自动回滚未完成，已保留快照供卸载重试"
    return 1
}

add_swap() {
    local new_swap=$1
    local allow_rebaseline="${2:-0}"
    local normalized_swap
    local dev_swap_list previous_managed=0 previous_managed_uuid="" previous_managed_header_bytes=0
    local new_managed_uuid new_managed_header_bytes original_swap_uuid original_swap_label
    local managed_header_tmp="${SWAP_MANAGED_HEADER_STATE}.new"
    local fstab_tmp="${FSTAB_FILE}.bbr-direct-tune.apply.tmp.$$"
    local fstab_input="/dev/null"
    local alpine_start_tmp="${ALPINE_SWAP_START}.bbr-direct-tune.tmp.$$"

    if ! normalized_swap=$(normalize_uint "$new_swap" 1 4096); then
        ui_error "Swap 大小必须是 1 到 4096 之间的整数 MB"
        return 1
    fi
    new_swap="$normalized_swap"

    ui_section "调整虚拟内存"

    if ! [[ "$new_swap" =~ ^[0-9]+$ ]] || [ "$new_swap" -le 0 ]; then
        ui_error "Swap 大小必须是正整数 MB"
        return 1
    fi

    dev_swap_list=$(awk 'NR>1 && $1 ~ /^\/dev\// {printf "  • %s (大小: %d MB, 已用: %d MB)\n", $1, int(($3+512)/1024), int(($4+512)/1024)}' "$PROC_SWAPS_FILE")
    if [ -n "$dev_swap_list" ]; then
        ui_info "检测到其他虚拟内存分区，本脚本不会修改"
    fi

    ui_warn "即将重建脚本管理的虚拟内存并更新开机配置；restore 时恢复原状态"
    echo ""

    if ! snapshot_swap_state "$allow_rebaseline"; then
        return 1
    fi
    if [ -s "$SWAP_MANAGED_STATE" ]; then
        previous_managed_uuid=$(awk -F= '$1 == "managed_uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_MANAGED_STATE")
        previous_managed_header_bytes=$(awk -F= '$1 == "managed_header_bytes" {print $2}' "$SWAP_MANAGED_STATE")
        [ "$(awk -F= '$1 == "status" {print $2}' "$SWAP_MANAGED_STATE")" = "managed" ] && previous_managed=1
    fi
    if ! write_swap_managed_state "changing" "$previous_managed_uuid" "$previous_managed_header_bytes"; then
        ui_error "无法记录 Swap 调整状态，未执行重建"
        [ "$previous_managed" -eq 0 ] && cleanup_swap_snapshot_files
        return 1
    fi
    if ! commit_swap_snapshot_ready; then
        ui_error "无法提交 Swap 恢复快照，未执行重建"
        [ "$previous_managed" -eq 0 ] && cleanup_swap_snapshot_files
        return 1
    fi
    if swapfile_is_active && ! swapoff "$SWAP_FILE"; then
        ui_error "无法停用 $SWAP_FILE；可能可用内存不足，未执行任何重建"
        if [ "$previous_managed" -eq 1 ]; then
            write_swap_managed_state "managed" "$previous_managed_uuid" "$previous_managed_header_bytes" || \
                ui_warn "未能还原 Swap 管理状态文件；恢复快照已保留"
        else
            cleanup_swap_snapshot_files
        fi
        return 1
    fi
    if { [ -e "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; } && \
       { [ ! -f "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; }; then
        ui_error "$SWAP_FILE 不是普通文件，已停止调整"
        rollback_swap_change
        return 1
    fi
    rm -f -- "$SWAP_FILE" || {
        rollback_swap_change
        return 1
    }

    echo "正在配置虚拟内存..."
    if ! create_swapfile_storage $((new_swap * 1024 * 1024)); then
        rm -f -- "$SWAP_FILE"
        rollback_swap_change
        return 1
    fi
    if ! chmod 600 "$SWAP_FILE" || ! mkswap "$SWAP_FILE" >/dev/null 2>&1; then
        rm -f -- "$SWAP_FILE"
        rollback_swap_change
        return 1
    fi

    new_managed_uuid=$(blkid -s UUID -o value "$SWAP_FILE" 2>/dev/null || true)
    new_managed_header_bytes=$(swap_header_bytes)
    rm -f -- "$managed_header_tmp"
    if ! save_swap_header "$SWAP_FILE" "$managed_header_tmp" "$new_managed_header_bytes" || \
       ! chmod 600 "$managed_header_tmp"; then
        ui_error "无法保存新 Swap 签名，正在回滚原状态"
        rm -f -- "$managed_header_tmp"
        rm -f -- "$SWAP_FILE"
        rollback_swap_change
        return 1
    fi
    if ! mv -f "$managed_header_tmp" "$SWAP_MANAGED_HEADER_STATE" || \
       ! write_swap_managed_state "managed" "$new_managed_uuid" "$new_managed_header_bytes"; then
        ui_error "无法写入新 Swap 管理状态，正在回滚原状态"
        rm -f -- "$managed_header_tmp" "$SWAP_FILE"
        rollback_swap_change
        return 1
    fi
    if ! swapon "$SWAP_FILE"; then
        rollback_swap_change
        return 1
    fi

    if [ -e "$FSTAB_FILE" ] || [ -L "$FSTAB_FILE" ]; then
        if [ ! -f "$FSTAB_FILE" ] || [ -L "$FSTAB_FILE" ]; then
            rollback_swap_change
            return 1
        fi
        fstab_input="$FSTAB_FILE"
    fi
    original_swap_uuid=$(awk -F= '$1 == "uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_STATE")
    original_swap_label=$(awk -F= '$1 == "label" {sub(/^[^=]*=/, ""); print}' "$SWAP_STATE")
    SWAPFILE_ORIGINAL_UUID="$original_swap_uuid"
    SWAPFILE_ORIGINAL_LABEL="$original_swap_label"
    SWAPFILE_PREVIOUS_UUID="$previous_managed_uuid"
    SWAPFILE_MANAGED_UUID="$new_managed_uuid"
    export SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
    if ! prepare_managed_temp_file "$fstab_tmp"; then
        unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
        rollback_swap_change
        return 1
    fi
    awk -v swap_file="$SWAP_FILE" '
        {
            source=$1
            target=$2
            type=$3
            if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ && \
                (source == swap_file || target == swap_file || \
                 (ENVIRON["SWAPFILE_ORIGINAL_UUID"] != "" && source == "UUID=" ENVIRON["SWAPFILE_ORIGINAL_UUID"] && (target == "none" || type == "swap")) || \
                 (ENVIRON["SWAPFILE_ORIGINAL_LABEL"] != "" && source == "LABEL=" ENVIRON["SWAPFILE_ORIGINAL_LABEL"] && (target == "none" || type == "swap")) || \
                 (ENVIRON["SWAPFILE_PREVIOUS_UUID"] != "" && source == "UUID=" ENVIRON["SWAPFILE_PREVIOUS_UUID"] && (target == "none" || type == "swap")) || \
                 (ENVIRON["SWAPFILE_MANAGED_UUID"] != "" && source == "UUID=" ENVIRON["SWAPFILE_MANAGED_UUID"] && (target == "none" || type == "swap")))) next
            print
        }
    ' "$fstab_input" > "$fstab_tmp" || {
        unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
        rm -f -- "$fstab_tmp"
        rollback_swap_change
        return 1
    }
    if ! printf '%s swap swap defaults 0 0\n' "$SWAP_FILE" >> "$fstab_tmp" || \
       ! atomic_replace_file_preserving_metadata "$fstab_tmp" "$FSTAB_FILE"; then
        unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
        rm -f -- "$fstab_tmp"
        rollback_swap_change
        return 1
    fi
    unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID

    if [ -f "$ALPINE_RELEASE_FILE" ]; then
        if ! mkdir -p "$(dirname "$ALPINE_SWAP_START")" || \
           ! prepare_managed_temp_file "$alpine_start_tmp" || \
           ! printf 'swapon %s\n' "$SWAP_FILE" > "$alpine_start_tmp" || \
           ! finalize_managed_temp_file "$alpine_start_tmp" "$ALPINE_SWAP_START" 755; then
            rollback_swap_change
            return 1
        fi
        if ! openrc_local_is_enabled; then
            if openrc_other_start_files_exist || \
               ! command -v rc-update >/dev/null 2>&1 || \
               ! rc-update add local default >/dev/null 2>&1 || ! openrc_local_is_enabled; then
                ui_error "无法安全启用 OpenRC local 服务，正在回滚 Swap 调整"
                rollback_swap_change
                return 1
            fi
        fi
    fi

    ui_success "虚拟内存配置完成"
    return 0
}

is_ookla_speedtest() {
    local candidate="$1" version_output

    [ -x "$candidate" ] || return 1
    version_output=$("$candidate" --version 2>&1)
    grep -qi "Speedtest by Ookla" <<< "$version_output"
}

run_speedtest() {
    [ -n "$SPEEDTEST_BIN" ] && [ -x "$SPEEDTEST_BIN" ] || return 127
    "$SPEEDTEST_BIN" --accept-license --accept-gdpr "$@"
}

calculate_sha256() {
    local file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        return 1
    fi
}

ensure_speedtest() {
    local existing_speedtest=""
    existing_speedtest=$(command -v speedtest 2>/dev/null || true)
    if [ -n "$existing_speedtest" ]; then
        if is_ookla_speedtest "$existing_speedtest"; then
            SPEEDTEST_BIN="$existing_speedtest"
            return 0
        fi
        ui_warn "现有测速命令不兼容，将使用独立临时工具" >&2
    else
        echo -e "${gl_huang}speedtest 未安装。${gl_bai}" >&2
    fi

    echo -e "${gl_zi}正在临时下载 Ookla Speedtest CLI，测速结束后会自动清理。${gl_bai}" >&2

    local cpu_arch
    local download_url
    local expected_sha256
    local actual_sha256
    local tmp_dir
    cpu_arch=$(uname -m)

    case "$cpu_arch" in
        x86_64)
            download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
            expected_sha256="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
            ;;
        aarch64)
            download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
            expected_sha256="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
            ;;
        *)
            echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
            return 1
            ;;
    esac

    tmp_dir=$(mktemp -d /tmp/bbr-speedtest.XXXXXX) || {
        echo -e "${gl_hong}无法创建临时目录，speedtest 安装失败${gl_bai}" >&2
        return 1
    }
    if ! (umask 077; set -C; printf '%s\n' "$tmp_dir" > "$SPEEDTEST_TMP_MARKER") 2>/dev/null; then
        echo -e "${gl_hong}无法安全创建 speedtest 临时状态文件${gl_bai}" >&2
        rm -rf -- "$tmp_dir"
        return 1
    fi
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q "$download_url" -O "$tmp_dir/speedtest.tgz"; then
            echo -e "${gl_hong}speedtest 下载失败${gl_bai}" >&2
            rm -rf "$tmp_dir"
            rm -f "$SPEEDTEST_TMP_MARKER"
            return 1
        fi
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$download_url" -o "$tmp_dir/speedtest.tgz"; then
            echo -e "${gl_hong}speedtest 下载失败${gl_bai}" >&2
            rm -rf "$tmp_dir"
            rm -f "$SPEEDTEST_TMP_MARKER"
            return 1
        fi
    else
        echo -e "${gl_hong}未找到 wget 或 curl，无法下载 speedtest${gl_bai}" >&2
        rm -rf "$tmp_dir"
        rm -f "$SPEEDTEST_TMP_MARKER"
        return 1
    fi

    actual_sha256=$(calculate_sha256 "$tmp_dir/speedtest.tgz" 2>/dev/null || true)
    if [ -z "$actual_sha256" ]; then
        echo -e "${gl_hong}缺少 SHA-256 校验工具，拒绝执行下载的 speedtest${gl_bai}" >&2
        rm -rf "$tmp_dir"
        rm -f "$SPEEDTEST_TMP_MARKER"
        return 1
    fi
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo -e "${gl_hong}speedtest 下载文件 SHA-256 不匹配，已拒绝执行${gl_bai}" >&2
        rm -rf "$tmp_dir"
        rm -f "$SPEEDTEST_TMP_MARKER"
        return 1
    fi

    if ! tar -xzf "$tmp_dir/speedtest.tgz" -C "$tmp_dir" speedtest 2>/dev/null || [ ! -f "$tmp_dir/speedtest" ]; then
        echo -e "${gl_hong}speedtest 解压失败${gl_bai}" >&2
        rm -rf "$tmp_dir"
        rm -f "$SPEEDTEST_TMP_MARKER"
        return 1
    fi

    if ! chmod +x "$tmp_dir/speedtest" || ! is_ookla_speedtest "$tmp_dir/speedtest"; then
        echo -e "${gl_hong}下载的文件不是可用的 Ookla Speedtest CLI${gl_bai}" >&2
        rm -rf "$tmp_dir"
        rm -f "$SPEEDTEST_TMP_MARKER"
        return 1
    fi

    SPEEDTEST_BIN="$tmp_dir/speedtest"
    ui_success "测速工具准备完成" >&2
    return 0
}

detect_bandwidth() {
    local profile="${1:-optimize}"
    local requested_bandwidth="${BANDWIDTH_MBPS:-}"
    local normalized_bandwidth=""

    if normalized_bandwidth=$(normalize_uint "$requested_bandwidth" 1 1000000); then
        echo "$normalized_bandwidth"
        return 0
    fi
    if [ "$AUTO_MODE" = "1" ]; then
        echo "1000"
        return 0
    fi

    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    ui_card_start "选择带宽配置方式" >&2
    ui_card_line "01  手动选择或输入    推荐" >&2
    ui_card_line "02  自动检测          本机最近测速点" >&2
    ui_card_line "03  指定测速服务器    输入服务器 ID" >&2
    ui_card_end >&2
    if [ "$profile" = "optimize" ]; then
        ui_info "请按到落地机方向的可用带宽选择" >&2
    elif [ "$profile" = "landing" ]; then
        ui_info "请按面向主要用户或优化机方向的可用带宽选择" >&2
    fi
    echo "" >&2
    
    read -e -p "$(printf '%b%s%b 选择 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" bw_choice
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        1|01) bw_choice="preset" ;;
        2|02) bw_choice="auto" ;;
        3|03) bw_choice="server" ;;
    esac

    case "$bw_choice" in
        auto)
            # 自动检测带宽 - 选择最近服务器
            echo "" >&2
            ui_info "正在自动测速，请稍候" >&2
            
            # 检查speedtest是否安装
            if ! ensure_speedtest; then
                ui_warn "测速工具不可用，已使用默认带宽方案" >&2
                echo "1000"
                return 0
            fi
            
            # 智能测速：获取附近服务器列表，按距离依次尝试
            # 获取附近服务器列表（按延迟排序）
            local servers_list=$(run_speedtest --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            
            if [ -z "$servers_list" ]; then
                servers_list="auto"
            fi
            
            local speedtest_output=""
            local upload_speed=""
            local attempt=0
            local max_attempts=5  # 最多尝试5个服务器
            
            # 逐个尝试服务器
            for server_id in $servers_list; do
                attempt=$((attempt + 1))
                
                if [ $attempt -gt $max_attempts ]; then
                    break
                fi
                
                if [ "$server_id" = "auto" ]; then
                    speedtest_output=$(run_speedtest 2>&1)
                else
                    speedtest_output=$(run_speedtest --server-id="$server_id" 2>&1)
                fi
                
                # 提取上传速度
                upload_speed=""
                if grep -q "Upload:" <<< "$speedtest_output"; then
                    upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
                fi
                if [ -z "$upload_speed" ]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi
                
                # 检查是否成功
                if [ -n "$upload_speed" ] && ! grep -qi "FAILED\|error" <<< "$speedtest_output"; then
                    ui_success "测速完成" >&2
                    break
                fi
            done
            
            # 所有尝试都失败了
            if [ -z "$upload_speed" ] || grep -qi "FAILED\|error" <<< "$speedtest_output"; then
                ui_warn "自动测速未完成" >&2
                
                # 询问用户确认
                if confirm_yn "是否使用默认方案继续？" "y" "y"; then
                    use_default=y
                else
                    use_default=n
                fi
                
                case "$use_default" in
                    [Yy])
                        echo "1000"
                        return 0
                        ;;
                    [Nn])
                        echo "" >&2
                        echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                        local manual_bandwidth=""
                        while true; do
                            read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                            if normalized_bandwidth=$(normalize_uint "$manual_bandwidth" 1 1000000); then
                                echo "$normalized_bandwidth"
                                return 0
                            else
                                ui_error "请输入有效的数字" >&2
                            fi
                        done
                        ;;
                    *)
                        ui_warn "输入无效，已使用默认方案" >&2
                        echo "1000"
                        return 0
                        ;;
                esac
            fi
            
            # 转为整数并验证
            local upload_mbps=${upload_speed%.*}
            if ! normalized_bandwidth=$(normalize_uint "$upload_mbps" 0 1000000); then
                ui_warn "测速结果异常，已使用默认方案" >&2
                normalized_bandwidth=1000
            elif [ "$normalized_bandwidth" -eq 0 ]; then
                # 不足 1 Mbps 的有效结果按 1 Mbps 保守计算，不能误套千兆默认值。
                normalized_bandwidth=1
            fi

            # 返回带宽值
            echo "$normalized_bandwidth"
            return 0
            ;;
        server)
            # 手动指定测速服务器ID
            echo "" >&2
            ui_section "手动指定测速服务器" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! ensure_speedtest; then
                ui_warn "测速工具不可用，已使用默认带宽方案" >&2
                echo "1000"
                return 0
            fi
            
            # 显示如何查看服务器列表
            ui_card_start "测速服务器" >&2
            ui_card_line "运行 speedtest --servers 可查看完整列表" >&2
            ui_card_line "每行开头的数字就是服务器 ID" >&2
            ui_card_end >&2
            
            # 输入服务器ID
            local server_id=""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入测速服务器ID（纯数字）: ${gl_bai}")" server_id
                
                if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                    break
                else
                    ui_error "请输入纯数字的服务器 ID" >&2
                fi
            done
            
            # 使用指定服务器测速
            echo "" >&2
            ui_info "正在测速，请稍候" >&2
            
            local speedtest_output=$(run_speedtest --server-id="$server_id" 2>&1)
            
            # 提取上传速度
            local upload_speed=""
            if grep -q "Upload:" <<< "$speedtest_output"; then
                upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
            fi
            if [ -z "$upload_speed" ]; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
            fi
            
            # 检查测速是否成功
            if [ -n "$upload_speed" ] && ! grep -qi "FAILED\|error" <<< "$speedtest_output"; then
                local upload_mbps=${upload_speed%.*}
                if ! normalized_bandwidth=$(normalize_uint "$upload_mbps" 0 1000000); then
                    ui_warn "测速结果异常，已使用默认方案" >&2
                    normalized_bandwidth=1000
                elif [ "$normalized_bandwidth" -eq 0 ]; then
                    normalized_bandwidth=1
                fi
                ui_success "测速完成" >&2
                echo "$normalized_bandwidth"
                return 0
            else
                ui_warn "测速未完成" >&2
                
                if confirm_yn "是否使用默认方案继续？" "y" "y"; then
                    use_default=y
                else
                    use_default=n
                fi
                
                if [[ "$use_default" =~ ^[Yy]$ ]]; then
                    echo "1000"
                    return 0
                else
                    echo "" >&2
                    echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                        if normalized_bandwidth=$(normalize_uint "$manual_bandwidth" 1 1000000); then
                            echo "$normalized_bandwidth"
                            return 0
                        else
                            ui_error "请输入有效的数字" >&2
                        fi
                    done
                fi
            fi
            ;;
        preset)
            # 手动选择预设档位
            ui_card_start "选择带宽档位" >&2
            ui_card_line "01  100 Mbps    NAT / 极小带宽" >&2
            ui_card_line "02  200 Mbps    小型 VPS" >&2
            ui_card_line "03  300 Mbps    入门服务器" >&2
            ui_card_line "04  500 Mbps    标准小带宽" >&2
            ui_card_line "05  700 Mbps    准千兆" >&2
            ui_card_line "06  1 Gbps      常见 VPS（推荐）" >&2
            ui_card_line "07  1.5 Gbps    中高端 VPS" >&2
            ui_card_line "08  2 Gbps      高性能 VPS" >&2
            ui_card_line "09  2.5 Gbps    高带宽服务器" >&2
            ui_card_line "10  自定义输入" >&2
            ui_card_line "00  取消调优" >&2
            ui_card_end >&2
            echo "" >&2
            
            # 读取用户选择
            local preset_choice=""
            read -e -p "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}  # 默认选择6 (1 Gbps)
            
            case "$preset_choice" in
                1|01)
                    echo "100"
                    return 0
                    ;;
                2|02)
                    echo "200"
                    return 0
                    ;;
                3|03)
                    echo "300"
                    return 0
                    ;;
                4|04)
                    echo "500"
                    return 0
                    ;;
                5|05)
                    echo "700"
                    return 0
                    ;;
                6|06)
                    echo "1000"
                    return 0
                    ;;
                7|07)
                    echo "1500"
                    return 0
                    ;;
                8|08)
                    echo "2000"
                    return 0
                    ;;
                9|09)
                    echo "2500"
                    return 0
                    ;;
                10)
                    # 自定义输入
                    ui_section "自定义带宽" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入带宽值（单位：Mbps，如 750、1200）: " manual_bandwidth
                        if normalized_bandwidth=$(normalize_uint "$manual_bandwidth" 1 1000000); then
                            echo "$normalized_bandwidth"
                            return 0
                        else
                            ui_error "请输入有效的正整数" >&2
                        fi
                    done
                    ;;
                0|00)
                    echo "" >&2
                    ui_info "已取消本次调优" >&2
                    return 2
                    ;;
                *)
                    ui_warn "无效选择，已使用默认方案" >&2
                    echo "1000"
                    return 0
                    ;;
            esac
            ;;
        *)
            ui_warn "无效选择，已使用默认方案" >&2
            echo "1000"
            return 0
            ;;
    esac
}

profile_label() {
    case "$1" in
        optimize) echo "优化机（代理节点 / Realm / Gost / nft 中转）" ;;
        landing) echo "落地机（代理出口 / 高 RTT 直连 / 文件服务）" ;;
        website) echo "建站机（网站 / API / 反向代理）" ;;
        *) echo "未知场景" ;;
    esac
}

select_tuning_profile() {
    local profile_choice=""
    local requested_profile="${TUNE_PROFILE:-}"

    case "$requested_profile" in
        optimize|landing|website)
            echo "$requested_profile"
            return 0
            ;;
    esac

    if [ "$AUTO_MODE" = "1" ]; then
        echo "optimize"
        return 0
    fi

    ui_card_start "选择服务器用途" >&2
    ui_card_line "01  优化机    代理节点 / 中转入口" >&2
    ui_card_line "02  落地机    代理出口 / 高延迟直连" >&2
    ui_card_line "03  建站机    网站 / API / 反向代理" >&2
    ui_card_end >&2
    echo "" >&2
    read -e -p "$(printf '%b%s%b 选择 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" profile_choice
    profile_choice=${profile_choice:-1}
    case "$profile_choice" in
        2|02) echo "landing" ;;
        3|03) echo "website" ;;
        *) echo "optimize" ;;
    esac
}

region_label() {
    case "$1" in
        asia) echo "亚洲（典型 RTT 80ms）" ;;
        america) echo "美洲（典型 RTT 180ms）" ;;
        europe) echo "欧洲（典型 RTT 200ms）" ;;
        other) echo "其他地区（典型 RTT 200ms）" ;;
        *) echo "未知地区" ;;
    esac
}

select_network_region() {
    local profile="$1"
    local requested_region="${SERVER_REGION:-${TUNE_REGION:-}}"
    local region_choice=""

    requested_region=$(printf '%s' "$requested_region" | tr '[:upper:]' '[:lower:]')
    case "$requested_region" in
        1|asia|asian|cn|hk|jp|sg) echo "asia"; return 0 ;;
        2|america|americas|us|ca|na) echo "america"; return 0 ;;
        3|europe|eu) echo "europe"; return 0 ;;
        4|other|global|oceania|au) echo "other"; return 0 ;;
    esac
    if [ -n "$requested_region" ]; then
        ui_warn "自定义地区设置无效，已改用地区选择" >&2
    fi

    if [ "$AUTO_MODE" = "1" ]; then
        # 非交互模式使用跨地区基线，避免默认 RTT 过低限制高延迟链路。
        echo "other"
        return 0
    fi

    ui_card_start "选择主要链路地区" >&2
    if [ "$profile" = "optimize" ]; then
        ui_card_line "按主要落地机或业务远端所在地区选择" >&2
    else
        ui_card_line "按主要用户或中转机所在地区选择" >&2
    fi
    ui_card_line "01  亚洲      香港 / 日本 / 新加坡 / 韩国" >&2
    ui_card_line "02  美洲      美国 / 加拿大" >&2
    ui_card_line "03  欧洲      德国 / 荷兰 / 英国" >&2
    ui_card_line "04  其他地区  大洋洲 / 中东 / 非洲 / 跨地区" >&2
    ui_card_end >&2
    echo "" >&2
    read -e -p "$(printf '%b%s%b 选择 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" region_choice
    region_choice=${region_choice:-1}
    case "$region_choice" in
        2|02) echo "america" ;;
        3|03) echo "europe" ;;
        4|04) echo "other" ;;
        *) echo "asia" ;;
    esac
}

select_target_rtt() {
    local region="$1"
    local default_rtt=""

    case "$region" in
        asia) default_rtt=80 ;;
        america) default_rtt=180 ;;
        europe) default_rtt=200 ;;
        other) default_rtt=200 ;;
        *)
            ui_warn "地区预设无效，已使用默认 RTT ${DEFAULT_TARGET_RTT_MS} ms" >&2
            default_rtt="$DEFAULT_TARGET_RTT_MS"
            ;;
    esac
    if ! normalize_uint "$default_rtt" 1 2000 >/dev/null 2>&1; then
        ui_warn "地区 RTT 预设异常，已使用默认 RTT ${DEFAULT_TARGET_RTT_MS} ms" >&2
        default_rtt="$DEFAULT_TARGET_RTT_MS"
    fi
    echo "$default_rtt"
}

trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

RTT_TARGET_HOST=""
RTT_TARGET_PORT=""
RTT_TARGET_DISPLAY=""

rtt_target_host_is_valid() {
    local host="$1"

    [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
    [[ "$host" != -* && "$host" != *..* ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ || "$host" =~ ^[0-9A-Fa-f:.%]+$ ]]
}

parse_rtt_target() {
    local target="$1" scheme="" authority="" remainder=""
    local host="" port="" normalized_port=""

    RTT_TARGET_HOST=""
    RTT_TARGET_PORT=""
    RTT_TARGET_DISPLAY=""
    target=$(trim_whitespace "$target")
    [ -n "$target" ] || return 1

    case "$target" in
        http://*)
            scheme="http"
            target=${target#http://}
            ;;
        https://*)
            scheme="https"
            target=${target#https://}
            ;;
        *://*)
            return 1
            ;;
    esac

    if [ -n "$scheme" ]; then
        authority=${target%%/*}
        authority=${authority%%\?*}
        authority=${authority%%#*}
    else
        authority="$target"
    fi
    [ -n "$authority" ] || return 1
    [[ "$authority" != *@* ]] || return 1

    case "$authority" in
        \[*\]*)
            host=${authority#\[}
            host=${host%%\]*}
            remainder=${authority#*\]}
            case "$remainder" in
                "") ;;
                :*) port=${remainder#:} ;;
                *) return 1 ;;
            esac
            ;;
        *:*)
            if [[ "$authority" == *:*:* ]]; then
                # 未加方括号的多冒号输入按裸 IPv6 处理，不猜测末段是否为端口。
                host="$authority"
            else
                host=${authority%:*}
                port=${authority##*:}
            fi
            ;;
        *)
            host="$authority"
            ;;
    esac

    rtt_target_host_is_valid "$host" || return 1
    if [ -z "$port" ]; then
        case "$scheme" in
            http) port=80 ;;
            https) port=443 ;;
        esac
    fi
    if [ -n "$port" ]; then
        normalized_port=$(normalize_uint "$port" 1 65535) || return 1
        port="$normalized_port"
    fi

    RTT_TARGET_HOST="$host"
    RTT_TARGET_PORT="$port"
    if [ -n "$port" ]; then
        if [[ "$host" == *:* ]]; then
            RTT_TARGET_DISPLAY="[${host}]:${port}"
        else
            RTT_TARGET_DISPLAY="${host}:${port}"
        fi
    else
        RTT_TARGET_DISPLAY="$host"
    fi
    return 0
}

measure_icmp_target_samples() {
    local host="$1" output=""
    local ping_command=(ping -n -c 8 -W 2 -i 1 "$host")

    command -v ping >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        output=$(LC_ALL=C timeout 14 "${ping_command[@]}" 2>/dev/null || true)
    else
        output=$(LC_ALL=C "${ping_command[@]}" 2>/dev/null || true)
    fi
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i !~ /^time[=<][0-9.]+/) continue
                value = $i
                sub(/^time[=<]/, "", value)
                if (value !~ /^[0-9]+([.][0-9]+)?$/) continue
                rounded = int(value + 0.5)
                if (rounded < 1) rounded = 1
                print rounded
            }
        }
    ' <<< "$output"
}

resolve_rtt_tcp_host() {
    local host="$1" address=""

    if [[ "$host" =~ ^[0-9]+([.][0-9]+){3}$ || "$host" == *:* ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        address=$(getent ahosts "$host" 2>/dev/null | awk 'NR == 1 {print $1}')
    fi
    printf '%s\n' "${address:-$host}"
}

measure_tcp_connect_once() {
    local host="$1" port="$2" timing_output="" elapsed="" milliseconds=""

    command -v timeout >/dev/null 2>&1 || return 1
    # 在子进程内部只计 TCP connect()，不把 timeout/bash 的启动时间算进 RTT。
    timing_output=$(LC_ALL=C timeout 4 bash -c '
        TIMEFORMAT="%R"
        { time {
            exec 3<>"/dev/tcp/$1/$2" || exit 1
            exec 3>&- 3<&-
        }; } 2>&1
    ' _ "$host" "$port") || return 1
    elapsed=$(awk '/^[0-9]+([.][0-9]+)?$/ {value=$1} END {print value}' <<< "$timing_output")
    [ -n "$elapsed" ] || return 1

    milliseconds=$(awk -v seconds="$elapsed" 'BEGIN {
        value=int(seconds*1000+0.5)
        if (value < 1) value=1
        printf "%d", value
    }')
    normalize_uint "$milliseconds" 1 2000
}

measure_tcp_target_samples() {
    local host="$1" port="$2" address rtt attempt
    local success_count=0

    address=$(resolve_rtt_tcp_host "$host") || return 1
    for attempt in 1 2 3 4 5 6; do
        if rtt=$(measure_tcp_connect_once "$address" "$port"); then
            printf '%s\n' "$rtt"
            success_count=$((success_count + 1))
        fi
        [ "$attempt" -eq 6 ] || sleep 1
    done
    [ "$success_count" -ge 3 ]
}

reset_rtt_statistics() {
    RTT_SAMPLE_MIN=""
    RTT_SAMPLE_MEDIAN=""
    RTT_SAMPLE_AVG=""
    RTT_SAMPLE_P95=""
    RTT_SAMPLE_MAX=""
    RTT_SAMPLE_COUNT=0
    RTT_TARGETS_USED=""
}

set_single_rtt_statistics() {
    local value="$1"

    value=$(normalize_uint "$value" 1 3000) || return 1
    RTT_SAMPLE_MIN="$value"
    RTT_SAMPLE_MEDIAN="$value"
    RTT_SAMPLE_AVG="$value"
    RTT_SAMPLE_P95="$value"
    RTT_SAMPLE_MAX="$value"
    RTT_SAMPLE_COUNT=1
}

calculate_rtt_statistics() {
    local raw_samples="$1" value sum=0 count=0 median_index p95_index
    local sorted=()

    mapfile -t sorted < <(
        printf '%s\n' "$raw_samples" |
            awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 3000 {print $1}' |
            sort -n
    )
    count=${#sorted[@]}
    [ "$count" -gt 0 ] || return 1
    for value in "${sorted[@]}"; do
        sum=$((sum + value))
    done
    median_index=$(((count - 1) / 2))
    p95_index=$(((count * 95 + 99) / 100 - 1))
    [ "$p95_index" -lt "$count" ] || p95_index=$((count - 1))

    RTT_SAMPLE_MIN=${sorted[0]}
    if [ $((count % 2)) -eq 0 ]; then
        RTT_SAMPLE_MEDIAN=$(((sorted[$((count / 2 - 1))] + sorted[$((count / 2))] + 1) / 2))
    else
        RTT_SAMPLE_MEDIAN=${sorted[$median_index]}
    fi
    RTT_SAMPLE_AVG=$(((sum + count / 2) / count))
    RTT_SAMPLE_P95=${sorted[$p95_index]}
    RTT_SAMPLE_MAX=${sorted[$((count - 1))]}
    RTT_SAMPLE_COUNT=$count
}

TARGET_RTT_MEASURED_MS=""
measure_target_rtt_list() {
    local raw_targets="$1" target mode display samples target_max
    local targets=()
    local all_samples="" success_count=0 failed_count=0

    TARGET_RTT_MEASURED_MS=""
    reset_rtt_statistics
    raw_targets=$(trim_whitespace "$raw_targets")
    [ -n "$raw_targets" ] || return 2
    [[ "$raw_targets" != ,* && "$raw_targets" != *, && "$raw_targets" != *,,* ]] || return 2
    IFS=',' read -r -a targets <<< "$raw_targets"
    [ "${#targets[@]}" -ge 1 ] && [ "${#targets[@]}" -le 3 ] || return 2

    for target in "${targets[@]}"; do
        target=$(trim_whitespace "$target")
        parse_rtt_target "$target" || return 2
        display="$RTT_TARGET_DISPLAY"
        if [ -n "$RTT_TARGET_PORT" ]; then
            mode="TCP"
            samples=$(measure_tcp_target_samples "$RTT_TARGET_HOST" "$RTT_TARGET_PORT") || samples=""
            if [ "$(printf '%s\n' "$samples" | awk '/^[0-9]+$/{n++} END{print n+0}')" -lt 3 ]; then
                samples=""
            fi
        else
            mode="ICMP"
            samples=$(measure_icmp_target_samples "$RTT_TARGET_HOST") || samples=""
            if [ "$(printf '%s\n' "$samples" | awk '/^[0-9]+$/{n++} END{print n+0}')" -lt 3 ]; then
                samples=""
            fi
        fi
        if [ -n "$samples" ]; then
            target_max=$(printf '%s\n' "$samples" | sort -n | tail -n 1)
            all_samples+="${all_samples:+$'\n'}${samples}"
            success_count=$((success_count + 1))
            RTT_TARGETS_USED+="${RTT_TARGETS_USED:+,}${display}"
            ui_success "业务对端 ${display}（${mode}，约 6-8 秒）：最大 ${target_max} ms"
        else
            failed_count=$((failed_count + 1))
            ui_warn "业务对端 ${display} 有效样本不足，未参与 RTT 计算"
        fi
    done

    [ "$success_count" -gt 0 ] || return 1
    calculate_rtt_statistics "$all_samples" || return 1
    TARGET_RTT_MEASURED_MS="$RTT_SAMPLE_MAX"
    ui_info "RTT 样本 ${RTT_SAMPLE_COUNT} 个：min/median/avg/p95/max = ${RTT_SAMPLE_MIN}/${RTT_SAMPLE_MEDIAN}/${RTT_SAMPLE_AVG}/${RTT_SAMPLE_P95}/${RTT_SAMPLE_MAX} ms"
    ui_info "按你的策略，TCP 缓冲区使用最大有效 RTT：${TARGET_RTT_MEASURED_MS} ms"
    if [ "$failed_count" -gt 0 ]; then
        ui_warn "${failed_count} 个业务对端样本不足，已按其余 ${success_count} 个目标计算"
    fi
    return 0
}

prepare_target_rtt() {
    local region="$1" profile="$2"
    local preset_rtt requested_rtt normalized_rtt choice="" custom_choice=""
    local manual_rtt="" raw_targets="" measure_rc=0

    TARGET_RTT_RESULT=""
    TARGET_RTT_SOURCE="preset"
    if [ "$profile" = "landing" ]; then
        requested_rtt="${RELAY_RTT_MS:-${TARGET_RTT_MS:-}}"
    else
        requested_rtt="${TARGET_RTT_MS:-}"
    fi
    reset_rtt_statistics
    if normalized_rtt=$(normalize_uint "$requested_rtt" 1 3000); then
        TARGET_RTT_RESULT="$normalized_rtt"
        TARGET_RTT_SOURCE="$([ "$profile" = "landing" ] && echo relay-override || echo override)"
        set_single_rtt_statistics "$normalized_rtt"
        return 0
    fi
    if [ -n "$requested_rtt" ]; then
        ui_warn "TARGET_RTT_MS 无效，已改用地区预设" >&2
    fi

    preset_rtt=$(select_target_rtt "$region")
    if ! normalized_rtt=$(normalize_uint "$preset_rtt" 1 3000); then
        normalized_rtt="$DEFAULT_TARGET_RTT_MS"
        ui_warn "地区预设 RTT 异常，已回退 ${DEFAULT_TARGET_RTT_MS} ms" >&2
    fi
    preset_rtt="$normalized_rtt"
    TARGET_RTT_RESULT="$preset_rtt"
    set_single_rtt_statistics "$preset_rtt"
    if [ -n "${RTT_TEST_TARGETS:-}" ]; then
        if measure_target_rtt_list "$RTT_TEST_TARGETS"; then
            TARGET_RTT_RESULT="$TARGET_RTT_MEASURED_MS"
            TARGET_RTT_SOURCE="target-max"
            return 0
        fi
        ui_warn "RTT_TEST_TARGETS 样本不足，已回退地区预设 ${preset_rtt} ms" >&2
        set_single_rtt_statistics "$preset_rtt"
    fi
    if [ "$AUTO_MODE" = "1" ]; then
        return 0
    fi

    ui_card_start "选择目标 RTT 计算方式" >&2
    ui_card_line "01  地区预设    ${preset_rtt} ms，稳定保守" >&2
    ui_card_line "02  自定义      直接输入 RTT 或检测业务对端 推荐" >&2
    ui_card_end >&2
    echo "" >&2
    if ! read -e -p "$(printf '%b%s%b 选择 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" choice; then
        choice="1"
    fi
    choice=${choice:-1}
    case "$choice" in
        2|02)
            ui_card_start "自定义目标 RTT" >&2
            ui_card_line "01  直接输入 RTT 毫秒值" >&2
            ui_card_line "02  输入对端地址自动检测（支持 域名:端口）" >&2
            ui_card_end >&2
            echo "" >&2
            if ! read -e -p "$(printf '%b%s%b 选择 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" custom_choice; then
                custom_choice="1"
            fi
            custom_choice=${custom_choice:-1}
            case "$custom_choice" in
                2|02)
                    if [ "$profile" = "optimize" ]; then
                        ui_info "优化机可访问 lf3-ips.zstaticcdn.com，查找对应省市和运营商的 TCPPing 地址" >&2
                        ui_info "请粘贴页面列出的完整 域名:端口；多运营商用英文逗号分隔，最多三个" >&2
                    else
                        ui_info "请输入实际用户、中转机或业务远端；支持 IP、域名、域名:端口 或 http(s):// 地址" >&2
                        ui_info "多个目标使用英文逗号分隔，最多输入三个" >&2
                    fi
                    while true; do
                        if ! read -e -p "请输入 1-3 个对端地址: " raw_targets; then
                            raw_targets=""
                        fi
                        if [ -z "$(trim_whitespace "$raw_targets")" ]; then
                            ui_warn "未输入业务对端，已回退地区预设 ${preset_rtt} ms" >&2
                            return 0
                        fi
                        measure_target_rtt_list "$raw_targets"
                        measure_rc=$?
                        case "$measure_rc" in
                            0)
                                TARGET_RTT_RESULT="$TARGET_RTT_MEASURED_MS"
                                TARGET_RTT_SOURCE="target-max"
                                ui_success "已使用业务对端最大有效 RTT：${TARGET_RTT_RESULT} ms" >&2
                                return 0
                                ;;
                            1)
                                ui_warn "所有业务对端均检测失败，已回退地区预设 ${preset_rtt} ms" >&2
                                return 0
                                ;;
                            *)
                                ui_warn "格式无效：支持 IP、域名、域名:端口、http(s):// 地址，多个目标用英文逗号分隔" >&2
                                ;;
                        esac
                    done
                    ;;
                *)
                    while true; do
                        if ! read -e -p "请输入 RTT 毫秒值 [1-3000]: " manual_rtt; then
                            manual_rtt=""
                        fi
                        if normalized_rtt=$(normalize_uint "$manual_rtt" 1 3000); then
                            TARGET_RTT_RESULT="$normalized_rtt"
                            TARGET_RTT_SOURCE="manual"
                            set_single_rtt_statistics "$normalized_rtt"
                            ui_success "已使用自定义 RTT：${TARGET_RTT_RESULT} ms" >&2
                            return 0
                        fi
                        if [ -z "$manual_rtt" ]; then
                            ui_warn "未输入 RTT，已回退地区预设 ${preset_rtt} ms" >&2
                            return 0
                        fi
                        ui_warn "请输入 1-3000 之间的整数" >&2
                    done
                    ;;
            esac
            ;;
        *)
            ui_info "已使用地区预设 RTT：${preset_rtt} ms" >&2
            ;;
    esac
    return 0
}

select_mss_clamp() {
    local profile="$1"
    local requested="${ENABLE_MSS_CLAMP:-}"

    [ "$profile" = "optimize" ] || {
        echo "0"
        return 0
    }
    case "$requested" in
        1|yes|YES|true|TRUE)
            echo "1"
            return 0
            ;;
        0|no|NO|false|FALSE)
            echo "0"
            return 0
            ;;
    esac
    if [ "$AUTO_MODE" = "1" ]; then
        echo "0"
        return 0
    fi

    echo "" >&2
    ui_info "普通代理和网站请选择默认答案" >&2
    if confirm_yn "本机是否使用防火墙进行内核转发？" "n" "n"; then
        echo "1"
    else
        echo "0"
    fi
}

detect_memory_mb() {
    local memory_mb limit_bytes limit_mb limit_file normalized_value
    memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
    memory_mb=$(normalize_uint "$memory_mb" 1 1000000000) || memory_mb=512

    for limit_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [ -r "$limit_file" ] || continue
        limit_bytes=$(cat "$limit_file" 2>/dev/null)
        normalized_value=$(normalize_uint "$limit_bytes" 1 9000000000000000000) || continue
        limit_bytes="$normalized_value"
        limit_mb=$((limit_bytes / 1024 / 1024))
        if [ "$limit_mb" -gt 0 ] && [ "$limit_mb" -lt "$memory_mb" ]; then
            memory_mb=$limit_mb
        fi
    done
    echo "$memory_mb"
}

detect_cpu_count() {
    local cpu_count quota period quota_count normalized_value

    cpu_count=$(nproc 2>/dev/null || true)
    if ! normalized_value=$(normalize_uint "$cpu_count" 1 1000000); then
        cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    else
        cpu_count="$normalized_value"
    fi
    if ! normalized_value=$(normalize_uint "$cpu_count" 1 1000000); then
        cpu_count=$(awk '/^processor[[:space:]]*:/ {count++} END {print count+0}' /proc/cpuinfo 2>/dev/null)
    else
        cpu_count="$normalized_value"
    fi
    if normalized_value=$(normalize_uint "$cpu_count" 1 1000000); then
        cpu_count="$normalized_value"
    else
        cpu_count=1
    fi

    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r quota period < /sys/fs/cgroup/cpu.max || true
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
    fi
    if quota=$(normalize_uint "${quota:-}" 1 9000000000000000000) && \
       period=$(normalize_uint "${period:-}" 1 9000000000000000000); then
        # 分数 CPU 配额向下取整，避免 1.5 CPU 被误判为双核并触发更激进的初始窗口。
        quota_count=$((quota / period))
        [ "$quota_count" -lt 1 ] && quota_count=1
        [ "$quota_count" -lt "$cpu_count" ] && cpu_count=$quota_count
    fi
    echo "$cpu_count"
}

select_tcp_buffer_defaults() {
    local profile="$1"
    local bandwidth="$2"
    local memory_mb="$3"
    local rmem_max_bytes="$4"
    local wmem_max_bytes="${5:-$4}"
    local rmem_min=4096
    local rmem_default=131072
    local wmem_min=4096
    local wmem_default=65536

    # 中间值只负责连接早期的窗口增长，最大值仍由 BDP 和内存上限控制。
    # 高带宽小内存机使用 256KiB 起点可明显缩短爬坡，同时避免 MiB 级默认值
    # 在高并发代理场景中为每条新连接制造过大的瞬时内存和发送突发。
    if [ "$profile" != "website" ] && [ "$bandwidth" -ge 1000 ] && [ "$memory_mb" -ge 768 ]; then
        rmem_default=262144
        wmem_default=262144
    elif [ "$profile" != "website" ] && [ "$bandwidth" -ge 500 ] && [ "$memory_mb" -ge 512 ]; then
        rmem_default=262144
        wmem_default=131072
    elif [ "$memory_mb" -le 256 ]; then
        rmem_default=87380
        wmem_default=16384
    fi

    [ "$rmem_default" -gt "$rmem_max_bytes" ] && rmem_default=$rmem_max_bytes
    [ "$wmem_default" -gt "$wmem_max_bytes" ] && wmem_default=$wmem_max_bytes

    printf '%s %s %s %s\n' "$rmem_min" "$rmem_default" "$wmem_min" "$wmem_default"
}

initial_window_marker_is_valid() {
    local marker_cwnd marker_rwnd
    [ -s "$INIT_WINDOW_MARKER" ] && [ ! -L "$INIT_WINDOW_MARKER" ] || return 1
    marker_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$INIT_WINDOW_MARKER")
    marker_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$INIT_WINDOW_MARKER")
    normalize_uint "$marker_cwnd" 10 32 >/dev/null 2>&1 &&         normalize_uint "$marker_rwnd" 10 32 >/dev/null 2>&1
}

calculate_initial_window_for_path() {
    local bandwidth="$1" rtt_ms="$2" cpu_count="$3" memory_mb="$4"
    local initial_window=10 bdp_kb

    bandwidth=$(normalize_uint "$bandwidth" 1 1000000) || return 1
    rtt_ms=$(normalize_uint "$rtt_ms" 1 3000) || rtt_ms="$DEFAULT_TARGET_RTT_MS"
    cpu_count=$(normalize_uint "$cpu_count" 1 1000000 2>/dev/null) || cpu_count=1
    memory_mb=$(normalize_uint "$memory_mb" 1 1000000000 2>/dev/null) || memory_mb=512

    # IW10 是安全基线。只有带宽、RTT 和本机资源同时足够时才逐档提高，避免
    # 低配机器或短 RTT 路径在首个 RTT 一次性突发过多数据并制造重传。
    bdp_kb=$(( (bandwidth * rtt_ms + 7) / 8 ))
    if [ "$bdp_kb" -ge 512 ] && [ "$bandwidth" -ge 200 ] && [ "$memory_mb" -ge 512 ]; then
        initial_window=16
    fi
    if [ "$bdp_kb" -ge 2048 ] && [ "$bandwidth" -ge 500 ] && [ "$memory_mb" -ge 768 ]; then
        initial_window=24
    fi
    if [ "$bdp_kb" -ge 8192 ] && [ "$bandwidth" -ge 1000 ] && \
       [ "$memory_mb" -ge 1024 ] && [ "$cpu_count" -ge 2 ]; then
        initial_window=32
    fi
    echo "$initial_window"
}

select_initial_window_values() {
    local bandwidth="$1" rtt_ms="$2" cpu_count="$3" memory_mb="$4"
    local automatic requested_cwnd requested_rwnd

    automatic=$(calculate_initial_window_for_path "$bandwidth" "$rtt_ms" "$cpu_count" "$memory_mb") || return 1
    requested_cwnd=$(normalize_uint "${INIT_CWND:-}" 10 32 2>/dev/null || true)
    requested_rwnd=$(normalize_uint "${INIT_RWND:-}" 10 32 2>/dev/null || true)
    INIT_CWND_RESULT="${requested_cwnd:-$automatic}"
    INIT_RWND_RESULT="${requested_rwnd:-$automatic}"
    INIT_WINDOW_MANAGED=1
}

select_effective_bandwidth() {
    local nominal="$1"

    nominal=$(normalize_uint "$nominal" 1 1000000 2>/dev/null) || nominal=1000
    # CPU 核数不能可靠代表 TCP 吞吐能力。窗口必须覆盖用户选择或实际测得的
    # 线路 BDP；机器资源通过缓冲区总内存上限和初始窗口单独收敛。
    printf '%s %s\n' "$nominal" "path-bandwidth"
}

calculate_profile_buffer_size() {
    local bandwidth="$1"
    local rtt_ms="$2"
    local profile="$3"
    local memory_mb="$4"
    local bdp_bytes target_bytes target_mb memory_cap_mb buffer_mb
    local minimum_mb memory_divisor hard_cap_mb headroom_bytes

    bandwidth=$(normalize_uint "$bandwidth" 1 1000000) || bandwidth=1000
    rtt_ms=$(normalize_uint "$rtt_ms" 1 3000) || rtt_ms="$DEFAULT_TARGET_RTT_MS"
    memory_mb=$(normalize_uint "$memory_mb" 1 1000000000) || memory_mb=512

    # BDP(bytes) = Mbps * ms * 125。采用 2*BDP 加固定 2MiB，而不是先把 BDP
    # 向上取整再翻倍；后者在中低 BDP 场景会无意义放大窗口和突发。
    bdp_bytes=$((bandwidth * rtt_ms * 125))
    headroom_bytes=$((2 * 1024 * 1024))
    target_bytes=$((bdp_bytes * 2 + headroom_bytes))
    target_mb=$(( (target_bytes + 1024 * 1024 - 1) / 1024 / 1024 ))

    case "$profile" in
        website)
            minimum_mb=4
            memory_divisor=32
            hard_cap_mb=64
            ;;
        *)
            minimum_mb=4
            memory_divisor=8
            # 覆盖 1GB 机器上 2.5Gbps x 200ms 的 2*BDP。这里是自动调优
            # 天花板，不会在建连时预分配；内存 1/8 与 256MiB 双重上限防止失控。
            hard_cap_mb=256
            ;;
    esac
    [ "$bandwidth" -ge 500 ] && minimum_mb=8
    [ "$target_mb" -lt "$minimum_mb" ] && target_mb=$minimum_mb
    target_mb=$(( ((target_mb + 3) / 4) * 4 ))

    memory_cap_mb=$((memory_mb / memory_divisor))
    [ "$memory_cap_mb" -lt "$minimum_mb" ] && memory_cap_mb=$minimum_mb
    [ "$memory_cap_mb" -gt "$hard_cap_mb" ] && memory_cap_mb=$hard_cap_mb

    buffer_mb=$target_mb
    [ "$buffer_mb" -gt "$memory_cap_mb" ] && buffer_mb=$memory_cap_mb
    echo "$buffer_mb"
}

#=============================================================================
# SWAP智能检测和建议函数（集成到选项2/3）
#=============================================================================
check_and_suggest_swap() {
    local mem_total="" swap_total="" normalized_value="" current_swap_type="" confirm="n"
    local recommended_swap
    local need_swap=0

    command -v free >/dev/null 2>&1 || return 0
    mem_total=$(free -m 2>/dev/null | awk 'NR==2{print $2}')
    swap_total=$(free -m 2>/dev/null | awk 'NR==3{print $2}')
    normalized_value=$(normalize_uint "$mem_total" 1 1000000000) || return 0
    mem_total="$normalized_value"
    normalized_value=$(normalize_uint "$swap_total" 0 1000000000) || return 0
    swap_total="$normalized_value"

    # 判断是否需要SWAP
    if [ "$mem_total" -lt 4096 ]; then
        # 小于 4GB 内存时保留提示，由用户决定是否新增或重建 /swapfile。
        need_swap=1
    fi
    
    # 如果不需要SWAP，直接返回
    if [ "$need_swap" -eq 0 ]; then
        return 0
    fi

    if ! command -v blkid >/dev/null 2>&1; then
        ui_warn "缺少 blkid，无法安全配置虚拟内存"
        return 0
    fi
    if [ -e "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
        if [ ! -f "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
            ui_warn "$SWAP_FILE 不是普通文件，已跳过自动配置"
            return 0
        fi
        current_swap_type=$(blkid -s TYPE -o value "$SWAP_FILE" 2>/dev/null || true)
        if [ "$current_swap_type" != "swap" ]; then
            ui_warn "$SWAP_FILE 不是有效 Swap 文件，为避免覆盖数据已跳过自动配置"
            return 0
        fi
    fi
    
    # 计算推荐的SWAP大小
    if [ "$mem_total" -lt 512 ]; then
        recommended_swap=1024
    elif [ "$mem_total" -lt 1024 ]; then
        recommended_swap=$((mem_total * 2))
    elif [ "$mem_total" -lt 2048 ]; then
        recommended_swap=$((mem_total * 3 / 2))
    elif [ "$mem_total" -lt 4096 ]; then
        recommended_swap=$mem_total
    else
        recommended_swap=4096
    fi
    
    # 小白模式只说明将执行的操作，不展示内存与计算参数。
    echo ""
    ui_warn "检测到内存较小，可由脚本自动配置虚拟内存"
    if [ "$current_swap_type" = "swap" ]; then
        ui_info "检测到现有 $SWAP_FILE；选择继续会按推荐大小重建并更新开机配置"
        ui_info "执行 restore 时会按恢复保护还原 Swap 文件、启用状态和系统参数"
    elif [ "$swap_total" -gt 0 ]; then
        ui_info "检测到系统已有其他 Swap；选择继续只新增 $SWAP_FILE，不修改现有分区"
    else
        ui_info "选择继续会创建 $SWAP_FILE；执行 restore 时恢复原状态"
    fi
    echo ""
    
    # 询问用户
    if confirm_yn "是否现在配置虚拟内存？" "n" "n"; then
        confirm=y
    else
        confirm=n
    fi

    case "$confirm" in
        [Yy])
            if add_swap "$recommended_swap" 1; then
                :
            else
                echo ""
                ui_warn "虚拟内存配置未完成，已尝试恢复原状态"
            fi
            return 0
            ;;
        [Nn])
            ui_info "已跳过虚拟内存配置"
            return 0
            ;;
        *)
            ui_warn "输入无效，已跳过虚拟内存配置"
            return 0
            ;;
    esac
}

#=============================================================================
# 配置冲突检测与清理（避免被其他 sysctl 覆盖）
#=============================================================================
sysctl_key_is_managed() {
    local managed_key

    case "$1" in
        net.ipv4.tcp_ecn)
            # 该键仅用于恢复旧版运行态；当前配置明确保留管理员原值。
            return 1
            ;;
        net.ipv4.tcp_fastopen_blackhole_timeout_sec)
            # 旧内核没有该键时不会写入配置，也不应据此停用其他文件。
            sysctl -n "$1" >/dev/null 2>&1
            return
            ;;
    esac
    for managed_key in "${TUNED_SYSCTL_KEYS[@]}"; do
        [ "$1" = "$managed_key" ] && return 0
    done
    return 1
}

sysctl_key_is_restorable() {
    local key

    sysctl_key_is_managed "$1" && return 0
    for key in "${RETIRED_SYSCTL_KEYS[@]}"; do
        [ "$1" = "$key" ] && return 0
    done
    return 1
}

managed_sysctl_key_regex() {
    local key escaped_key regex=""

    for key in "${TUNED_SYSCTL_KEYS[@]}"; do
        sysctl_key_is_managed "$key" || continue
        # sysctl 同时接受 net.ipv4.key 与 net/ipv4/key 两种写法。
        escaped_key=$(printf '%s\n' "$key" | sed 's|\.|[./]|g')
        regex+="${regex:+|}${escaped_key}"
    done
    printf '^[[:space:]]*-?[[:space:]]*(%s)[[:space:]]*=' "$regex"
}

resolve_sysctl_conf_edit_path() {
    local resolved="/etc/sysctl.conf"

    if [ -L /etc/sysctl.conf ]; then
        command -v readlink >/dev/null 2>&1 || return 1
        resolved=$(readlink -f /etc/sysctl.conf 2>/dev/null) || return 1
    fi
    case "$resolved" in
        /etc/*) ;;
        *) return 1 ;;
    esac
    [ -f "$resolved" ] || return 1
    printf '%s\n' "$resolved"
}

remember_sysctl_conf_edit_path() {
    local edit_path="$1"
    local recorded_path

    case "$edit_path" in
        /etc/*) ;;
        *) return 1 ;;
    esac
    case "$edit_path" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [ -f "$edit_path" ] && [ ! -L "$edit_path" ] || return 1

    if [ -s "$SYSCTL_CONFLICT_PATH_STATE" ]; then
        recorded_path=$(cat "$SYSCTL_CONFLICT_PATH_STATE" 2>/dev/null) || return 1
        if [ "$recorded_path" != "$edit_path" ]; then
            ui_error "sysctl.conf 在调优期间发生变化，已停止自动处理"
            ui_info "请先执行 restore，再重新应用调优"
            return 1
        fi
        return 0
    fi

    if ! printf '%s\n' "$edit_path" > "$SYSCTL_CONFLICT_PATH_STATE"; then
        return 1
    fi
    chmod 600 "$SYSCTL_CONFLICT_PATH_STATE" 2>/dev/null || true
}

append_conflict_mapping() {
    local original_file="$1"
    local disabled_file="$2"
    local state_tmp="${CONFLICT_STATE}.tmp.$$"

    prepare_managed_temp_file "$state_tmp" || return 1
    if ! {
        if [ -s "$CONFLICT_STATE" ]; then
            cat -- "$CONFLICT_STATE" || return 1
        fi
        printf '%s|%s\n' "$original_file" "$disabled_file"
    } > "$state_tmp"; then
        return 1
    fi
    finalize_managed_temp_file "$state_tmp" "$CONFLICT_STATE" 600
}

# 冲突映射按事务整体恢复，不提供未使用的逐条删除入口。

remember_edited_sysctl_file() {
    local edit_path="$1"

    case "$edit_path" in
        /etc/sysctl.d/*.conf) ;;
        *) return 1 ;;
    esac
    case "$edit_path" in *'|'*|*$'\n'*|*$'\r'*) return 1 ;; esac
    [ -f "$edit_path" ] && [ ! -L "$edit_path" ] || return 1
    grep -Fqx -- "edit|$edit_path" "$CONFLICT_STATE" 2>/dev/null && return 0
    append_conflict_mapping "edit" "$edit_path"
}

check_and_clean_conflicts() {
    local conflicts=()
    local conf f key escaped_key sysctl_conf_path
    local key_regex

    key_regex=$(managed_sysctl_key_regex)
    if ! managed_output_path_is_safe "$CONFLICT_STATE" || ! touch "$CONFLICT_STATE" 2>/dev/null; then
        ui_error "无法写入冲突恢复记录"
        return 1
    fi

    for conf in /etc/sysctl.d/*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        # Debian 常见的 99-sysctl.conf 只是 sysctl.conf 的别名，由主文件统一处理。
        if [ -e /etc/sysctl.conf ] && [ "$conf" -ef /etc/sysctl.conf ]; then
            continue
        fi
        grep -qE "$key_regex" "$conf" 2>/dev/null && conflicts+=("$conf")
    done

    local has_sysctl_conflict=0
    if [ -f /etc/sysctl.conf ] && grep -qE "$key_regex" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        return 0
    fi

    ui_info "检测到旧配置冲突，正在自动清理"

    # sysctl.conf 不能整份停用，仅标记冲突行，restore 时可逐行恢复。
    if [ "$has_sysctl_conflict" -eq 1 ]; then
        if ! sysctl_conf_path=$(resolve_sysctl_conf_edit_path); then
            ui_error "无法安全处理 sysctl.conf"
            return 1
        fi
        if ! remember_sysctl_conf_edit_path "$sysctl_conf_path"; then
            ui_error "无法记录冲突恢复状态"
            return 1
        fi
        for key in "${TUNED_SYSCTL_KEYS[@]}"; do
            sysctl_key_is_managed "$key" || continue
            escaped_key=$(printf '%s\n' "$key" | sed 's|\.|[./]|g')
            if ! sed -i -E "s|^([[:space:]]*-?[[:space:]]*${escaped_key}[[:space:]]*=)|# bbr-direct-tune disabled: \\1|" "$sysctl_conf_path"; then
                ui_error "无法清理旧配置冲突"
                return 1
            fi
        done
    fi

    # 其他配置也只标记冲突键，避免同一文件内无关的安全、VM 或业务参数失效。
    # CONFLICT_STATE 同时兼容旧版 original|disabled 映射与新版 edit|path 记录。
    for f in "${conflicts[@]}"; do
        [ -f "$f" ] || continue
        if [ -L "$f" ] || ! remember_edited_sysctl_file "$f"; then
            ui_error "无法安全记录冲突配置：$f"
            return 1
        fi
        for key in "${TUNED_SYSCTL_KEYS[@]}"; do
            sysctl_key_is_managed "$key" || continue
            escaped_key=$(printf '%s\n' "$key" | sed 's|\.|[./]|g')
            if ! sed -i -E "s|^([[:space:]]*-?[[:space:]]*${escaped_key}[[:space:]]*=)|# bbr-direct-tune disabled: \\1|" "$f"; then
                ui_error "无法标记冲突配置：$f"
                return 1
            fi
        done
    done

    chmod 600 "$CONFLICT_STATE" 2>/dev/null || true
    ui_success "旧配置冲突已清理"
    return 0
}

#=============================================================================
# 立即生效与防分片函数（无需重启）
#=============================================================================

ensure_bbr_available() {
    local available_cc original_qdisc candidate_cc

    if ! command -v sysctl >/dev/null 2>&1; then
        ui_error "未检测到 sysctl，无法应用或验证 BBR/FQ"
        return 1
    fi
    if ! command -v tc >/dev/null 2>&1; then
        ui_error "未检测到 tc（iproute2），无法让现有出口网卡立即使用 fq"
        ui_info "请先安装 iproute2，再重新运行脚本"
        return 1
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
    fi
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    BBR_CONGESTION_CONTROL=""
    for candidate_cc in bbr3 bbr2 bbr; do
        if grep -qw "$candidate_cc" <<< "$available_cc"; then
            BBR_CONGESTION_CONTROL="$candidate_cc"
            break
        fi
    done
    if [ -z "$BBR_CONGESTION_CONTROL" ]; then
        ui_error "当前内核未提供可用的 BBR 拥塞控制，已停止应用"
        ui_info "请先升级到支持 BBR 的发行版内核，再重新运行脚本"
        return 1
    fi

    original_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ -z "$original_qdisc" ]; then
        ui_error "无法读取 net.core.default_qdisc，已停止应用"
        return 1
    fi
    if [ "$original_qdisc" != "fq" ]; then
        if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
            ui_error "当前内核不支持 fq，已停止应用"
            return 1
        fi
        if ! sysctl -w "net.core.default_qdisc=${original_qdisc}" >/dev/null 2>&1; then
            ui_error "网络功能预检后未能恢复原状态"
            ui_info "请执行 status 复核调优是否生效后再重试"
            return 1
        fi
    fi

    ui_success "运行环境检查通过"
}

# 获取需应用 qdisc 的网卡（排除常见虚拟接口）
eligible_ifaces() {
    local d dev operstate

    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|ifb*|dummy*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            *'|'*|*[[:space:]]*) continue;;
        esac
        operstate=$(cat "$d/operstate" 2>/dev/null || echo "unknown")
        case "$operstate" in
            down|lowerlayerdown|notpresent) continue ;;
        esac
        echo "$dev"
    done
}

qdisc_root_kind() {
    local output

    output=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    awk '$1 == "qdisc" {
        for (i = 1; i <= NF; i++) {
            if ($i == "root") {print $2; exit}
        }
    }' <<< "$output"
}

fq_initial_quantum_value() {
    local iface="$1" initcwnd="$2" mtu bytes

    initcwnd=$(normalize_uint "$initcwnd" 10 32 2>/dev/null) || initcwnd=10
    mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)
    mtu=$(normalize_uint "$mtu" 576 65536 2>/dev/null) || mtu=1500
    # tc fq 的输入解析器要求裸字节数；以 MTU 加以太网头对齐内核 IW10 默认值。
    bytes=$((initcwnd * (mtu + 14)))
    printf '%s\n' "$bytes"
}

# 将 tc -d 的 fq 参数规范化为可安全重放的输入；未知扩展字段直接拒绝。
fq_record_from_output() {
    local output="$1" line token value canonical="" index=0
    local tokens=()

    line=$(printf '%s\n' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')
    [[ " $line " == *" qdisc fq "* ]] && \
        { [[ " $line " == *" root "* ]] || [[ " $line " == *" parent "* ]]; } || return 1
    read -r -a tokens <<< "$line"
    [ "${tokens[0]:-}" = "qdisc" ] && [ "${tokens[1]:-}" = "fq" ] || return 1
    index=3
    while [ "$index" -lt "${#tokens[@]}" ]; do
        token="${tokens[$index]}"
        case "$token" in
            dev|refcnt|parent) index=$((index + 2)) ;;
            root) index=$((index + 1)) ;;
            limit|flow_limit)
                index=$((index + 1)); value="${tokens[$index]:-}"; value="${value%p}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            buckets)
                index=$((index + 1)); value="${tokens[$index]:-}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            orphan_mask)
                index=$((index + 1)); value="${tokens[$index]:-}"
                normalize_uint "$value" 0 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            quantum|initial_quantum)
                index=$((index + 1)); value="${tokens[$index]:-}"
                value=$(tc_size_to_bytes "$value") || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            maxrate|defrate|low_rate_threshold)
                index=$((index + 1)); value="${tokens[$index]:-}"
                [[ "$value" =~ ^[0-9]+([.][0-9]+)?[KMGTPEkmgtpe]?bit$ ]] || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            refill_delay|ce_threshold|timer_slack|horizon|offload_horizon)
                index=$((index + 1)); value="${tokens[$index]:-}"
                [[ "$value" =~ ^[0-9]+([.][0-9]+)?(s|ms|us|usec|ns)$ ]] || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            pacing|nopacing|horizon_cap|horizon_drop)
                canonical+="${canonical:+ }$token"; index=$((index + 1))
                ;;
            bands)
                index=$((index + 1)); value="${tokens[$index]:-}"
                [ "$value" = "3" ] || return 1
                canonical+="${canonical:+ }bands 3"; index=$((index + 1))
                [ "${tokens[$index]:-}" = "priomap" ] || return 1
                canonical+=" priomap"; index=$((index + 1))
                for _ in {1..16}; do
                    value="${tokens[$index]:-}"
                    normalize_uint "$value" 0 2 >/dev/null || return 1
                    canonical+=" $value"; index=$((index + 1))
                done
                ;;
            weights)
                canonical+="${canonical:+ }weights"; index=$((index + 1))
                for _ in {1..3}; do
                    value="${tokens[$index]:-}"
                    normalize_uint "$value" 1 2147483647 >/dev/null || return 1
                    canonical+=" $value"; index=$((index + 1))
                done
                ;;
            *) return 1 ;;
        esac
    done
    [ -n "$canonical" ] || canonical="default"
    printf '%s\n' "$canonical"
}

fq_spec_normalize() {
    local spec="$1" parsed

    [ -n "$spec" ] && [[ "$spec" != *'|'* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
    if [ "$spec" = "default" ]; then
        parsed=$(fq_record_from_output "qdisc fq 0: root") || return 1
    else
        parsed=$(fq_record_from_output "qdisc fq 0: root $spec") || return 1
    fi
    printf '%s\n' "$parsed"
}

fq_spec_is_valid() {
    fq_spec_normalize "$1" >/dev/null
}

tc_size_to_bytes() {
    local value="$1" number unit multiplier bytes

    [[ "$value" =~ ^([0-9]+)([KMGTPkmgpt]?)[bB]?$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    number=$(normalize_uint "$number" 0 4294967295) || return 1
    case "$unit" in
        '') multiplier=1 ;;
        K|k) multiplier=1024 ;;
        M|m) multiplier=1048576 ;;
        G|g) multiplier=1073741824 ;;
        T|t) multiplier=1099511627776 ;;
        P|p) multiplier=1125899906842624 ;;
        *) return 1 ;;
    esac
    [ "$number" -le $((4294967295 / multiplier)) ] || return 1
    bytes=$((number * multiplier))
    printf '%s\n' "$bytes"
}

# 只有所有硬件队列类型一致，且叶参数也完全一致时才取得 mq 管理权。
# 输出：leaf_kind|queue_count|canonical_spec。
mq_leaf_snapshot() {
    local iface="$1" output handle major line kind parent record line_spec
    local leaf_kind="" leaf_spec="" count=0

    output=$(LC_ALL=C tc -d qdisc show dev "$iface" 2>/dev/null) || return 1
    handle=$(awk '$1 == "qdisc" && $2 == "mq" {
        for (i = 1; i <= NF; i++) if ($i == "root") {print $3; exit}
    }' <<< "$output")
    major=${handle%:}
    [ -n "$major" ] || return 1

    while IFS= read -r line; do
        [ "$(awk '{print $1}' <<< "$line")" = "qdisc" ] || continue
        kind=$(awk '{print $2}' <<< "$line")
        case "$kind" in mq|ingress|clsact) continue ;; esac
        parent=$(awk '{for(i=1;i<=NF;i++) if($i=="parent"){print $(i+1); exit}}' <<< "$line")
        [ -n "$parent" ] || continue
        if [ "$major" = "0" ]; then
            [[ "$parent" == :* || "$parent" == 0:* ]] || continue
        else
            [[ "$parent" == "$major":* ]] || continue
        fi

        case "$kind" in
            fq) line_spec=$(fq_record_from_output "$line") || return 1 ;;
            fq_codel)
                record=$(fq_codel_record_from_output "$line") || return 1
                IFS='|' read -r _ line_spec <<< "$record"
                fq_codel_spec_is_valid auto "$line_spec" || return 1
                ;;
            *) return 1 ;;
        esac
        if [ -z "$leaf_kind" ]; then
            leaf_kind="$kind"
            leaf_spec="$line_spec"
        elif [ "$leaf_kind" != "$kind" ] || [ "$leaf_spec" != "$line_spec" ]; then
            return 1
        fi
        count=$((count + 1))
    done <<< "$output"

    [ "$count" -gt 0 ] && [ -n "$leaf_kind" ] || return 1
    printf '%s|%s|%s\n' "$leaf_kind" "$count" "$leaf_spec"
}

mq_tx_queue_count() {
    local iface="$1" queue count=0

    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
    for queue in "/sys/class/net/$iface/queues"/tx-*; do
        [ -d "$queue" ] || continue
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || return 1
    printf '%s\n' "$count"
}

mq_queue_count() {
    local iface="$1" output handle major

    output=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
    handle=$(awk '$1 == "qdisc" && $2 == "mq" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<< "$output")
    major=${handle%:}; [ -n "$major" ] || return 1
    awk -v major="$major" '$1=="qdisc" && $2!="mq" && $2!="ingress" && $2!="clsact" {
        for(i=1;i<=NF;i++) if($i=="parent") {
            parent=$(i+1)
            if((major=="0" && (parent ~ /^:/ || index(parent,"0:")==1)) || (major!="0" && index(parent,major ":")==1)) count++
            break
        }
    } END{if(count<1) exit 1; print count}' <<< "$output"
}

mq_leaf_kind() { mq_leaf_snapshot "$1" | awk -F'|' '{print $1}'; }
mq_leaf_spec() { mq_leaf_snapshot "$1" | awk -F'|' '{print $3}'; }

mq_state_value() {
    local iface="$1" column="$2"

    [ -s "$MQ_STATE" ] && [ ! -L "$MQ_STATE" ] || return 1
    [ "$(head -n 1 "$MQ_STATE" 2>/dev/null)" = "# mq-state-v2" ] || return 1
    awk -F'|' -v wanted="$iface" -v column="$column" '$1 == wanted && NF == 4 {print $column; exit}' "$MQ_STATE"
}

mq_state_leaf_kind() { mq_state_value "$1" 2; }
mq_state_leaf_count() { mq_state_value "$1" 3; }
mq_state_leaf_spec() {
    local iface="$1" leaf_kind leaf_spec

    leaf_kind=$(mq_state_leaf_kind "$iface") || return 1
    leaf_spec=$(mq_state_value "$iface" 4) || return 1
    if [ "$leaf_kind" = "fq" ]; then
        # 6.13 快照保留 tc 显示单位；重放前统一转换为 tc 接受的裸字节数。
        fq_spec_normalize "$leaf_spec"
    else
        printf '%s\n' "$leaf_spec"
    fi
}

mq_current_matches_snapshot() {
    local iface="$1" snapshot expected

    snapshot=$(mq_leaf_snapshot "$iface") || return 1
    expected="$(mq_state_leaf_kind "$iface")|$(mq_state_leaf_count "$iface")|$(mq_state_leaf_spec "$iface")"
    [ "$snapshot" = "$expected" ]
}

mq_state_file_is_valid() {
    local iface leaf_kind leaf_count leaf_spec

    [ -s "$MQ_STATE" ] && [ ! -L "$MQ_STATE" ] || return 1
    [ "$(head -n 1 "$MQ_STATE" 2>/dev/null)" = "# mq-state-v2" ] || return 1
    while IFS='|' read -r iface leaf_kind leaf_count leaf_spec; do
        [ "$iface" = "# mq-state-v2" ] && continue
        [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
        normalize_uint "$leaf_count" 1 4096 >/dev/null || return 1
        case "$leaf_kind" in
            fq) fq_spec_is_valid "$leaf_spec" || return 1 ;;
            fq_codel) fq_codel_spec_is_valid auto "$leaf_spec" || return 1 ;;
            unsupported) [ "$leaf_spec" = "-" ] || return 1 ;;
            *) return 1 ;;
        esac
    done < "$MQ_STATE"
}

save_mq_snapshot_for_iface() {
    local iface="$1" snapshot leaf_kind leaf_count leaf_spec

    if snapshot=$(mq_leaf_snapshot "$iface"); then
        IFS='|' read -r leaf_kind leaf_count leaf_spec <<< "$snapshot"
    else
        leaf_kind=unsupported
        leaf_count=$(mq_queue_count "$iface") || return 1
        leaf_spec="-"
    fi
    printf '%s|%s|%s|%s\n' "$iface" "$leaf_kind" "$leaf_count" "$leaf_spec" >> "$MQ_STATE"
}

# 兼容 6.9.0 及更早已经提交的快照。旧版从不改 mq，因此只在当前根仍是
# mq 时补录叶队列；若结构已变化则拒绝猜测。
ensure_mq_snapshot_state() {
    local dev kind snapshot leaf_kind leaf_count leaf_spec state_tmp="${MQ_STATE}.tmp.$$"

    if [ -e "$MQ_STATE" ] || [ -L "$MQ_STATE" ]; then
        mq_state_file_is_valid
        return
    fi
    prepare_managed_temp_file "$state_tmp" || return 1
    printf '%s\n' '# mq-state-v2' > "$state_tmp" || return 1
    while IFS='|' read -r dev kind; do
        [ "$dev" = "# qdisc-state-v2" ] && continue
        [ "$kind" = "mq" ] || continue
        [ -e "/sys/class/net/$dev" ] || continue
        [ "$(qdisc_root_kind "$dev")" = "mq" ] || return 1
        if snapshot=$(mq_leaf_snapshot "$dev"); then
            IFS='|' read -r leaf_kind leaf_count leaf_spec <<< "$snapshot"
        else
            leaf_kind=unsupported
            leaf_count=$(mq_queue_count "$dev") || return 1
            leaf_spec="-"
        fi
        printf '%s|%s|%s|%s\n' "$dev" "$leaf_kind" "$leaf_count" "$leaf_spec" >> "$state_tmp" || return 1
    done < "$QDISC_STATE"
    finalize_managed_temp_file "$state_tmp" "$MQ_STATE" 600
}

# mq 0: 不能直接删除。先给它一个可寻址句柄，再删除根；命令只操作 root，
# 不会移除独立的 clsact/ingress qdisc。
qdisc_remove_root() {
    local iface="$1" leaf_kind leaf_spec

    tc qdisc del dev "$iface" root >/dev/null 2>&1 && return 0
    [ "$(qdisc_root_kind "$iface")" = "mq" ] || return 1
    tc qdisc replace dev "$iface" root handle 1: mq >/dev/null 2>&1 || return 1
    tc qdisc del dev "$iface" root >/dev/null 2>&1 && return 0
    leaf_kind=$(mq_state_leaf_kind "$iface" 2>/dev/null || true)
    leaf_spec=$(mq_state_leaf_spec "$iface" 2>/dev/null || true)
    case "$leaf_kind" in fq|fq_codel) qdisc_set_mq_leaves "$iface" "$leaf_kind" "$leaf_spec" >/dev/null 2>&1 || true ;; esac
    return 1
}


qdisc_set_mq_leaves() {
    local iface="$1" leaf_kind="$2" leaf_spec="${3:-default}"
    local output handle major parents parent
    local options=()

    case "$leaf_kind" in
        fq)
            leaf_spec=$(fq_spec_normalize "$leaf_spec") || return 1
            [ "$leaf_spec" = "default" ] || read -r -a options <<< "$leaf_spec"
            ;;
        fq_codel)
            fq_codel_spec_is_valid auto "$leaf_spec" || return 1
            read -r -a options <<< "$leaf_spec"
            ;;
        *) return 1 ;;
    esac
    output=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
    handle=$(awk '$1 == "qdisc" && $2 == "mq" {
        for (i = 1; i <= NF; i++) if ($i == "root") {print $3; exit}
    }' <<< "$output")
    major=${handle%:}
    if [ -z "$major" ] || [ "$major" = "0" ]; then
        tc qdisc replace dev "$iface" root handle 1: mq >/dev/null 2>&1 || return 1
        output=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
        handle=$(awk '$1 == "qdisc" && $2 == "mq" {
            for (i = 1; i <= NF; i++) if ($i == "root") {print $3; exit}
        }' <<< "$output")
        major=${handle%:}
    fi
    [ -n "$major" ] || return 1
    parents=$(awk -v major="$major" '
        $1 == "qdisc" && $2 != "mq" && $2 != "ingress" && $2 != "clsact" {
            for (i = 1; i <= NF; i++) if ($i == "parent") {
                parent=$(i + 1)
                if (index(parent, major ":") == 1) print parent
                break
            }
        }
    ' <<< "$output")
    [ -n "$parents" ] || return 1
    for parent in $parents; do
        if [ "$leaf_kind" = "fq" ]; then
            tc qdisc replace dev "$iface" parent "$parent" fq "${options[@]}" >/dev/null 2>&1 || return 1
        else
            tc qdisc replace dev "$iface" parent "$parent" fq_codel "${options[@]}" >/dev/null 2>&1 || return 1
        fi
    done
    # mq_leaf_snapshot 只有在所有叶队列类型和参数一致时才成功。设置阶段只验证
    # 类型；精确恢复由 qdisc_restore_mq 随后对完整快照做等价校验。
    [ "$(mq_leaf_kind "$iface" 2>/dev/null)" = "$leaf_kind" ]
}

qdisc_restore_mq() {
    local iface="$1" leaf_kind="${2:-}" leaf_spec="${3:-}" current_kind current_count expected_count

    [ -n "$leaf_kind" ] || leaf_kind=$(mq_state_leaf_kind "$iface")
    [ -n "$leaf_spec" ] || leaf_spec=$(mq_state_leaf_spec "$iface")
    case "$leaf_kind" in fq|fq_codel) ;; *) return 1 ;; esac
    current_kind=$(qdisc_root_kind "$iface")
    expected_count=$(mq_state_leaf_count "$iface") || return 1
    if [ "$current_kind" != "mq" ]; then
        current_count=$(mq_tx_queue_count "$iface") || return 1
        [ "$current_count" = "$expected_count" ] || return 1
        qdisc_remove_root "$iface" >/dev/null 2>&1 || [ -z "$current_kind" ] || return 1
        [ "$(qdisc_root_kind "$iface")" = "mq" ] || \
            tc qdisc add dev "$iface" root handle 1: mq >/dev/null 2>&1 || return 1
    fi
    current_count=$(mq_queue_count "$iface") || return 1
    [ "$current_count" = "$expected_count" ] || return 1
    qdisc_set_mq_leaves "$iface" "$leaf_kind" "$leaf_spec" || return 1
    mq_current_matches_snapshot "$iface"
}

qdisc_set_fq() {
    local iface="$1" initcwnd="${2:-10}" current_kind initial_quantum fq_spec

    initial_quantum=$(fq_initial_quantum_value "$iface" "$initcwnd") || return 1
    fq_spec="initial_quantum ${initial_quantum}"
    current_kind=$(qdisc_root_kind "$iface")
    case "$current_kind" in
        mq)
            qdisc_set_mq_leaves "$iface" fq "$fq_spec" || qdisc_set_mq_leaves "$iface" fq default
            ;;
        fq)
            # 原生 fq 没有完整参数快照，调用方应保留它；此分支仅供已接管队列重放。
            tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                tc qdisc replace dev "$iface" root fq >/dev/null 2>&1
            ;;
        fq_codel)
            # 内核自动创建的 handle 0: 根队列不能先删除；已有完整快照时可直接原子替换。
            tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                tc qdisc replace dev "$iface" root fq >/dev/null 2>&1
            ;;
        ''|noqueue)
            tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                tc qdisc replace dev "$iface" root fq >/dev/null 2>&1
            ;;
        *)
            qdisc_remove_root "$iface" || return 1
            current_kind=$(qdisc_root_kind "$iface")
            case "$current_kind" in
                mq) qdisc_set_mq_leaves "$iface" fq "$fq_spec" || qdisc_set_mq_leaves "$iface" fq default ;;
                fq) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                        tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
                *) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                       tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
            esac
            ;;
    esac
}

# 将 tc 输出规范化为可安全重放的 fq_codel 参数。
# 输出格式：HANDLE|OPTIONS。0: 代表内核自动句柄，记录为 auto。
fq_codel_record_from_output() {
    local output="$1" line handle token value canonical="" ecn_mode="noecn"
    local tokens=()
    local index=0 seen_limit=0 seen_flows=0 seen_quantum=0 seen_target=0 seen_interval=0

    line=$(printf '%s\n' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')
    [[ " $line " == *" qdisc fq_codel "* ]] && \
        { [[ " $line " == *" root "* ]] || [[ " $line " == *" parent "* ]]; } || return 1
    read -r -a tokens <<< "$line"
    [ "${#tokens[@]}" -ge 4 ] || return 1
    [ "${tokens[0]}" = "qdisc" ] && [ "${tokens[1]}" = "fq_codel" ] || return 1
    handle="${tokens[2]}"
    [[ "$handle" =~ ^[0-9A-Fa-f]+:$ ]] || return 1
    [ "$handle" = "0:" ] && handle="auto"

    index=3
    while [ "$index" -lt "${#tokens[@]}" ]; do
        token="${tokens[$index]}"
        case "$token" in
            dev|refcnt|parent)
                index=$((index + 2))
                ;;
            root)
                index=$((index + 1))
                ;;
            limit)
                [ "$seen_limit" -eq 0 ] || return 1
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]%p}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }limit $value"; seen_limit=1; index=$((index + 1))
                ;;
            flows)
                [ "$seen_flows" -eq 0 ] || return 1
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }flows $value"; seen_flows=1; index=$((index + 1))
                ;;
            quantum)
                [ "$seen_quantum" -eq 0 ] || return 1
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }quantum $value"; seen_quantum=1; index=$((index + 1))
                ;;
            target|interval|ce_threshold)
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]}"
                [[ "$value" =~ ^[0-9]+([.][0-9]+)?(s|ms|us|usec|ns)$ ]] || return 1
                case "$token" in
                    target) [ "$seen_target" -eq 0 ] || return 1; seen_target=1 ;;
                    interval) [ "$seen_interval" -eq 0 ] || return 1; seen_interval=1 ;;
                esac
                canonical+="${canonical:+ }$token $value"; index=$((index + 1))
                ;;
            memory_limit)
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]}"
                [[ "$value" =~ ^[0-9]+([KMGTPkmgpt]?[bB]?)?$ ]] || return 1
                canonical+="${canonical:+ }memory_limit $value"; index=$((index + 1))
                ;;
            ce_threshold_selector)
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]}"
                [[ "$value" =~ ^(0x[0-9A-Fa-f]+|[0-9]+)/(0x[0-9A-Fa-f]+|[0-9]+)$ ]] || return 1
                canonical+="${canonical:+ }ce_threshold_selector $value"; index=$((index + 1))
                ;;
            drop_batch)
                index=$((index + 1)); [ "$index" -lt "${#tokens[@]}" ] || return 1
                value="${tokens[$index]}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }drop_batch $value"; index=$((index + 1))
                ;;
            ecn)
                ecn_mode="ecn"; index=$((index + 1))
                ;;
            noecn)
                ecn_mode="noecn"; index=$((index + 1))
                ;;
            *)
                # 未识别字段无法保证恢复等价，拒绝取得该队列所有权。
                return 1
                ;;
        esac
    done
    [ "$seen_limit" -eq 1 ] && [ "$seen_flows" -eq 1 ] && [ "$seen_quantum" -eq 1 ] && \
        [ "$seen_target" -eq 1 ] && [ "$seen_interval" -eq 1 ] || return 1
    canonical+="${canonical:+ }$ecn_mode"
    printf '%s|%s\n' "$handle" "$canonical"
}

fq_codel_spec_is_valid() {
    local handle="$1" spec="$2" mock_output parsed parsed_handle parsed_spec expected_handle

    case "$handle" in auto) expected_handle=auto ;; *) [[ "$handle" =~ ^[0-9A-Fa-f]+:$ ]] || return 1; expected_handle="$handle" ;; esac
    [ -n "$spec" ] && [[ "$spec" != *'|'* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
    mock_output="qdisc fq_codel $([ "$handle" = auto ] && echo '0:' || echo "$handle") root $spec"
    parsed=$(fq_codel_record_from_output "$mock_output") || return 1
    IFS='|' read -r parsed_handle parsed_spec <<< "$parsed"
    [ "$parsed_handle" = "$expected_handle" ] && [ "$parsed_spec" = "$spec" ]
}

fq_codel_state_record() {
    local iface="$1"

    [ -s "$FQ_CODEL_STATE" ] && [ ! -L "$FQ_CODEL_STATE" ] || return 1
    [ "$(head -n 1 "$FQ_CODEL_STATE" 2>/dev/null)" = "# fq-codel-state-v1" ] || return 1
    awk -F'|' -v wanted="$iface" '$1 == wanted && NF == 3 {print; exit}' "$FQ_CODEL_STATE"
}

fq_codel_state_file_is_valid() {
    local iface handle spec

    [ -s "$FQ_CODEL_STATE" ] && [ ! -L "$FQ_CODEL_STATE" ] || return 1
    [ "$(head -n 1 "$FQ_CODEL_STATE" 2>/dev/null)" = "# fq-codel-state-v1" ] || return 1
    while IFS='|' read -r iface handle spec; do
        [ "$iface" = "# fq-codel-state-v1" ] && continue
        [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
        fq_codel_spec_is_valid "$handle" "$spec" || return 1
    done < "$FQ_CODEL_STATE"
}

save_fq_codel_snapshot_for_iface() {
    local iface="$1" output record handle spec state_tmp="${FQ_CODEL_STATE}.tmp.$$"

    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [ -e "/sys/class/net/$iface" ] || return 1
    output=$(LC_ALL=C tc -d qdisc show dev "$iface" root 2>/dev/null) || return 1
    record=$(fq_codel_record_from_output "$output") || return 1
    IFS='|' read -r handle spec <<< "$record"
    fq_codel_spec_is_valid "$handle" "$spec" || return 1

    [ ! -e "$FQ_CODEL_STATE" ] || fq_codel_state_file_is_valid || return 1
    prepare_managed_temp_file "$state_tmp" || return 1
    {
        printf '%s\n' '# fq-codel-state-v1'
        if [ -s "$FQ_CODEL_STATE" ]; then
            awk -F'|' -v wanted="$iface" '$1 != wanted && $1 != "# fq-codel-state-v1"' "$FQ_CODEL_STATE" || return 1
        fi
        printf '%s|%s|%s\n' "$iface" "$handle" "$spec"
    } > "$state_tmp" || return 1
    finalize_managed_temp_file "$state_tmp" "$FQ_CODEL_STATE" 600
}

ensure_fq_codel_snapshot_for_iface() {
    local iface="$1" original_kind current_kind record handle spec

    original_kind=$(awk -F'|' -v wanted="$iface" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
    [ "$original_kind" = "fq_codel" ] || return 1
    if record=$(fq_codel_state_record "$iface"); then
        IFS='|' read -r _ handle spec <<< "$record"
        fq_codel_spec_is_valid "$handle" "$spec"
        return
    fi

    # 兼容旧快照：只在当前仍是原 fq_codel 时补录，不从其他队列类型猜测原参数。
    current_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    [ "$current_kind" = "fq_codel" ] || return 1
    save_fq_codel_snapshot_for_iface "$iface"
}

fq_codel_current_matches_snapshot() {
    local iface="$1" record saved_handle saved_spec current_record current_handle current_spec

    record=$(fq_codel_state_record "$iface") || return 1
    IFS='|' read -r _ saved_handle saved_spec <<< "$record"
    current_record=$(fq_codel_record_from_output "$(LC_ALL=C tc -d qdisc show dev "$iface" root 2>/dev/null)") || return 1
    IFS='|' read -r current_handle current_spec <<< "$current_record"
    [ "$saved_spec" = "$current_spec" ] || return 1
    [ "$saved_handle" = "auto" ] || [ "$saved_handle" = "$current_handle" ]
}

restore_fq_codel_root() {
    local iface="$1" record handle spec current_kind
    local tc_command=(tc qdisc replace dev "$iface" root)
    local options=()

    record=$(fq_codel_state_record "$iface") || return 1
    IFS='|' read -r _ handle spec <<< "$record"
    fq_codel_spec_is_valid "$handle" "$spec" || return 1
    read -r -a options <<< "$spec"
    [ "$handle" = "auto" ] || tc_command+=(handle "$handle")
    tc_command+=(fq_codel "${options[@]}")
    "${tc_command[@]}" >/dev/null 2>&1 || return 1
    current_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    [ "$current_kind" = "fq_codel" ] && fq_codel_current_matches_snapshot "$iface"
}

apply_tc_fq_now() {
    local initcwnd="${1:-10}"
    if ! command -v tc >/dev/null 2>&1; then
        ui_error "未检测到 tc（iproute2），无法应用 fq"
        return 1
    fi
    local failed=0
    local candidates=0
    local root_kind original_kind saved_leaf_kind
    for dev in $(eligible_ifaces); do
        original_kind=$(awk -F'|' -v wanted="$dev" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
        [ -n "$original_kind" ] || continue
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$original_kind" in
            none|noqueue|pfifo_fast|fq|fq_codel|mq) ;;
            # 其他队列可能带有不可见或不可安全重放的参数，不取得所有权。
            *) continue ;;
        esac
        case "$original_kind" in
            mq)
                saved_leaf_kind=$(mq_state_leaf_kind "$dev" 2>/dev/null)
                case "$saved_leaf_kind" in
                    fq|fq_codel)
                        candidates=$((candidates + 1))
                        if [ "$root_kind" != "mq" ] || ! qdisc_set_fq "$dev" "$initcwnd"; then
                            failed=$((failed + 1))
                        fi
                        ;;
                    *) ui_warn "网卡 $dev 的 mq 叶队列无法安全重建，已保持原样" ;;
                esac
                ;;
            fq)
                candidates=$((candidates + 1))
                # 根 fq 的原始参数未单独取得所有权，保留现状，避免 restore 无法等价还原。
                [ "$root_kind" = "fq" ] || failed=$((failed + 1))
                ;;
            fq_codel)
                if ensure_fq_codel_snapshot_for_iface "$dev"; then
                    candidates=$((candidates + 1))
                    case "$root_kind" in
                        fq|fq_codel) qdisc_set_fq "$dev" "$initcwnd" || failed=$((failed + 1)) ;;
                        *) failed=$((failed + 1)) ;;
                    esac
                else
                    ui_warn "网卡 $dev 的 fq_codel 参数无法安全保存，已保持原样"
                fi
                ;;
            none|noqueue|pfifo_fast)
                candidates=$((candidates + 1))
                case "$root_kind" in
                    fq) qdisc_set_fq "$dev" "$initcwnd" || failed=$((failed + 1)) ;;
                    ''|noqueue|pfifo_fast) qdisc_set_fq "$dev" "$initcwnd" || failed=$((failed + 1)) ;;
                    *) failed=$((failed + 1)) ;;
                esac
                ;;
        esac
    done
    if [ "$candidates" -eq 0 ]; then
        ui_error "未发现可安全管理的出口网卡，fq 未应用"
        return 1
    fi

    [ "$failed" -gt 0 ] && ui_error "部分网卡队列处理失败"
    [ "$failed" -eq 0 ]
}

default_egress_iface() {
    local iface=""

    if [ "$IPERF_FAMILY" = "-6" ]; then
        iface=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
    else
        iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    fi
    [ -n "$iface" ] || iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] || iface=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
    printf '%s\n' "$iface"
}

apply_default_route_initial_window() {
    local initcwnd="$1"
    local initrwnd="$2"
    local current_route clean_route current_initcwnd current_initrwnd
    local route_identity saved_route saved_identity
    local route_metrics=()
    local route_args=()

    [[ "$initcwnd" =~ ^[0-9]+$ ]] || return 1
    [[ "$initrwnd" =~ ^[0-9]+$ ]] || return 1
    if [ "$initcwnd" -eq 0 ] && [ "$initrwnd" -eq 0 ]; then
        return 0
    fi
    if ! command -v ip >/dev/null 2>&1; then
        [ "$initcwnd" -eq 0 ] && [ "$initrwnd" -eq 0 ]
        return
    fi
    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    current_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    current_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    [ -n "$current_initcwnd" ] || current_initcwnd=0
    [ -n "$current_initrwnd" ] || current_initrwnd=0
    if [ "$current_initcwnd" = "$initcwnd" ] && [ "$current_initrwnd" = "$initrwnd" ]; then
        if [ "$INIT_WINDOW_MANAGED" -eq 1 ]; then
            printf 'initcwnd=%s\ninitrwnd=%s\n' "$initcwnd" "$initrwnd" > "$INIT_WINDOW_MARKER" || return 1
            chmod 600 "$INIT_WINDOW_MARKER" 2>/dev/null || return 1
        fi
        return 0
    fi
    [ -n "$current_route" ] || return 1
    clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    route_identity=$(default_route_identity "$clean_route" 2>/dev/null) || return 1
    [ -n "$route_identity" ] || return 1
    if [ -s "$ROUTE_STATE" ]; then
        saved_route=$(awk -F= '$1 == "route" {sub(/^[^=]*=/, ""); print}' "$ROUTE_STATE")
        saved_identity=$(awk -F= '$1 == "route_identity" {sub(/^[^=]*=/, ""); print}' "$ROUTE_STATE")
        [ -n "$saved_route" ] || return 1
        [ -n "$saved_identity" ] || saved_identity=$(default_route_identity "$saved_route" 2>/dev/null || true)
        [ -n "$saved_identity" ] && [ "$route_identity" = "$saved_identity" ] || return 1
    fi
    read -r -a route_args <<< "$clean_route"
    [ "${#route_args[@]}" -gt 0 ] || return 1
    [ "$initcwnd" -gt 0 ] && route_metrics+=(initcwnd "$initcwnd")
    [ "$initrwnd" -gt 0 ] && route_metrics+=(initrwnd "$initrwnd")
    if ip route replace "${route_args[@]}" "${route_metrics[@]}" >/dev/null 2>&1; then
        if [ "$INIT_WINDOW_MANAGED" -eq 1 ]; then
            printf 'initcwnd=%s\ninitrwnd=%s\n' "$initcwnd" "$initrwnd" > "$INIT_WINDOW_MARKER" || return 1
            chmod 600 "$INIT_WINDOW_MARKER" 2>/dev/null || return 1
        fi
        return 0
    fi
    return 1
}

# MSS clamp（防分片）自动启用
apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        if [ "$action" = "enable" ]; then
            ui_warn "缺少防火墙工具，无法启用转发防分片"
            return 1
        fi
        return 0
    fi
    if [ "$action" = "enable" ]; then
        if iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu -m comment --comment "$MSS_RULE_COMMENT" >/dev/null 2>&1; then
            return 0
        fi
        # 已存在无标记等价规则时不重复添加，也不取得该规则的所有权。
        if iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu >/dev/null 2>&1; then
            return 0
        fi
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu -m comment --comment "$MSS_RULE_COMMENT"
    else
        while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu -m comment --comment "$MSS_RULE_COMMENT" >/dev/null 2>&1; do
            if ! iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
                --clamp-mss-to-pmtu -m comment --comment "$MSS_RULE_COMMENT" >/dev/null 2>&1; then
                return 1
            fi
        done
        return 0
    fi
}

sample_softnet_pressure() {
    local seconds="${1:-3}" first second
    local p1 d1 t1 p2 d2 t2

    SOFTNET_DELTA_DROPPED=0
    SOFTNET_DELTA_SQUEEZE=0
    first=$(read_softnet_counters 2>/dev/null) || return 1
    read -r p1 d1 t1 <<< "$first"
    sleep "$seconds"
    second=$(read_softnet_counters 2>/dev/null) || return 1
    read -r p2 d2 t2 <<< "$second"
    [ "$p2" -ge "$p1" ] && [ "$d2" -ge "$d1" ] && [ "$t2" -ge "$t1" ] || return 1
    SOFTNET_DELTA_DROPPED=$((d2 - d1))
    SOFTNET_DELTA_SQUEEZE=$((t2 - t1))
    return 0
}

feedback_netdev_backlog() {
    local base="$1" memory_mb="$2" cpu_count="$3" result="$1"

    NETDEV_BACKLOG_RESULT="$base"
    SOFTNET_DELTA_DROPPED=0
    SOFTNET_DELTA_SQUEEZE=0
    if [ "$memory_mb" -ge 1024 ] && [ "$cpu_count" -ge 2 ] && sample_softnet_pressure 3; then
        if [ "$SOFTNET_DELTA_DROPPED" -gt 0 ] || [ "$SOFTNET_DELTA_SQUEEZE" -gt 0 ]; then
            result=$((base * 2))
            [ "$result" -gt 32768 ] && result=32768
            ui_warn "3 秒 softnet 增量 dropped/time_squeeze=${SOFTNET_DELTA_DROPPED}/${SOFTNET_DELTA_SQUEEZE}，backlog 升至 ${result}" >&2
        else
            ui_info "3 秒 softnet 无丢弃或挤压增量，backlog 保持 ${base}" >&2
        fi
    else
        ui_info "softnet 样本或资源条件不足，backlog 保持保守值 ${base}" >&2
    fi
    NETDEV_BACKLOG_RESULT="$result"
}

#=============================================================================
# BBR 配置函数（智能检测版）
#=============================================================================

# 直连/落地优化配置
bbr_configure_direct() {
    local snapshot_key
    local congestion_control

    ui_banner
    ui_section "应用 BBR + FQ 智能网络调优"
    if ! validate_managed_output_paths; then
        return 1
    fi
    if ! ensure_bbr_available; then
        return 1
    fi
    congestion_control="$BBR_CONGESTION_CONTROL"
    if ! snapshot_initial_state; then
        ui_error "未能创建恢复快照，已停止应用配置"
        return 1
    fi
    for snapshot_key in "${TUNED_SYSCTL_KEYS[@]}"; do
        sysctl_key_is_managed "$snapshot_key" || continue
        if ! ensure_sysctl_snapshot_key "$snapshot_key"; then
            ui_error "未能补充保存关键参数原值，已停止应用配置"
            return 1
        fi
    done
    # 应用前清理旧版网络事务状态，不保留已退役功能行为。
    if ! cleanup_legacy_runtime_before_apply; then
        ui_error "旧版运行状态清理未完成，已停止应用"
        return 1
    fi
    
    ui_step 1 6 "选择用途、地区并检查内存"
    local profile
    local profile_name
    local region
    local region_name
    local memory_mb
    local cpu_count
    profile=$(select_tuning_profile)
    profile_name=$(profile_label "$profile")
    region=$(select_network_region "$profile")
    region_name=$(region_label "$region")
    memory_mb=$(detect_memory_mb)
    cpu_count=$(detect_cpu_count)
    check_and_suggest_swap

    echo ""
    ui_step 2 6 "自动计算优化方案"
    local detected_bandwidth
    local effective_bandwidth
    local bandwidth_limit_reason
    local target_rtt_ms
    local buffer_mb
    local rmem_buffer_mb
    local wmem_buffer_mb
    local rmem_buffer_bytes
    local wmem_buffer_bytes
    local mss_clamp_enabled
    local initcwnd
    local initrwnd
    local initcwnd_label
    local initrwnd_label
    local rtt_source="preset"
    local buffer_defaults
    local tcp_rmem_min
    local tcp_rmem_default
    local tcp_wmem_min
    local tcp_wmem_default
    if ! detected_bandwidth=$(detect_bandwidth "$profile"); then
        cleanup_test_tools_after_tuning
        return 1
    fi
    read -r effective_bandwidth bandwidth_limit_reason < <(select_effective_bandwidth "$detected_bandwidth")
    ui_success "带宽检测完成，窗口按 ${effective_bandwidth} Mbps 计算"
    prepare_target_rtt "$region" "$profile" || return 1
    target_rtt_ms="$TARGET_RTT_RESULT"
    rtt_source="$TARGET_RTT_SOURCE"
    rmem_buffer_mb=$(calculate_profile_buffer_size "$effective_bandwidth" "$target_rtt_ms" "$profile" "$memory_mb")
    wmem_buffer_mb=$(calculate_profile_buffer_size "$effective_bandwidth" "$target_rtt_ms" "$profile" "$memory_mb")
    rmem_buffer_bytes=$((rmem_buffer_mb * 1024 * 1024))
    wmem_buffer_bytes=$((wmem_buffer_mb * 1024 * 1024))
    buffer_mb="$rmem_buffer_mb"
    [ "$wmem_buffer_mb" -gt "$buffer_mb" ] && buffer_mb="$wmem_buffer_mb"
    buffer_defaults=$(select_tcp_buffer_defaults "$profile" "$effective_bandwidth" "$memory_mb" "$rmem_buffer_bytes" "$wmem_buffer_bytes")
    read -r tcp_rmem_min tcp_rmem_default tcp_wmem_min tcp_wmem_default <<< "$buffer_defaults"
    select_initial_window_values "$effective_bandwidth" "$target_rtt_ms" "$cpu_count" "$memory_mb" || return 1
    initcwnd="$INIT_CWND_RESULT"
    initrwnd="$INIT_RWND_RESULT"
    initcwnd_label=$initcwnd
    initrwnd_label=$initrwnd
    [ "$initcwnd" -eq 0 ] && initcwnd_label="内核默认"
    [ "$initrwnd" -eq 0 ] && initrwnd_label="内核默认"
    mss_clamp_enabled=$(select_mss_clamp "$profile")
    
    echo ""
    ui_step 3 6 "检查并处理配置冲突"
    
    # 仅标记实际冲突键；保留同一 sysctl 文件内的其他安全、VM 和业务参数。
    if ! check_and_clean_conflicts; then
        return 1
    fi

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    ui_step 4 6 "生成优化配置"
    
    local somaxconn=8192
    local syn_backlog=8192
    local netdev_backlog=4096
    local tcp_slow_start_after_idle=0
    local ip_local_port_range="10240 65535"
    local sysctl_conf_tmp="${SYSCTL_CONF}.tmp.$$"
    local profile_state_tmp="${PROFILE_STATE}.tmp.$$"

    case "$profile" in
        optimize)
            syn_backlog=16384
            netdev_backlog=8192
            ;;
        landing)
            somaxconn=4096
            ;;
        website)
            somaxconn=4096
            syn_backlog=8192
            netdev_backlog=2048
            ip_local_port_range="32768 65535"
            ;;
    esac
    # 100/200 Mbps 小水管不放大收包队列，降低突发撞上游限速后形成的排队和重传。
    if [ "$detected_bandwidth" -le 200 ]; then
        [ "$somaxconn" -gt 4096 ] && somaxconn=4096
        [ "$syn_backlog" -gt 4096 ] && syn_backlog=4096
        [ "$netdev_backlog" -gt 2048 ] && netdev_backlog=2048
    fi
    if [ "$memory_mb" -le 512 ]; then
        somaxconn=4096
        syn_backlog=4096
        [ "$netdev_backlog" -gt 4096 ] && netdev_backlog=4096
    fi
    if [ "$memory_mb" -le 256 ]; then
        somaxconn=2048
        syn_backlog=2048
        [ "$netdev_backlog" -gt 2048 ] && netdev_backlog=2048
    fi
    # 高带宽且资源充足时扩大连接监听容量。netdev backlog 是否升档由
    # 短窗口 softnet 增量决定，避免把自开机累计值误判为当前压力。
    if [ "$detected_bandwidth" -ge 2500 ] && [ "$memory_mb" -ge 4096 ] && [ "$cpu_count" -ge 4 ]; then
        somaxconn=32768
        syn_backlog=32768
    elif [ "$detected_bandwidth" -ge 1000 ] && [ "$memory_mb" -ge 2048 ] && [ "$cpu_count" -ge 2 ]; then
        somaxconn=16384
        syn_backlog=32768
    fi
    feedback_netdev_backlog "$netdev_backlog" "$memory_mb" "$cpu_count"
    netdev_backlog="$NETDEV_BACKLOG_RESULT"
    
    if ! mkdir -p "$(dirname "$SYSCTL_CONF")" 2>/dev/null || \
       ! prepare_managed_temp_file "$sysctl_conf_tmp"; then
        ui_error "无法准备优化配置文件"
        return 1
    fi
    if ! cat > "$sysctl_conf_tmp" << EOF
# BBR multi-profile configuration (memory-aware BDP edition)
# Generated on $(date)
# Profile: ${profile} | Region: ${region} | Bandwidth: ${detected_bandwidth} Mbps
# Target RTT: ${target_rtt_ms} ms | Source: ${rtt_source}
# Available memory: ${memory_mb} MB | Online CPU: ${cpu_count} | TCP receive/send cap: ${rmem_buffer_mb}/${wmem_buffer_mb} MB
# Route initial window: initcwnd ${initcwnd_label} | initrwnd ${initrwnd_label}

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=${congestion_control}

# TCP 缓冲区与窗口自动调节（接收/发送方向独立计算）
net.core.rmem_max=${rmem_buffer_bytes}
net.core.wmem_max=${wmem_buffer_bytes}
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_rmem=${tcp_rmem_min} ${tcp_rmem_default} ${rmem_buffer_bytes}
net.ipv4.tcp_wmem=${tcp_wmem_min} ${tcp_wmem_default} ${wmem_buffer_bytes}

# ===== ${profile_name} =====

# 临时端口范围（避开常用服务端口）
net.ipv4.ip_local_port_range=${ip_local_port_range}

# 连接队列（按用途和内存收敛，避免突发流量放大内存）
net.core.somaxconn=${somaxconn}
net.ipv4.tcp_max_syn_backlog=${syn_backlog}
net.ipv4.tcp_abort_on_overflow=0

# 网络收包积压队列（按场景基线和 3 秒 softnet 增量反馈，最高 32768）
net.core.netdev_max_backlog=${netdev_backlog}

    # 高级TCP优化
    net.ipv4.tcp_timestamps=1
    net.ipv4.tcp_sack=1
    net.ipv4.tcp_dsack=1
    # ECN、路径指标缓存、未发送队列和重试寿命保留发行版或管理员原值。
    net.ipv4.tcp_slow_start_after_idle=${tcp_slow_start_after_idle}
    net.ipv4.tcp_mtu_probing=1

# 孤儿 FIN_WAIT_2 回收（TIME_WAIT 上限保留内核自适应默认值）
net.ipv4.tcp_fin_timeout=30

# TCP Fast Open（节省1个RTT，加速连接建立）
net.ipv4.tcp_fastopen=3

# UDP缓冲区（QUIC/Hysteria 支持）
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP安全增强
net.ipv4.tcp_syncookies=1

EOF
    then
        ui_error "优化配置写入失败"
        return 1
    fi

    # 启用 TFO 的黑洞退避；旧内核没有该参数时不写入，避免整份 sysctl 配置报错。
    if sysctl -n net.ipv4.tcp_fastopen_blackhole_timeout_sec >/dev/null 2>&1; then
        if ! cat >> "$sysctl_conf_tmp" << EOF
# TCP Fast Open 中间设备黑洞回退（检测到失败后暂停主动 TFO 1 小时）
net.ipv4.tcp_fastopen_blackhole_timeout_sec=3600

EOF
        then
            ui_error "优化配置写入失败"
            return 1
        fi
    fi

    # 检查配置文件是否创建成功
    if [ ! -s "$sysctl_conf_tmp" ] || \
       ! finalize_managed_temp_file "$sysctl_conf_tmp" "$SYSCTL_CONF" 644; then
        ui_error "配置创建失败，请检查磁盘空间和权限"
        return 1
    fi
    if ! prepare_managed_temp_file "$profile_state_tmp" || \
       ! printf 'profile=%s
profile_name=%s
region=%s
region_name=%s
congestion_control=%s
bandwidth_mbps=%s
rtt_ms=%s
rtt_source=%s
rtt_min=%s
rtt_median=%s
rtt_avg=%s
rtt_p95=%s
rtt_max=%s
rtt_count=%s
rtt_targets=%s
memory_mb=%s
cpu_count=%s
buffer_mb=%s
rmem_buffer_mb=%s
wmem_buffer_mb=%s
tcp_rmem=%s %s %s
tcp_wmem=%s %s %s
somaxconn=%s
tcp_max_syn_backlog=%s
netdev_max_backlog=%s
softnet_delta_dropped=%s
softnet_delta_time_squeeze=%s
initcwnd=%s
initrwnd=%s
mss_clamp=%s
'         "$profile" "$profile_name" "$region" "$region_name" "$congestion_control" "$detected_bandwidth" "$target_rtt_ms"         "$rtt_source" "$RTT_SAMPLE_MIN" "$RTT_SAMPLE_MEDIAN" "$RTT_SAMPLE_AVG" "$RTT_SAMPLE_P95" "$RTT_SAMPLE_MAX" "$RTT_SAMPLE_COUNT" "$RTT_TARGETS_USED"         "$memory_mb" "$cpu_count" "$buffer_mb" "$rmem_buffer_mb" "$wmem_buffer_mb"         "$tcp_rmem_min" "$tcp_rmem_default" "$rmem_buffer_bytes" "$tcp_wmem_min" "$tcp_wmem_default" "$wmem_buffer_bytes" "$somaxconn" "$syn_backlog"         "$netdev_backlog" "${SOFTNET_DELTA_DROPPED:-0}" "${SOFTNET_DELTA_SQUEEZE:-0}" "$initcwnd" "$initrwnd" "$mss_clamp_enabled" > "$profile_state_tmp" || \
       ! finalize_managed_temp_file "$profile_state_tmp" "$PROFILE_STATE" 600; then
        ui_error "无法保存调优状态"
        return 1
    fi
    if ! printf 'effective_bandwidth_mbps=%s\nbandwidth_limit_reason=%s\n' \
        "$effective_bandwidth" "$bandwidth_limit_reason" >> "$PROFILE_STATE"; then
        ui_error "无法保存带宽约束状态"
        return 1
    fi
    chmod 600 "$PROFILE_STATE" 2>/dev/null || return 1

    # 步骤 4：应用配置
    echo ""
    ui_step 5 6 "应用优化并设置开机生效"
    local sysctl_rc=0
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || sysctl_rc=$?
    if [ "$sysctl_rc" -ne 0 ]; then
        ui_warn "部分系统配置未成功应用，将继续完成验证"
    else
        ui_success "系统配置已应用"
    fi
    restore_retired_sysctl_keys_after_apply

    # 立即应用 fq 和路由初始窗口；MSS Clamp 仅用于明确启用的内核转发场景。
    local qdisc_apply_failed=0
    local route_apply_failed=0
    local mss_apply_failed=0
    if ! apply_tc_fq_now "$initcwnd"; then
        qdisc_apply_failed=1
        ui_error "部分网络设置处理失败；流程继续并在最后验证"
    fi
    if ! apply_default_route_initial_window "$initcwnd" "$initrwnd"; then
        route_apply_failed=1
        ui_warn "部分网络设置未成功应用；其余调优继续"
    fi
    if [ "$mss_clamp_enabled" = "1" ]; then
        apply_mss_clamp enable >/dev/null 2>&1 || mss_apply_failed=1
    else
        apply_mss_clamp disable >/dev/null 2>&1 || mss_apply_failed=1
    fi
    # 持久化所有运行时调优（重启后自动恢复）
    local modules_conf_tmp="${MODULES_CONF}.tmp.$$"
    local persist_script_tmp="${PERSIST_SCRIPT}.tmp.$$"
    if mkdir -p /etc/modules-load.d 2>/dev/null && \
       prepare_managed_temp_file "$modules_conf_tmp" && \
       printf '%s\n' tcp_bbr > "$modules_conf_tmp" && \
       finalize_managed_temp_file "$modules_conf_tmp" "$MODULES_CONF" 644; then
        :
    else
        ui_warn "开机恢复准备未完全完成"
    fi

    if ! mkdir -p "$(dirname "$PERSIST_SCRIPT")" 2>/dev/null || \
       ! prepare_managed_temp_file "$persist_script_tmp"; then
        ui_error "开机恢复配置创建失败"
        return 1
    fi
    if ! cat > "$persist_script_tmp" << 'APPLYEOF'
#!/bin/bash
# BBR 多场景重启恢复脚本 - 自动生成，勿手动编辑
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
PROFILE_STATE="/var/lib/bbr-direct-tune/profile.state"
QDISC_STATE="/var/lib/bbr-direct-tune/qdisc.state"
MQ_STATE="/var/lib/bbr-direct-tune/mq.state"
FQ_CODEL_STATE="/var/lib/bbr-direct-tune/fq_codel.state"
ROUTE_STATE="/var/lib/bbr-direct-tune/route.state"
MSS_CLAMP_ENABLED=0
INITCWND=0
INITRWND=0
BUFFER_MB=0
CPU_COUNT=1
TCP_RMEM=""
TCP_WMEM=""
RMEM_MAX_BYTES=0
WMEM_MAX_BYTES=0
SOMAXCONN=0
SYN_BACKLOG=0
NETDEV_BACKLOG=0
CONGESTION_CONTROL=""
PROFILE_FAILED=0
normalize_uint() {
    local value="$1" min_value="$2" max_value="$3"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [ "${value#0}" != "$value" ]; do value=${value#0}; done
    [ -n "$value" ] || value=0
    [ "${#value}" -le "${#max_value}" ] || return 1
    [ "$value" -ge "$min_value" ] && [ "$value" -le "$max_value" ] || return 1
    printf '%s\n' "$value"
}
qdisc_root_kind() {
    tc qdisc show dev "$1" 2>/dev/null | awk '$1=="qdisc"{for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}'
}
fq_initial_quantum_value() {
    local iface="$1" initcwnd="$2" mtu bytes
    initcwnd=$(normalize_uint "$initcwnd" 10 32 2>/dev/null) || initcwnd=10
    mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)
    mtu=$(normalize_uint "$mtu" 576 65536 2>/dev/null) || mtu=1500
    bytes=$((initcwnd * (mtu + 14)))
    printf '%s\n' "$bytes"
}
tc_size_to_bytes() {
    local value="$1" number unit multiplier bytes
    [[ "$value" =~ ^([0-9]+)([KMGTPkmgpt]?)[bB]?$ ]] || return 1
    number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    number=$(normalize_uint "$number" 0 4294967295) || return 1
    case "$unit" in
        '') multiplier=1 ;; K|k) multiplier=1024 ;; M|m) multiplier=1048576 ;;
        G|g) multiplier=1073741824 ;; T|t) multiplier=1099511627776 ;;
        P|p) multiplier=1125899906842624 ;; *) return 1 ;;
    esac
    [ "$number" -le $((4294967295 / multiplier)) ] || return 1
    bytes=$((number * multiplier))
    printf '%s\n' "$bytes"
}
fq_record_from_output() {
    local output="$1" line token value canonical="" index=0 tokens=()
    line=$(printf '%s\n' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')
    [[ " $line " == *" qdisc fq "* ]] && { [[ " $line " == *" root "* ]] || [[ " $line " == *" parent "* ]]; } || return 1
    read -r -a tokens <<< "$line"
    [ "${tokens[0]:-}" = qdisc ] && [ "${tokens[1]:-}" = fq ] || return 1
    index=3
    while [ "$index" -lt "${#tokens[@]}" ]; do
        token="${tokens[$index]}"
        case "$token" in
            dev|refcnt|parent) index=$((index + 2)) ;;
            root) index=$((index + 1)) ;;
            limit|flow_limit)
                index=$((index + 1)); value="${tokens[$index]:-}"; value="${value%p}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            buckets)
                index=$((index + 1)); value="${tokens[$index]:-}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            orphan_mask)
                index=$((index + 1)); value="${tokens[$index]:-}"
                normalize_uint "$value" 0 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            quantum|initial_quantum)
                index=$((index + 1)); value="${tokens[$index]:-}"
                value=$(tc_size_to_bytes "$value") || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            maxrate|defrate|low_rate_threshold)
                index=$((index + 1)); value="${tokens[$index]:-}"
                [[ "$value" =~ ^[0-9]+([.][0-9]+)?[KMGTPEkmgtpe]?bit$ ]] || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            refill_delay|ce_threshold|timer_slack|horizon|offload_horizon)
                index=$((index + 1)); value="${tokens[$index]:-}"
                [[ "$value" =~ ^[0-9]+([.][0-9]+)?(s|ms|us|usec|ns)$ ]] || return 1
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            pacing|nopacing|horizon_cap|horizon_drop)
                canonical+="${canonical:+ }$token"; index=$((index + 1)) ;;
            bands)
                index=$((index + 1)); value="${tokens[$index]:-}"; [ "$value" = 3 ] || return 1
                canonical+="${canonical:+ }bands 3"; index=$((index + 1))
                [ "${tokens[$index]:-}" = priomap ] || return 1
                canonical+=" priomap"; index=$((index + 1))
                for _ in {1..16}; do
                    value="${tokens[$index]:-}"; normalize_uint "$value" 0 2 >/dev/null || return 1
                    canonical+=" $value"; index=$((index + 1))
                done ;;
            weights)
                canonical+="${canonical:+ }weights"; index=$((index + 1))
                for _ in {1..3}; do
                    value="${tokens[$index]:-}"; normalize_uint "$value" 1 2147483647 >/dev/null || return 1
                    canonical+=" $value"; index=$((index + 1))
                done ;;
            *) return 1 ;;
        esac
    done
    [ -n "$canonical" ] || canonical=default
    printf '%s\n' "$canonical"
}
fq_spec_normalize() {
    local spec="$1" parsed
    [ -n "$spec" ] && [[ "$spec" != *'|'* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
    if [ "$spec" = default ]; then parsed=$(fq_record_from_output "qdisc fq 0: root") || return 1
    else parsed=$(fq_record_from_output "qdisc fq 0: root $spec") || return 1; fi
    printf '%s\n' "$parsed"
}
fq_spec_is_valid() { fq_spec_normalize "$1" >/dev/null; }
mq_leaf_snapshot() {
    local output handle major line kind parent record line_spec leaf_kind="" leaf_spec="" count=0
    output=$(LC_ALL=C tc -d qdisc show dev "$1" 2>/dev/null) || return 1
    handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<< "$output")
    major=${handle%:}; [ -n "$major" ] || return 1
    while IFS= read -r line; do
        [ "$(awk '{print $1}' <<< "$line")" = qdisc ] || continue
        kind=$(awk '{print $2}' <<< "$line")
        case "$kind" in mq|ingress|clsact) continue ;; esac
        parent=$(awk '{for(i=1;i<=NF;i++) if($i=="parent"){print $(i+1); exit}}' <<< "$line")
        [ -n "$parent" ] || continue
        if [ "$major" = 0 ]; then [[ "$parent" == :* || "$parent" == 0:* ]] || continue
        else [[ "$parent" == "$major":* ]] || continue; fi
        case "$kind" in
            fq) line_spec=$(fq_record_from_output "$line") || return 1 ;;
            fq_codel)
                record=$(fq_codel_record_from_output "$line") || return 1
                IFS='|' read -r _ line_spec <<< "$record"
                fq_codel_spec_is_valid auto "$line_spec" || return 1
                ;;
            *) return 1 ;;
        esac
        if [ -z "$leaf_kind" ]; then leaf_kind="$kind"; leaf_spec="$line_spec"
        elif [ "$leaf_kind" != "$kind" ] || [ "$leaf_spec" != "$line_spec" ]; then return 1; fi
        count=$((count + 1))
    done <<< "$output"
    [ "$count" -gt 0 ] && [ -n "$leaf_kind" ] || return 1
    printf '%s|%s|%s\n' "$leaf_kind" "$count" "$leaf_spec"
}
mq_tx_queue_count() {
    local queue count=0
    [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
    for queue in "/sys/class/net/$1/queues"/tx-*; do [ -d "$queue" ] && count=$((count + 1)); done
    [ "$count" -gt 0 ] || return 1
    printf '%s\n' "$count"
}
mq_queue_count() {
    local output handle major
    output=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<< "$output")
    major=${handle%:}; [ -n "$major" ] || return 1
    awk -v major="$major" '$1=="qdisc" && $2!="mq" && $2!="ingress" && $2!="clsact" {
        for(i=1;i<=NF;i++) if($i=="parent") {parent=$(i+1); if((major=="0" && (parent ~ /^:/ || index(parent,"0:")==1)) || (major!="0" && index(parent,major ":")==1)) count++; break}
    } END{if(count<1) exit 1; print count}' <<< "$output"
}
mq_leaf_kind() { mq_leaf_snapshot "$1" | awk -F'|' '{print $1}'; }
mq_state_value() {
    [ -s "$MQ_STATE" ] && [ ! -L "$MQ_STATE" ] || return 1
    [ "$(head -n 1 "$MQ_STATE" 2>/dev/null)" = "# mq-state-v2" ] || return 1
    awk -F'|' -v wanted="$1" -v column="$2" '$1==wanted && NF==4{print $column; exit}' "$MQ_STATE"
}
mq_state_leaf_kind() { mq_state_value "$1" 2; }
mq_state_leaf_count() { mq_state_value "$1" 3; }
mq_state_leaf_spec() {
    local kind spec
    kind=$(mq_state_leaf_kind "$1") || return 1
    spec=$(mq_state_value "$1" 4) || return 1
    if [ "$kind" = fq ]; then fq_spec_normalize "$spec"; else printf '%s\n' "$spec"; fi
}
mq_current_matches_snapshot() {
    local actual expected
    actual=$(mq_leaf_snapshot "$1") || return 1
    expected="$(mq_state_leaf_kind "$1")|$(mq_state_leaf_count "$1")|$(mq_state_leaf_spec "$1")"
    [ "$actual" = "$expected" ]
}
qdisc_remove_root() {
    local iface="$1" kind spec
    tc qdisc del dev "$iface" root >/dev/null 2>&1 && return 0
    [ "$(qdisc_root_kind "$iface")" = mq ] || return 1
    tc qdisc replace dev "$iface" root handle 1: mq >/dev/null 2>&1 || return 1
    tc qdisc del dev "$iface" root >/dev/null 2>&1 && return 0
    kind=$(mq_state_leaf_kind "$iface" 2>/dev/null || true)
    spec=$(mq_state_leaf_spec "$iface" 2>/dev/null || true)
    case "$kind" in fq|fq_codel) qdisc_set_mq_leaves "$iface" "$kind" "$spec" >/dev/null 2>&1 || true ;; esac
    return 1
}
qdisc_set_mq_leaves() {
    local iface="$1" kind="$2" spec="${3:-default}" output handle major parents parent options=()
    case "$kind" in
        fq) spec=$(fq_spec_normalize "$spec") || return 1; [ "$spec" = default ] || read -r -a options <<< "$spec" ;;
        fq_codel) fq_codel_spec_is_valid auto "$spec" || return 1; read -r -a options <<< "$spec" ;;
        *) return 1 ;;
    esac
    output=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
    handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<< "$output")
    major=${handle%:}
    if [ -z "$major" ] || [ "$major" = 0 ]; then
        tc qdisc replace dev "$iface" root handle 1: mq >/dev/null 2>&1 || return 1
        output=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
        handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<< "$output")
        major=${handle%:}
    fi
    [ -n "$major" ] || return 1
    parents=$(awk -v major="$major" '$1=="qdisc" && $2!="mq" && $2!="ingress" && $2!="clsact" {
        for(i=1;i<=NF;i++) if($i=="parent"){parent=$(i+1); if(index(parent,major ":")==1) print parent; break}}
    ' <<< "$output")
    [ -n "$parents" ] || return 1
    for parent in $parents; do
        if [ "$kind" = fq ]; then tc qdisc replace dev "$iface" parent "$parent" fq "${options[@]}" >/dev/null 2>&1 || return 1
        else tc qdisc replace dev "$iface" parent "$parent" fq_codel "${options[@]}" >/dev/null 2>&1 || return 1; fi
    done
    [ "$(mq_leaf_kind "$iface" 2>/dev/null)" = "$kind" ]
}
qdisc_restore_mq() {
    local iface="$1" kind spec current current_count expected_count
    kind=$(mq_state_leaf_kind "$iface") || return 1
    spec=$(mq_state_leaf_spec "$iface") || return 1
    current=$(qdisc_root_kind "$iface")
    expected_count=$(mq_state_leaf_count "$iface") || return 1
    if [ "$current" != mq ]; then
        current_count=$(mq_tx_queue_count "$iface") || return 1
        [ "$current_count" = "$expected_count" ] || return 1
        qdisc_remove_root "$iface" >/dev/null 2>&1 || [ -z "$current" ] || return 1
        [ "$(qdisc_root_kind "$iface")" = mq ] || tc qdisc add dev "$iface" root handle 1: mq >/dev/null 2>&1 || return 1
    fi
    current_count=$(mq_queue_count "$iface") || return 1
    [ "$current_count" = "$expected_count" ] || return 1
    qdisc_set_mq_leaves "$iface" "$kind" "$spec" || return 1
    mq_current_matches_snapshot "$iface"
}
qdisc_set_fq() {
    local iface="$1" initcwnd="${2:-10}" current initial_quantum spec
    initial_quantum=$(fq_initial_quantum_value "$iface" "$initcwnd") || return 1
    spec="initial_quantum ${initial_quantum}"
    current=$(qdisc_root_kind "$iface")
    case "$current" in
        mq) qdisc_set_mq_leaves "$iface" fq "$spec" || qdisc_set_mq_leaves "$iface" fq default ;;
        fq) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
            tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
        fq_codel) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
            tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
        ''|noqueue) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
            tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
        *) qdisc_remove_root "$iface" || return 1
           current=$(qdisc_root_kind "$iface")
           case "$current" in
               mq) qdisc_set_mq_leaves "$iface" fq "$spec" || qdisc_set_mq_leaves "$iface" fq default ;;
               fq) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                   tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
               *) tc qdisc replace dev "$iface" root fq initial_quantum "$initial_quantum" >/dev/null 2>&1 || \
                   tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
           esac ;;
    esac
}
fq_codel_record_from_output() {
    local output="$1" line handle token value canonical="" ecn_mode="noecn"
    local tokens=() index=0 seen_limit=0 seen_flows=0 seen_quantum=0 seen_target=0 seen_interval=0
    line=$(printf '%s\n' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')
    [[ " $line " == *" qdisc fq_codel "* ]] && \
        { [[ " $line " == *" root "* ]] || [[ " $line " == *" parent "* ]]; } || return 1
    read -r -a tokens <<< "$line"
    [ "${tokens[0]:-}" = qdisc ] && [ "${tokens[1]:-}" = fq_codel ] || return 1
    handle="${tokens[2]:-}"; [[ "$handle" =~ ^[0-9A-Fa-f]+:$ ]] || return 1
    [ "$handle" = 0: ] && handle=auto
    index=3
    while [ "$index" -lt "${#tokens[@]}" ]; do
        token="${tokens[$index]}"
        case "$token" in
            dev|refcnt|parent) index=$((index + 2)) ;;
            root) index=$((index + 1)) ;;
            limit)
                [ "$seen_limit" -eq 0 ] || return 1; index=$((index + 1)); value="${tokens[$index]:-}"; value="${value%p}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1; canonical+="${canonical:+ }limit $value"; seen_limit=1; index=$((index + 1)) ;;
            flows)
                [ "$seen_flows" -eq 0 ] || return 1; index=$((index + 1)); value="${tokens[$index]:-}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1; canonical+="${canonical:+ }flows $value"; seen_flows=1; index=$((index + 1)) ;;
            quantum)
                [ "$seen_quantum" -eq 0 ] || return 1; index=$((index + 1)); value="${tokens[$index]:-}"
                normalize_uint "$value" 1 4294967295 >/dev/null || return 1; canonical+="${canonical:+ }quantum $value"; seen_quantum=1; index=$((index + 1)) ;;
            target|interval|ce_threshold)
                index=$((index + 1)); value="${tokens[$index]:-}"; [[ "$value" =~ ^[0-9]+([.][0-9]+)?(s|ms|us|usec|ns)$ ]] || return 1
                case "$token" in target) [ "$seen_target" -eq 0 ] || return 1; seen_target=1 ;; interval) [ "$seen_interval" -eq 0 ] || return 1; seen_interval=1 ;; esac
                canonical+="${canonical:+ }$token $value"; index=$((index + 1)) ;;
            memory_limit)
                index=$((index + 1)); value="${tokens[$index]:-}"; [[ "$value" =~ ^[0-9]+([KMGTPkmgpt]?[bB]?)?$ ]] || return 1
                canonical+="${canonical:+ }memory_limit $value"; index=$((index + 1)) ;;
            ce_threshold_selector)
                index=$((index + 1)); value="${tokens[$index]:-}"; [[ "$value" =~ ^(0x[0-9A-Fa-f]+|[0-9]+)/(0x[0-9A-Fa-f]+|[0-9]+)$ ]] || return 1
                canonical+="${canonical:+ }ce_threshold_selector $value"; index=$((index + 1)) ;;
            drop_batch)
                index=$((index + 1)); value="${tokens[$index]:-}"; normalize_uint "$value" 1 4294967295 >/dev/null || return 1
                canonical+="${canonical:+ }drop_batch $value"; index=$((index + 1)) ;;
            ecn) ecn_mode=ecn; index=$((index + 1)) ;;
            noecn) ecn_mode=noecn; index=$((index + 1)) ;;
            *) return 1 ;;
        esac
    done
    [ "$seen_limit" -eq 1 ] && [ "$seen_flows" -eq 1 ] && [ "$seen_quantum" -eq 1 ] && [ "$seen_target" -eq 1 ] && [ "$seen_interval" -eq 1 ] || return 1
    canonical+="${canonical:+ }$ecn_mode"; printf '%s|%s\n' "$handle" "$canonical"
}
fq_codel_spec_is_valid() {
    local handle="$1" spec="$2" mock parsed parsed_handle parsed_spec expected_handle
    case "$handle" in auto) expected_handle=auto ;; *) [[ "$handle" =~ ^[0-9A-Fa-f]+:$ ]] || return 1; expected_handle="$handle" ;; esac
    [ -n "$spec" ] && [[ "$spec" != *'|'* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
    mock="qdisc fq_codel $([ "$handle" = auto ] && echo 0: || echo "$handle") root $spec"
    parsed=$(fq_codel_record_from_output "$mock") || return 1
    IFS='|' read -r parsed_handle parsed_spec <<< "$parsed"
    [ "$parsed_handle" = "$expected_handle" ] && [ "$parsed_spec" = "$spec" ]
}
fq_codel_state_record() {
    [ -s "$FQ_CODEL_STATE" ] && [ ! -L "$FQ_CODEL_STATE" ] || return 1
    [ "$(head -n 1 "$FQ_CODEL_STATE" 2>/dev/null)" = "# fq-codel-state-v1" ] || return 1
    awk -F'|' -v wanted="$1" '$1 == wanted && NF == 3 {print; exit}' "$FQ_CODEL_STATE"
}
fq_codel_current_matches_snapshot() {
    local iface="$1" record saved_handle saved_spec current_record current_handle current_spec
    record=$(fq_codel_state_record "$iface") || return 1; IFS='|' read -r _ saved_handle saved_spec <<< "$record"
    fq_codel_spec_is_valid "$saved_handle" "$saved_spec" || return 1
    current_record=$(fq_codel_record_from_output "$(LC_ALL=C tc -d qdisc show dev "$iface" root 2>/dev/null)") || return 1
    IFS='|' read -r current_handle current_spec <<< "$current_record"
    [ "$saved_spec" = "$current_spec" ] && { [ "$saved_handle" = auto ] || [ "$saved_handle" = "$current_handle" ]; }
}
restore_fq_codel_root() {
    local iface="$1" record handle spec current_kind tc_command options=()
    record=$(fq_codel_state_record "$iface") || return 1; IFS='|' read -r _ handle spec <<< "$record"
    fq_codel_spec_is_valid "$handle" "$spec" || return 1; read -r -a options <<< "$spec"
    tc_command=(tc qdisc replace dev "$iface" root); [ "$handle" = auto ] || tc_command+=(handle "$handle")
    tc_command+=(fq_codel "${options[@]}"); "${tc_command[@]}" >/dev/null 2>&1 || return 1
    current_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    [ "$current_kind" = fq_codel ] && fq_codel_current_matches_snapshot "$iface"
}
tc_rate_mbit() {
    awk '
        {
            for (i = 1; i < NF; i++) {
                if ($i != "rate" || $(i + 1) !~ /^[0-9.]+[KMGTkmgt]?bit$/) continue
                value = $(i + 1); unit = value
                sub(/^[0-9.]+/, "", unit); sub(/bit$/, "", unit)
                number = value + 0
                if (unit == "K" || unit == "k") number /= 1000
                else if (unit == "G" || unit == "g") number *= 1000
                else if (unit == "T" || unit == "t") number *= 1000000
                else if (unit == "") number /= 1000000
                printf "%.3f\n", number; exit
            }
        }
    ' <<< "${1:-}"
}

default_route_identity() {
    local route="$1" token gateway="" device="" gateway_count=0 device_count=0 expect=""
    local route_tokens=()
    [ -n "$route" ] || return 1
    read -r -a route_tokens <<< "$route"
    for token in "${route_tokens[@]}"; do
        if [ -n "$expect" ]; then
            case "$expect" in
                via) gateway="$token"; gateway_count=$((gateway_count + 1)) ;;
                dev) device="$token"; device_count=$((device_count + 1)) ;;
            esac
            expect=""
            continue
        fi
        case "$token" in nexthop) return 1 ;; via|dev) expect="$token" ;; esac
    done
    [ "$device_count" -eq 1 ] && [ "$gateway_count" -le 1 ] || return 1
    printf 'dev=%s|via=%s\n' "$device" "$gateway"
}
if [ -s "$PROFILE_STATE" ]; then
    MSS_CLAMP_ENABLED=$(awk -F= '$1 == "mss_clamp" {print $2}' "$PROFILE_STATE")
    INITCWND=$(awk -F= '$1 == "initcwnd" {print $2}' "$PROFILE_STATE")
    INITRWND=$(awk -F= '$1 == "initrwnd" {print $2}' "$PROFILE_STATE")
    BUFFER_MB=$(awk -F= '$1 == "buffer_mb" {print $2}' "$PROFILE_STATE")
    CPU_COUNT=$(awk -F= '$1 == "cpu_count" {print $2}' "$PROFILE_STATE")
    CPU_COUNT=$(normalize_uint "$CPU_COUNT" 1 1000000 2>/dev/null) || CPU_COUNT=1
    TCP_RMEM=$(awk -F= '$1 == "tcp_rmem" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
    TCP_WMEM=$(awk -F= '$1 == "tcp_wmem" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
    SOMAXCONN=$(awk -F= '$1 == "somaxconn" {print $2}' "$PROFILE_STATE")
    SYN_BACKLOG=$(awk -F= '$1 == "tcp_max_syn_backlog" {print $2}' "$PROFILE_STATE")
    NETDEV_BACKLOG=$(awk -F= '$1 == "netdev_max_backlog" {print $2}' "$PROFILE_STATE")
    CONGESTION_CONTROL=$(awk -F= '$1 == "congestion_control" {print $2}' "$PROFILE_STATE")
else
    PROFILE_FAILED=1
fi
if normalized=$(normalize_uint "$BUFFER_MB" 1 512); then BUFFER_MB="$normalized"; else PROFILE_FAILED=1; BUFFER_MB=0; fi
if normalized=$(normalize_uint "$INITCWND" 0 1000000); then INITCWND="$normalized"; else PROFILE_FAILED=1; INITCWND=0; fi
if normalized=$(normalize_uint "$INITRWND" 0 1000000); then INITRWND="$normalized"; else PROFILE_FAILED=1; INITRWND=0; fi
if normalized=$(normalize_uint "$SOMAXCONN" 1 1000000000); then SOMAXCONN="$normalized"; else PROFILE_FAILED=1; SOMAXCONN=0; fi
if normalized=$(normalize_uint "$SYN_BACKLOG" 1 1000000000); then SYN_BACKLOG="$normalized"; else PROFILE_FAILED=1; SYN_BACKLOG=0; fi
if normalized=$(normalize_uint "$NETDEV_BACKLOG" 1 1000000000); then NETDEV_BACKLOG="$normalized"; else PROFILE_FAILED=1; NETDEV_BACKLOG=0; fi
case "$CONGESTION_CONTROL" in bbr|bbr2|bbr3) ;; *) PROFILE_FAILED=1; CONGESTION_CONTROL="" ;; esac
case "$MSS_CLAMP_ENABLED" in 0|1) ;; *) PROFILE_FAILED=1; MSS_CLAMP_ENABLED=0 ;; esac
[ -n "$TCP_RMEM" ] && [ -n "$TCP_WMEM" ] || PROFILE_FAILED=1
RMEM_MAX_BYTES=$(awk '{print $3}' <<< "$TCP_RMEM")
WMEM_MAX_BYTES=$(awk '{print $3}' <<< "$TCP_WMEM")
if normalized=$(normalize_uint "$RMEM_MAX_BYTES" 1 536870912); then RMEM_MAX_BYTES="$normalized"; else PROFILE_FAILED=1; RMEM_MAX_BYTES=0; fi
if normalized=$(normalize_uint "$WMEM_MAX_BYTES" 1 536870912); then WMEM_MAX_BYTES="$normalized"; else PROFILE_FAILED=1; WMEM_MAX_BYTES=0; fi
# 显式加载 BBR 并重新应用 sysctl，避免仅依赖发行版默认启动顺序
if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
fi
CORE_FAILED="$PROFILE_FAILED"
if command -v sysctl >/dev/null 2>&1 && [ -s "$SYSCTL_CONF" ]; then
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || CORE_FAILED=1
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "$CONGESTION_CONTROL" ] || CORE_FAILED=1
    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || CORE_FAILED=1
    [ "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)" = "0" ] || CORE_FAILED=1
    ACTUAL_CORE_WMEM=$(sysctl -n net.core.wmem_max 2>/dev/null)
    ACTUAL_CORE_RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null)
    ACTUAL_WMEM=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    ACTUAL_RMEM=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    [ "$ACTUAL_CORE_WMEM" = "$WMEM_MAX_BYTES" ] || CORE_FAILED=1
    [ "$ACTUAL_CORE_RMEM" = "$RMEM_MAX_BYTES" ] || CORE_FAILED=1
    [ "$ACTUAL_WMEM" = "$WMEM_MAX_BYTES" ] || CORE_FAILED=1
    [ "$ACTUAL_RMEM" = "$RMEM_MAX_BYTES" ] || CORE_FAILED=1
    if [ -n "$TCP_RMEM" ]; then
        [ "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{$1=$1; print}')" = "$TCP_RMEM" ] || CORE_FAILED=1
    fi
    if [ -n "$TCP_WMEM" ]; then
        [ "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{$1=$1; print}')" = "$TCP_WMEM" ] || CORE_FAILED=1
    fi
    if [[ "$SOMAXCONN" =~ ^[0-9]+$ ]] && [ "$SOMAXCONN" -gt 0 ]; then
        [ "$(sysctl -n net.core.somaxconn 2>/dev/null)" = "$SOMAXCONN" ] || CORE_FAILED=1
    fi
    if [[ "$SYN_BACKLOG" =~ ^[0-9]+$ ]] && [ "$SYN_BACKLOG" -gt 0 ]; then
        [ "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null)" = "$SYN_BACKLOG" ] || CORE_FAILED=1
    fi
    if [[ "$NETDEV_BACKLOG" =~ ^[0-9]+$ ]] && [ "$NETDEV_BACKLOG" -gt 0 ]; then
        [ "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)" = "$NETDEV_BACKLOG" ] || CORE_FAILED=1
    fi
else
    CORE_FAILED=1
fi
ROUTE_FAILED=0
if [ "$INITCWND" -gt 0 ] || [ "$INITRWND" -gt 0 ]; then
    if command -v ip >/dev/null 2>&1; then
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        current_identity=$(default_route_identity "$clean_route" 2>/dev/null || true)
        saved_identity=$(awk -F= '$1 == "route_identity" {sub(/^[^=]*=/, ""); print}' "$ROUTE_STATE" 2>/dev/null)
        if [ -z "$saved_identity" ]; then
            saved_route=$(awk -F= '$1 == "route" {sub(/^[^=]*=/, ""); print}' "$ROUTE_STATE" 2>/dev/null)
            saved_identity=$(default_route_identity "$saved_route" 2>/dev/null || true)
        fi
        [ -n "$saved_identity" ] && [ "$current_identity" = "$saved_identity" ] || ROUTE_FAILED=1
        current_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
        current_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
        [ -n "$current_initcwnd" ] || current_initcwnd=0
        [ -n "$current_initrwnd" ] || current_initrwnd=0
        if [ "$ROUTE_FAILED" -eq 0 ] && \
           { [ "$current_initcwnd" != "$INITCWND" ] || [ "$current_initrwnd" != "$INITRWND" ]; }; then
            route_args=()
            route_metrics=()
            case " $clean_route " in *" nexthop "*) ROUTE_FAILED=1 ;; esac
            read -r -a route_args <<< "$clean_route"
            [ "${#route_args[@]}" -gt 0 ] || ROUTE_FAILED=1
            [ "$INITCWND" -gt 0 ] && route_metrics+=(initcwnd "$INITCWND")
            [ "$INITRWND" -gt 0 ] && route_metrics+=(initrwnd "$INITRWND")
            if [ "$ROUTE_FAILED" -eq 0 ]; then
                ip route replace "${route_args[@]}" "${route_metrics[@]}" >/dev/null 2>&1 || ROUTE_FAILED=1
            fi
        fi
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        current_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
        current_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
        [ -n "$current_initcwnd" ] || current_initcwnd=0
        [ -n "$current_initrwnd" ] || current_initrwnd=0
        [ "$current_initcwnd" = "$INITCWND" ] && [ "$current_initrwnd" = "$INITRWND" ] || ROUTE_FAILED=1
    else
        ROUTE_FAILED=1
    fi
fi
# 只重放有完整恢复快照的 fq；失败时让启动服务返回非零，避免误报成功。
QDISC_FAILED=0
QDISC_CANDIDATES=0
if command -v tc >/dev/null 2>&1 && [ -s "$QDISC_STATE" ]; then
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|ifb*|dummy*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            *'|'*|*[[:space:]]*) continue;;
        esac
        operstate=$(cat "$d/operstate" 2>/dev/null || echo "unknown")
        case "$operstate" in
            down|lowerlayerdown|notpresent) continue ;;
        esac
        original_kind=$(awk -F '|' -v wanted="$dev" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
        [ -n "$original_kind" ] || continue
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$original_kind" in
            none|noqueue|pfifo_fast)
                QDISC_CANDIDATES=$((QDISC_CANDIDATES + 1))
                case "$root_kind" in
                    fq|''|noqueue|pfifo_fast) qdisc_set_fq "$dev" "$INITCWND" || QDISC_FAILED=1 ;;
                    *) QDISC_FAILED=1 ;;
                esac
                ;;
            fq)
                QDISC_CANDIDATES=$((QDISC_CANDIDATES + 1))
                [ "$root_kind" = fq ] || QDISC_FAILED=1
                ;;
            fq_codel)
                if fq_codel_state_record "$dev" >/dev/null 2>&1; then
                    QDISC_CANDIDATES=$((QDISC_CANDIDATES + 1))
                    case "$root_kind" in
                        fq|fq_codel) qdisc_set_fq "$dev" "$INITCWND" || QDISC_FAILED=1 ;;
                        *) QDISC_FAILED=1 ;;
                    esac
                else
                    [ "$root_kind" = fq_codel ] || QDISC_FAILED=1
                fi
                ;;
            mq)
                saved_leaf_kind=$(mq_state_leaf_kind "$dev" 2>/dev/null || true)
                case "$saved_leaf_kind" in
                    fq|fq_codel)
                        QDISC_CANDIDATES=$((QDISC_CANDIDATES + 1))
                        if [ "$root_kind" != mq ] || ! qdisc_set_fq "$dev" "$INITCWND"; then
                            QDISC_FAILED=1
                        fi
                        ;;
                    unsupported) [ "$root_kind" = mq ] || QDISC_FAILED=1 ;;
                    *) QDISC_FAILED=1 ;;
                esac
                ;;
            pfifo|codel|sfq)
                [ "$root_kind" = "$original_kind" ] || QDISC_FAILED=1
                ;;
            *)
                # 其他自定义队列未取得所有权，启动时保持现状。
                ;;
        esac
    done
    [ "$QDISC_CANDIDATES" -gt 0 ] || QDISC_FAILED=1
else
    QDISC_FAILED=1
fi
MSS_FAILED=0
if [ "$MSS_CLAMP_ENABLED" = "1" ]; then
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu -m comment --comment "bbr-direct-tune" >/dev/null 2>&1 && \
           ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu >/dev/null 2>&1; then
            iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
                --clamp-mss-to-pmtu -m comment --comment "bbr-direct-tune" >/dev/null 2>&1 || MSS_FAILED=1
        fi
    else
        MSS_FAILED=1
    fi
fi
[ "$CORE_FAILED" -eq 0 ] && [ "$QDISC_FAILED" -eq 0 ] && [ "$ROUTE_FAILED" -eq 0 ] && \
    [ "$MSS_FAILED" -eq 0 ] || exit 1
exit 0
APPLYEOF
    then
        ui_error "开机恢复配置创建失败"
        return 1
    fi
    if [ ! -s "$persist_script_tmp" ] || ! bash -n "$persist_script_tmp" || \
       ! finalize_managed_temp_file "$persist_script_tmp" "$PERSIST_SCRIPT" 755; then
        ui_error "开机恢复配置创建失败"
        return 1
    fi

    local persistence_ready=0
    local systemd_service_tmp="${SYSTEMD_SERVICE}.tmp.$$"
    local openrc_start_tmp="${OPENRC_START}.tmp.$$"
    local sysv_service_tmp="${SYSV_SERVICE}.tmp.$$"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if prepare_managed_temp_file "$systemd_service_tmp"; then
            cat > "$systemd_service_tmp" << EOF
[Unit]
Description=BBR Optimize - Restore tuning after boot
After=network-online.target systemd-sysctl.service ufw.service firewalld.service netfilter-persistent.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PERSIST_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
            if [ "$?" -eq 0 ] && \
               finalize_managed_temp_file "$systemd_service_tmp" "$SYSTEMD_SERVICE" 644 && \
               systemctl daemon-reload >/dev/null 2>&1 && \
               systemctl enable bbr-optimize-persist.service >/dev/null 2>&1 && \
               systemctl restart bbr-optimize-persist.service >/dev/null 2>&1 && \
               systemctl is-enabled --quiet bbr-optimize-persist.service && \
               systemctl is-active --quiet bbr-optimize-persist.service; then
                persistence_ready=1
            fi
        fi
    elif command -v rc-update >/dev/null 2>&1 && mkdir -p /etc/local.d 2>/dev/null; then
        if prepare_managed_temp_file "$openrc_start_tmp"; then
            cat > "$openrc_start_tmp" << EOF
#!/bin/sh
${PERSIST_SCRIPT}
EOF
            if [ "$?" -eq 0 ] && sh -n "$openrc_start_tmp" && \
               finalize_managed_temp_file "$openrc_start_tmp" "$OPENRC_START" 755; then
                if openrc_local_is_enabled || \
                   { ! openrc_other_start_files_exist && rc-update add local default >/dev/null 2>&1; }; then
                    if "$PERSIST_SCRIPT" >/dev/null 2>&1; then
                        persistence_ready=1
                    fi
                fi
            fi
        fi
    elif [ -d /etc/init.d ]; then
        if prepare_managed_temp_file "$sysv_service_tmp"; then
            cat > "$sysv_service_tmp" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          bbr-optimize-persist
# Required-Start:    \$network
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Restore BBR network tuning after boot
### END INIT INFO

case "\$1" in
    start|restart|force-reload)
        ${PERSIST_SCRIPT}
        exit \$?
        ;;
    stop)
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|force-reload}"
        exit 1
        ;;
esac
exit 0
EOF
            local sysv_registered=0
            if [ "$?" -eq 0 ] && sh -n "$sysv_service_tmp" && \
               finalize_managed_temp_file "$sysv_service_tmp" "$SYSV_SERVICE" 755; then
                if command -v update-rc.d >/dev/null 2>&1; then
                    update-rc.d bbr-optimize-persist defaults >/dev/null 2>&1 && sysv_registered=1
                elif command -v chkconfig >/dev/null 2>&1; then
                    chkconfig --add bbr-optimize-persist >/dev/null 2>&1 && \
                        chkconfig bbr-optimize-persist on >/dev/null 2>&1 && sysv_registered=1
                fi
                if [ "$sysv_registered" -eq 1 ] && "$SYSV_SERVICE" start >/dev/null 2>&1; then
                    persistence_ready=1
                fi
            fi
        fi
    fi

    if [ "$persistence_ready" -eq 1 ]; then
        ui_success "重启恢复已配置"
    else
        ui_warn "重启恢复未配置，请执行 status 复核调优是否生效"
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    ui_step 6 6 "完成验证"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_core_wmem=$(sysctl -n net.core.wmem_max 2>/dev/null)
    local actual_core_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    local actual_tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{$1=$1; print}')
    local actual_tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{$1=$1; print}')
    local expected_tcp_wmem="${tcp_wmem_min} ${tcp_wmem_default} ${wmem_buffer_bytes}"
    local expected_tcp_rmem="${tcp_rmem_min} ${tcp_rmem_default} ${rmem_buffer_bytes}"
    local actual_slow_start_after_idle=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
    local actual_somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null)
    local actual_syn_backlog=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null)
    local actual_netdev_backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)
    local actual_route=$(ip -4 route show default 2>/dev/null | head -1)
    local actual_initcwnd=$(echo "$actual_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    local actual_initrwnd=$(echo "$actual_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    [ -n "$actual_initcwnd" ] || actual_initcwnd=0
    [ -n "$actual_initrwnd" ] || actual_initrwnd=0
    local route_window_ready=0
    if { [ "$initcwnd" -eq 0 ] && [ "$initrwnd" -eq 0 ]; } || \
       { [ "$actual_initcwnd" = "$initcwnd" ] && [ "$actual_initrwnd" = "$initrwnd" ]; }; then
        route_window_ready=1
    fi
    local qdisc_runtime_ready=0
    runtime_qdisc_is_ready && qdisc_runtime_ready=1

    # 最终判断：核心运行值或实际 qdisc 应用失败时，命令返回非零。
    local apply_result=0
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "$congestion_control" ] && \
       [ "$actual_core_wmem" = "$wmem_buffer_bytes" ] && [ "$actual_core_rmem" = "$rmem_buffer_bytes" ] && \
       [ "$actual_wmem" = "$wmem_buffer_bytes" ] && [ "$actual_rmem" = "$rmem_buffer_bytes" ] && \
       [ "$actual_tcp_wmem" = "$expected_tcp_wmem" ] && [ "$actual_tcp_rmem" = "$expected_tcp_rmem" ] && \
       [ "$actual_slow_start_after_idle" = "0" ] && \
       [ "$actual_somaxconn" = "$somaxconn" ] && [ "$actual_syn_backlog" = "$syn_backlog" ] && \
       [ "$actual_netdev_backlog" = "$netdev_backlog" ] && [ "$route_window_ready" -eq 1 ] && \
       [ "$sysctl_rc" -eq 0 ] && [ "$qdisc_apply_failed" -eq 0 ] && \
       [ "$qdisc_runtime_ready" -eq 1 ] && \
       [ "$route_apply_failed" -eq 0 ] && [ "$mss_apply_failed" -eq 0 ] && \
       [ "$persistence_ready" -eq 1 ]; then
        ui_success "核心 TCP 参数与重启恢复已生效"
    else
        apply_result=1
        ui_error "网络调优未完全生效，请执行 status 复核调优是否生效"
    fi
    [ "$apply_result" -ne 0 ] || ui_success "网络调优流程已完整生效"
    if ! cleanup_test_tools_after_tuning; then
        apply_result=1
    fi
    return "$apply_result"
}

restore_disabled_sysctl_files() {
    local original_file disabled_file restored_count=0 failed_count=0

    [ -s "$CONFLICT_STATE" ] || return 0
    while IFS='|' read -r original_file disabled_file; do
        [ -n "$original_file" ] && [ -n "$disabled_file" ] || continue
        if [ "$original_file" = "edit" ]; then
            case "$disabled_file" in
                /etc/sysctl.d/*.conf) ;;
                *)
                    ui_warn "拒绝恢复路径异常的 sysctl 配置：$disabled_file"
                    failed_count=$((failed_count + 1))
                    continue
                    ;;
            esac
            if [ -f "$disabled_file" ] && [ ! -L "$disabled_file" ]; then
                if sed -i 's/^# bbr-direct-tune disabled: //' "$disabled_file" 2>/dev/null; then
                    restored_count=$((restored_count + 1))
                else
                    ui_warn "无法恢复 $disabled_file 中被标记的冲突项"
                    failed_count=$((failed_count + 1))
                fi
            else
                ui_warn "被编辑的 sysctl 配置已不存在或类型变化：$disabled_file"
                failed_count=$((failed_count + 1))
            fi
            continue
        fi
        if [ -f "$disabled_file" ] || [ -L "$disabled_file" ]; then
            if [ ! -e "$original_file" ] && [ ! -L "$original_file" ]; then
                if mv "$disabled_file" "$original_file" 2>/dev/null; then
                    restored_count=$((restored_count + 1))
                else
                    ui_warn "无法恢复 $original_file；旧文件仍位于 $disabled_file"
                    failed_count=$((failed_count + 1))
                fi
            else
                ui_warn "未覆盖后来创建的 $original_file；旧文件保留在 $disabled_file"
                failed_count=$((failed_count + 1))
            fi
        elif [ -e "$disabled_file" ]; then
            ui_warn "拒绝恢复类型异常的禁用配置：$disabled_file"
            failed_count=$((failed_count + 1))
        elif [ ! -e "$original_file" ] && [ ! -L "$original_file" ]; then
            ui_warn "无法恢复 $original_file；记录的禁用配置已不存在：$disabled_file"
            failed_count=$((failed_count + 1))
        fi
    done < "$CONFLICT_STATE"
    [ "$restored_count" -gt 0 ] && ui_success "已恢复 ${restored_count} 个 sysctl 冲突配置"
    [ "$failed_count" -eq 0 ]
}

restore_runtime_snapshot() {
    local setting key restored_count=0 failed_count=0

    [ -s "$SYSCTL_STATE" ] || return 0
    while IFS= read -r setting; do
        [ -n "$setting" ] || continue
        key=${setting%%=*}
        # 兼容旧版快照：已退役的全局 TCP 参数也必须能恢复原值。
        sysctl_key_is_restorable "$key" || continue
        if sysctl -w "$setting" >/dev/null 2>&1; then
            restored_count=$((restored_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done < "$SYSCTL_STATE"
    ui_success "已恢复 ${restored_count} 项调优前 sysctl 运行值"
    [ "$failed_count" -gt 0 ] && ui_warn "${failed_count} 项参数当前内核不支持，已跳过"
    [ "$failed_count" -eq 0 ]
}

restore_retired_sysctl_keys_after_apply() {
    local key value restored=0

    [ -s "$SYSCTL_STATE" ] || return 0
    for key in "${RETIRED_SYSCTL_KEYS[@]}"; do
        value=$(awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$SYSCTL_STATE")
        [ -n "$value" ] || continue
        if sysctl -w "$key=$value" >/dev/null 2>&1; then
            restored=$((restored + 1))
        else
            ui_warn "旧版参数 $key 未能恢复原值"
        fi
    done
    [ "$restored" -gt 0 ] && ui_info "已恢复 ${restored} 项旧版全局 TCP 参数原值"
    return 0
}

restore_qdisc_snapshot() {
    local dev qdisc_kind current_kind current_leaf_kind saved_leaf_kind
    local restored_count=0 failed_count=0

    [ -s "$QDISC_STATE" ] || return 0
    if ! command -v tc >/dev/null 2>&1; then
        if awk -F '|' 'NF >= 2 && $1 !~ /^#/ && $2 ~ /^(none|pfifo_fast)?$/ {found=1} END {exit !found}' "$QDISC_STATE" 2>/dev/null; then
            ui_warn "缺少 tc，无法完成网卡队列恢复"
            return 1
        fi
        return 0
    fi
    while IFS='|' read -r dev qdisc_kind; do
        [ "$dev" = "# qdisc-state-v2" ] && continue
        [ -e "/sys/class/net/$dev" ] || continue
        current_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$qdisc_kind" in
            fq)
                # apply 不会重建原本的 fq，保留其参数和运行统计。
                ;;
            mq)
                saved_leaf_kind=$(mq_state_leaf_kind "$dev" 2>/dev/null)
                if [ "$current_kind" != "mq" ]; then
                    ui_warn "网卡 $dev 的 mq 结构已被后续修改，未自动覆盖"
                    failed_count=$((failed_count + 1))
                    continue
                fi
                if [ "$saved_leaf_kind" = "unsupported" ]; then
                    continue
                fi
                if mq_current_matches_snapshot "$dev"; then
                    continue
                fi
                current_leaf_kind=$(mq_leaf_kind "$dev" 2>/dev/null || true)
                if [ "$current_leaf_kind" = "fq" ] && qdisc_restore_mq "$dev"; then
                    restored_count=$((restored_count + 1))
                else
                    ui_warn "网卡 $dev 的 mq 叶队列已被后续修改，未自动覆盖"
                    failed_count=$((failed_count + 1))
                fi
                ;;
            none|''|noqueue|pfifo_fast)
                if { [ "$qdisc_kind" = "pfifo_fast" ] || [ "$qdisc_kind" = "noqueue" ]; } && \
                   [ "$current_kind" = "$qdisc_kind" ]; then
                    continue
                fi
                if { [ "$qdisc_kind" = "none" ] || [ -z "$qdisc_kind" ]; } && [ "$current_kind" != "fq" ]; then
                    # 删除脚本添加的 fq 后，内核可能显示为空、noqueue 或重新挂载默认队列。
                    continue
                fi
                if [ "$current_kind" != "fq" ]; then
                    ui_warn "网卡 $dev 当前队列已变为 ${current_kind:-未知}，为避免覆盖后续修改未恢复 $qdisc_kind"
                    failed_count=$((failed_count + 1))
                    continue
                fi
                if [ "$qdisc_kind" = "none" ] || [ -z "$qdisc_kind" ] || [ "$qdisc_kind" = "noqueue" ]; then
                    if tc qdisc del dev "$dev" root >/dev/null 2>&1; then
                        restored_count=$((restored_count + 1))
                    else
                        ui_warn "网卡 $dev 的原空队列状态未能自动恢复"
                        failed_count=$((failed_count + 1))
                    fi
                elif tc qdisc replace dev "$dev" root "$qdisc_kind" >/dev/null 2>&1; then
                    restored_count=$((restored_count + 1))
                else
                    ui_warn "网卡 $dev 的原队列 $qdisc_kind 未能自动恢复"
                    failed_count=$((failed_count + 1))
                fi
                ;;
            fq_codel)
                case "$current_kind" in
                    fq_codel)
                        if fq_codel_state_record "$dev" >/dev/null 2>&1 && ! fq_codel_current_matches_snapshot "$dev"; then
                            ui_warn "网卡 $dev 的 fq_codel 参数未恢复到调优前快照"
                            failed_count=$((failed_count + 1))
                        fi
                        ;;
                    fq)
                        if fq_codel_state_record "$dev" >/dev/null 2>&1 && restore_fq_codel_root "$dev"; then
                            restored_count=$((restored_count + 1))
                        else
                            ui_warn "网卡 $dev 的原 fq_codel 队列未能按参数快照恢复"
                            failed_count=$((failed_count + 1))
                        fi
                        ;;
                    *)
                        ui_warn "网卡 $dev 的原队列为 fq_codel，当前已变为 ${current_kind:-未知}，未自动覆盖"
                        failed_count=$((failed_count + 1))
                        ;;
                esac
                ;;
            pfifo|codel|sfq)
                # apply 不会替换这些队列，因此恢复阶段只核对，不修改。
                if [ "$current_kind" != "$qdisc_kind" ]; then
                    ui_warn "网卡 $dev 的原队列为 $qdisc_kind，当前已变为 ${current_kind:-未知}，未自动覆盖"
                    failed_count=$((failed_count + 1))
                fi
                ;;
            *)
                # 自定义队列从未被 apply 改动，恢复阶段也不重建。
                ui_info "网卡 $dev 的自定义队列 $qdisc_kind 未被脚本改动，已保留"
                ;;
        esac
    done < "$QDISC_STATE"
    [ "$restored_count" -gt 0 ] && ui_success "已恢复 ${restored_count} 个由脚本替换的网卡队列"
    [ "$failed_count" -eq 0 ]
}

restore_route_snapshot() {
    local initcwnd initrwnd current_initcwnd current_initrwnd saved_route saved_identity
    local current_route clean_route current_identity applied_initcwnd applied_initrwnd normalized_value
    local applied_state_valid=0
    local route_metrics=()
    local route_args=()

    [ -s "$ROUTE_STATE" ] || return 0
    initcwnd=$(awk -F= '$1 == "initcwnd" {print $2}' "$ROUTE_STATE")
    initrwnd=$(awk -F= '$1 == "initrwnd" {print $2}' "$ROUTE_STATE")
    saved_identity=$(awk -F= '$1 == "route_identity" {sub(/^[^=]*=/, ""); print}' "$ROUTE_STATE")
    saved_route=$(awk -F= '$1 == "route" {sub(/^[^=]*=/, ""); print}' "$ROUTE_STATE")
    normalized_value=$(normalize_uint "$initcwnd" 0 1000000) || normalized_value=0
    initcwnd="$normalized_value"
    normalized_value=$(normalize_uint "$initrwnd" 0 1000000) || normalized_value=0
    initrwnd="$normalized_value"

    if [ -s "$PROFILE_STATE" ]; then
        applied_initcwnd=$(awk -F= '$1 == "initcwnd" {print $2}' "$PROFILE_STATE")
        applied_initrwnd=$(awk -F= '$1 == "initrwnd" {print $2}' "$PROFILE_STATE")
        if applied_initcwnd=$(normalize_uint "$applied_initcwnd" 0 1000000) && \
           applied_initrwnd=$(normalize_uint "$applied_initrwnd" 0 1000000); then
            applied_state_valid=1
        fi
    fi
    if [ "$applied_state_valid" -eq 1 ] && \
       [ "$applied_initcwnd" = "$initcwnd" ] && [ "$applied_initrwnd" = "$initrwnd" ]; then
        # 脚本实际未改变该路由，不应干预之后由管理员设置的窗口。
        return 0
    fi
    if ! command -v ip >/dev/null 2>&1; then
        ui_warn "缺少路由工具，无法确认初始窗口已恢复"
        return 1
    fi
    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    current_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    current_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    [ -n "$current_initcwnd" ] || current_initcwnd=0
    [ -n "$current_initrwnd" ] || current_initrwnd=0
    if [ "$current_initcwnd" = "$initcwnd" ] && [ "$current_initrwnd" = "$initrwnd" ]; then
        return 0
    fi
    # 快照时没有默认路由，说明脚本当时也没有取得该路由的修改权。
    [ -n "$saved_route" ] || return 0
    if [ -z "$current_route" ]; then
        ui_warn "默认路由已不存在，未自动恢复初始窗口"
        return 1
    fi
    if [ "$applied_state_valid" -ne 1 ] || \
       [ "$current_initcwnd" != "$applied_initcwnd" ] || [ "$current_initrwnd" != "$applied_initrwnd" ]; then
        ui_warn "默认路由窗口已被后续修改，未自动覆盖"
        return 1
    fi
    clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    [ -n "$saved_identity" ] || saved_identity=$(default_route_identity "$saved_route" 2>/dev/null || true)
    current_identity=$(default_route_identity "$clean_route" 2>/dev/null || true)
    if [ -z "$saved_identity" ] || [ "$current_identity" != "$saved_identity" ]; then
        ui_warn "默认路由已发生变化，未自动套用旧状态"
        return 1
    fi
    read -r -a route_args <<< "$clean_route"
    [ "${#route_args[@]}" -gt 0 ] || return 1
    [ "$initcwnd" -gt 0 ] && route_metrics+=(initcwnd "$initcwnd")
    [ "$initrwnd" -gt 0 ] && route_metrics+=(initrwnd "$initrwnd")
    if ip route replace "${route_args[@]}" "${route_metrics[@]}" >/dev/null 2>&1; then
        ui_success "已恢复默认路由初始窗口"
        return 0
    else
        ui_warn "默认路由初始窗口未能自动恢复"
        return 1
    fi
}

restore_rps_snapshot() {
    local state_path value restored_count=0 failed_count=0

    [ -s "$RPS_STATE" ] || return 0
    while IFS='|' read -r state_path value; do
        [ -f "$state_path" ] || continue
        if printf '%s\n' "$value" > "$state_path" 2>/dev/null; then
            restored_count=$((restored_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done < "$RPS_STATE"
    [ "$restored_count" -gt 0 ] && ui_success "已恢复 RPS/RFS 原始状态"
    [ "$failed_count" -eq 0 ]
}

restore_thp_snapshot() {
    local thp_mode

    [ -s "$THP_STATE" ] || return 0
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] || return 0
    thp_mode=$(head -1 "$THP_STATE")
    if [ -n "$thp_mode" ] && printf '%s\n' "$thp_mode" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
        ui_success "已恢复透明大页模式为 $thp_mode"
        return 0
    fi
    ui_warn "透明大页模式未能自动恢复"
    return 1
}

cleanup_state_snapshot() {
    [ "$STATE_DIR" = "/var/lib/bbr-direct-tune" ] || return 1
    rm -rf -- "$STATE_DIR" || return 1
    [ ! -e "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]
}

current_script_path() {
    local script_source="${BASH_SOURCE[0]:-}"
    local script_dir script_name

    [ -n "$script_source" ] || return 1
    case "$script_source" in
        /dev/fd/*|/proc/*/fd/*) return 1 ;;
    esac
    script_dir=$(cd -P -- "$(dirname -- "$script_source")" 2>/dev/null && pwd) || return 1
    script_name=$(basename -- "$script_source")
    script_source="${script_dir}/${script_name}"
    [ -f "$script_source" ] || return 1
    printf '%s\n' "$script_source"
}

remove_tuning_files() {
    local path
    local remove_failed=0
    local paths=(
        "$SYSTEMD_SERVICE"
        "/etc/systemd/system/multi-user.target.wants/bbr-optimize-persist.service"
        "$OPENRC_START"
        "$SYSV_SERVICE"
        "$PERSIST_SCRIPT"
        "$MODULES_CONF"
        "$SYSCTL_CONF"
    )

    for path in "${paths[@]}"; do
        if { [ -e "$path" ] || [ -L "$path" ]; } && ! rm -f -- "$path"; then
            ui_warn "无法删除残留文件：$path"
            remove_failed=1
        fi
    done

    for path in /etc/rc*.d/[SK][0-9][0-9]bbr-optimize-persist \
        /etc/rc.d/rc*.d/[SK][0-9][0-9]bbr-optimize-persist; do
        [ -L "$path" ] || continue
        if ! rm -f -- "$path"; then
            ui_warn "无法删除 SysV 启动残留：$path"
            remove_failed=1
        fi
    done
    [ "$remove_failed" -eq 0 ]
}

cleanup_known_backup_residuals() {
    local path cleanup_failed=0

    for path in /etc/security/limits.conf.bak.bbr-upgrade.* \
        /etc/security/limits.conf.bak.bbr-restore.* \
        /etc/sysctl.conf.bak.before-restore.* \
        /etc/sysctl.conf.bak.original; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        if ! rm -f -- "$path"; then
            ui_warn "无法删除脚本旧备份：$path"
            cleanup_failed=1
        fi
    done
    [ "$cleanup_failed" -eq 0 ]
}

read_tcp_retrans_counters() {
    local stats out retrans

    if command -v nstat >/dev/null 2>&1; then
        stats=$(LC_ALL=C nstat -asz TcpOutSegs TcpRetransSegs 2>/dev/null || true)
        out=$(awk '$1 == "TcpOutSegs" {print $2; exit}' <<< "$stats")
        retrans=$(awk '$1 == "TcpRetransSegs" {print $2; exit}' <<< "$stats")
        if [[ "$out" =~ ^[0-9]+$ && "$retrans" =~ ^[0-9]+$ ]]; then
            printf '%s %s\n' "$out" "$retrans"
            return 0
        fi
    fi

    [ -r /proc/net/snmp ] || return 1
    awk '
        $1 == "Tcp:" && $2 == "RtoAlgorithm" {
            for (i = 2; i <= NF; i++) column[$i] = i
            if (getline <= 0 || $1 != "Tcp:" ||
                !("OutSegs" in column) || !("RetransSegs" in column)) exit 1
            print $(column["OutSegs"]), $(column["RetransSegs"])
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' /proc/net/snmp
}

read_tcpext_counters() {
    [ -r /proc/net/netstat ] || return 1
    awk '
        $1 == "TcpExt:" && $2 != "" {
            for (i = 2; i <= NF; i++) column[$i] = i
            if (getline <= 0 || $1 != "TcpExt:") exit 1
            names[1]="TCPTimeouts"; names[2]="TCPFastRetrans"; names[3]="TCPSynRetrans"
            names[4]="ListenOverflows"; names[5]="ListenDrops"; names[6]="TCPAbortOnMemory"
            names[7]="TCPBacklogDrop"; names[8]="TCPRcvQDrop"
            for (n = 1; n <= 8; n++) {
                if (names[n] in column) value=$(column[names[n]])
                else value="-"
                printf "%s%s", value, (n == 8 ? ORS : OFS)
            }
            found=1
            exit
        }
        END {if (!found) exit 1}
    ' /proc/net/netstat
}

read_softnet_counters() {
    local processed_hex dropped_hex squeeze_hex rest
    local processed=0 dropped=0 squeeze=0 rows=0

    [ -r /proc/net/softnet_stat ] || return 1
    while read -r processed_hex dropped_hex squeeze_hex rest; do
        [[ "$processed_hex" =~ ^[0-9A-Fa-f]+$ && "$dropped_hex" =~ ^[0-9A-Fa-f]+$ &&
           "$squeeze_hex" =~ ^[0-9A-Fa-f]+$ ]] || continue
        processed=$((processed + 16#$processed_hex))
        dropped=$((dropped + 16#$dropped_hex))
        squeeze=$((squeeze + 16#$squeeze_hex))
        rows=$((rows + 1))
    done < /proc/net/softnet_stat
    [ "$rows" -gt 0 ] || return 1
    printf '%s %s %s\n' "$processed" "$dropped" "$squeeze"
}

read_qdisc_counters() {
    local dev="$1" root_kind

    root_kind=$(LC_ALL=C tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
    [ -n "$root_kind" ] || return 1
    LC_ALL=C tc -s qdisc show dev "$dev" 2>/dev/null |
        awk -v root="$root_kind" '
            function number(value) {
                gsub(/[^0-9]/, "", value)
                return value == "" ? 0 : value + 0
            }
            $1 == "qdisc" {
                use = 0
                if (root == "mq") {
                    use = $2 != "mq" && $2 != "ingress" && $2 != "clsact" &&
                          $0 !~ /(^|[[:space:]])root([[:space:]]|$)/
                } else {
                    use = $0 ~ /(^|[[:space:]])root([[:space:]]|$)/
                }
                next
            }
            use && $1 == "Sent" {
                packets += number($4)
                for (i = 1; i < NF; i++) {
                    key = $i
                    gsub(/[^[:alpha:]_]/, "", key)
                    if (key == "dropped") dropped += number($(i + 1))
                    else if (key == "requeues") requeues += number($(i + 1))
                }
                found = 1
            }
            END {
                if (!found) exit 1
                printf "%.0f %.0f %.0f\n", packets, dropped, requeues
            }
        '
}

show_network_counters() {
    local out retrans retrans_ratio processed softnet_dropped softnet_squeeze
    local tcp_inuse tcp_orphan tcp_tw tcp_alloc tcp_mem
    local tcp_timeouts tcp_fast_retrans tcp_syn_retrans listen_overflows listen_drops tcp_abort_memory tcp_backlog_drop tcp_rcvq_drop
    local dev qdisc_packets qdisc_dropped qdisc_requeues
    local qdisc_shown=0

    ui_card_start "网络栈累计计数"
    if read -r out retrans < <(read_tcp_retrans_counters); then
        if [ "$out" -gt 0 ]; then
            retrans_ratio=$(awk -v retrans="$retrans" -v out="$out" 'BEGIN {printf "%.3f%%", retrans * 100 / out}')
            ui_kv "TCP 重传段/发出段" "$retrans / $out（$retrans_ratio）"
        else
            ui_kv "TCP 重传段/发出段" "无有效样本"
        fi
    else
        ui_kv "TCP 重传段/发出段" "无法检查"
    fi

    if read -r processed softnet_dropped softnet_squeeze < <(read_softnet_counters); then
        ui_kv "softnet 处理/丢弃/挤压" "$processed / $softnet_dropped / $softnet_squeeze"
    else
        ui_kv "softnet 处理/丢弃" "无法检查"
    fi

    if read -r tcp_inuse tcp_orphan tcp_tw tcp_alloc tcp_mem < <(read_tcp_socket_summary); then
        ui_kv "TCP inuse/orphan/TW" "$tcp_inuse / $tcp_orphan / $tcp_tw"
        ui_kv "TCP alloc/mem pages" "$tcp_alloc / $tcp_mem"
    else
        ui_kv "TCP socket 摘要" "无法检查"
    fi
    if read -r tcp_timeouts tcp_fast_retrans tcp_syn_retrans listen_overflows listen_drops tcp_abort_memory tcp_backlog_drop tcp_rcvq_drop < <(read_tcpext_counters); then
        ui_kv "TcpExt 超时/快重传/SYN重传" "$tcp_timeouts / $tcp_fast_retrans / $tcp_syn_retrans"
        ui_kv "listen 溢出/丢弃" "$listen_overflows / $listen_drops"
        ui_kv "内存中止/backlog/RcvQ 丢弃" "$tcp_abort_memory / $tcp_backlog_drop / $tcp_rcvq_drop"
    else
        ui_kv "TcpExt" "无法检查"
    fi

    if command -v tc >/dev/null 2>&1; then
        for dev in $(eligible_ifaces); do
            if read -r qdisc_packets qdisc_dropped qdisc_requeues < <(read_qdisc_counters "$dev"); then
                ui_kv "qdisc ${dev}" "发送 $qdisc_packets / 丢弃 $qdisc_dropped / 重入队 $qdisc_requeues"
            else
                ui_kv "qdisc ${dev}" "无法检查"
            fi
            qdisc_shown=$((qdisc_shown + 1))
        done
        [ "$qdisc_shown" -gt 0 ] || ui_kv "qdisc" "未发现可管理网卡"
    else
        ui_kv "qdisc" "无法检查（缺少 tc）"
    fi
    ui_card_end
    ui_info "TCP 是全机汇总，softnet 是本机接收软中断，qdisc 是本机出口；均不等同于端到端丢包率"
    ui_info "请在相同负载前后比较增量，按 Δ重传段/Δ发出段计算；计数变小则基线无效"
    ui_info "TCP/softnet 通常自开机累计，qdisc 自创建或重置累计；重新入队不等同于丢包"
}

read_tcp_socket_summary() {
    [ -r /proc/net/sockstat ] || return 1
    awk '
        $1 == "TCP:" {
            for (i = 2; i < NF; i += 2) value[$i] = $(i + 1)
            printf "%s %s %s %s %s\n", value["inuse"]+0, value["orphan"]+0,
                value["tw"]+0, value["alloc"]+0, value["mem"]+0
            found=1
            exit
        }
        END {if (!found) exit 1}
    ' /proc/net/sockstat
}

read_iface_counter() {
    local iface="$1" key="$2" value

    case "$key" in
        rx_packets|tx_packets|rx_dropped|tx_dropped|rx_errors|tx_errors) ;;
        *) return 1 ;;
    esac
    [ -r "/sys/class/net/$iface/statistics/$key" ] || return 1
    read -r value < "/sys/class/net/$iface/statistics/$key" || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

count_iface_queues() {
    local iface="$1" direction="$2" queue count=0

    case "$direction" in rx|tx) ;; *) return 1 ;; esac
    for queue in "/sys/class/net/$iface/queues/${direction}-"*; do
        [ -d "$queue" ] || continue
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

count_active_queue_masks() {
    local iface="$1" direction="$2" mask_file mask count=0

    case "$direction" in
        rps) mask_file="rps_cpus"; direction="rx" ;;
        xps) mask_file="xps_cpus"; direction="tx" ;;
        *) return 1 ;;
    esac
    for mask_file in "/sys/class/net/$iface/queues/${direction}-"*/"$mask_file"; do
        [ -r "$mask_file" ] || continue
        read -r mask < "$mask_file" || continue
        if [[ "$mask" =~ [1-9A-Fa-f] ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

show_iface_queue_diagnostics() {
    local iface mtu txqlen rx_queues tx_queues rps_queues xps_queues
    local rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors shown=0

    ui_card_start "网卡与队列诊断"
    for iface in $(eligible_ifaces); do
        mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "未知")
        txqlen=$(cat "/sys/class/net/$iface/tx_queue_len" 2>/dev/null || echo "未知")
        rx_queues=$(count_iface_queues "$iface" rx 2>/dev/null || echo 0)
        tx_queues=$(count_iface_queues "$iface" tx 2>/dev/null || echo 0)
        rps_queues=$(count_active_queue_masks "$iface" rps 2>/dev/null || echo 0)
        xps_queues=$(count_active_queue_masks "$iface" xps 2>/dev/null || echo 0)
        rx_packets=$(read_iface_counter "$iface" rx_packets 2>/dev/null || echo "未知")
        tx_packets=$(read_iface_counter "$iface" tx_packets 2>/dev/null || echo "未知")
        rx_dropped=$(read_iface_counter "$iface" rx_dropped 2>/dev/null || echo "未知")
        tx_dropped=$(read_iface_counter "$iface" tx_dropped 2>/dev/null || echo "未知")
        rx_errors=$(read_iface_counter "$iface" rx_errors 2>/dev/null || echo "未知")
        tx_errors=$(read_iface_counter "$iface" tx_errors 2>/dev/null || echo "未知")
        ui_kv "$iface MTU/txqlen" "$mtu / $txqlen"
        ui_kv "$iface RX/TX 队列" "$rx_queues / $tx_queues（RPS $rps_queues / XPS $xps_queues 活跃）"
        ui_kv "$iface RX 包/丢弃/错误" "$rx_packets / $rx_dropped / $rx_errors"
        ui_kv "$iface TX 包/丢弃/错误" "$tx_packets / $tx_dropped / $tx_errors"
        shown=$((shown + 1))
    done
    [ "$shown" -gt 0 ] || ui_kv "网卡" "未发现可诊断的物理出口接口"
    ui_card_end
    ui_info "网卡和队列计数通常是累计值，应在相同负载前后比较增量"
}

resolve_diagnostic_address() {
    local host="$1" family="$2" address=""

    case "$family:$host" in
        4:*:*) return 1 ;;
        6:*:*) printf '%s\n' "$host"; return 0 ;;
    esac
    if [ "$family" = "4" ] && [[ "$host" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        if [ "$family" = "4" ]; then
            address=$(getent ahostsv4 "$host" 2>/dev/null | awk '
                {
                    count=split($1, octet, ".")
                    if (count == 4 && octet[1] ~ /^[0-9]+$/ && octet[2] ~ /^[0-9]+$/ &&
                        octet[3] ~ /^[0-9]+$/ && octet[4] ~ /^[0-9]+$/) {
                        print $1
                        exit
                    }
                }
            ')
        else
            address=$(getent ahostsv6 "$host" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
        fi
        [ -n "$address" ] || return 1
        printf '%s\n' "$address"
        return 0
    fi
    # 没有 getent 时让 ping 按指定地址族解析域名；结果仍由探测成功与否决定。
    printf '%s\n' "$host"
}

route_mtu_for_target() {
    local family="$1" address="$2" route iface mtu="" minimum=68

    [ "$family" = "6" ] && minimum=1280
    if command -v ip >/dev/null 2>&1; then
        route=$(ip "-$family" route get "$address" 2>/dev/null | head -n 1)
        mtu=$(awk '{for(i=1;i<NF;i++) if($i=="mtu" && $(i+1)~/^[0-9]+$/){print $(i+1); exit}}' <<< "$route")
        iface=$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$route")
        if [ -z "$mtu" ] && [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
            mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || true)
        fi
    fi
    normalize_uint "$mtu" "$minimum" 65535 2>/dev/null || printf '1500\n'
}

probe_df_payload() {
    local family="$1" address="$2" payload="$3"
    local ping_command=(ping "-$family" -n -c 1 -W 2 -M "do" -s "$payload" "$address")

    command -v ping >/dev/null 2>&1 || return 2
    if command -v timeout >/dev/null 2>&1; then
        timeout 4 "${ping_command[@]}" >/dev/null 2>&1
    else
        "${ping_command[@]}" >/dev/null 2>&1
    fi
}

find_df_pmtu() {
    local family="$1" address="$2" local_mtu="$3" overhead minimum low=0 high mid

    case "$family" in
        4) overhead=28; minimum=68 ;;
        6) overhead=48; minimum=1280 ;;
        *) return 2 ;;
    esac
    local_mtu=$(normalize_uint "$local_mtu" "$minimum" 65535) || local_mtu=1500
    [ "$local_mtu" -gt 9000 ] && local_mtu=9000
    high=$((local_mtu - overhead))
    [ "$high" -ge 0 ] || return 2
    probe_df_payload "$family" "$address" 0 || return 2
    if probe_df_payload "$family" "$address" "$high"; then
        printf '%s\n' "$local_mtu"
        return 0
    fi
    while [ "$low" -lt "$high" ]; do
        mid=$(((low + high + 1) / 2))
        if probe_df_payload "$family" "$address" "$mid"; then
            low="$mid"
        else
            high=$((mid - 1))
        fi
    done
    printf '%s\n' $((low + overhead))
}

tracepath_pmtu() {
    local family="$1" address="$2" output pmtu
    local trace_command=(tracepath "-$family" -n "$address")

    command -v tracepath >/dev/null 2>&1 || return 2
    if command -v timeout >/dev/null 2>&1; then
        output=$(LC_ALL=C timeout 20 "${trace_command[@]}" 2>/dev/null || true)
    else
        output=$(LC_ALL=C "${trace_command[@]}" 2>/dev/null || true)
    fi
    pmtu=$(awk '{for(i=1;i<NF;i++) if($i=="pmtu" && $(i+1)~/^[0-9]+$/) value=$(i+1)} END{print value}' <<< "$output")
    if [ "$family" = "4" ]; then
        normalize_uint "$pmtu" 68 65535
    else
        normalize_uint "$pmtu" 1280 65535
    fi
}

show_pmtu_family_diagnostic() {
    local family="$1" host="$2" address local_mtu trace_mtu df_mtu mss header

    if ! address=$(resolve_diagnostic_address "$host" "$family"); then
        ui_kv "IPv${family} PMTU/MSS" "目标无可用 IPv${family} 地址"
        return 0
    fi
    local_mtu=$(route_mtu_for_target "$family" "$address")
    trace_mtu=$(tracepath_pmtu "$family" "$address" 2>/dev/null || true)
    df_mtu=$(find_df_pmtu "$family" "$address" "$local_mtu" 2>/dev/null || true)
    [ "$family" = "4" ] && header=40 || header=60
    if [[ "$df_mtu" =~ ^[0-9]+$ ]] && [ "$df_mtu" -gt "$header" ]; then
        mss=$((df_mtu - header))
        ui_kv "IPv${family} DF PMTU/MSS" "${df_mtu} / ${mss}（目标 ${address}）"
    else
        ui_kv "IPv${family} DF PMTU/MSS" "未完成（ICMP 被阻断、目标不可达或 ping 不支持 -M do）"
    fi
    if [[ "$trace_mtu" =~ ^[0-9]+$ ]] && [ "$trace_mtu" -gt "$header" ]; then
        ui_kv "IPv${family} tracepath" "PMTU ${trace_mtu} / MSS $((trace_mtu - header))"
    elif command -v tracepath >/dev/null 2>&1; then
        ui_kv "IPv${family} tracepath" "未返回有效 PMTU"
    else
        ui_kv "IPv${family} tracepath" "不可用（缺少 tracepath）"
    fi
}

show_pmtu_diagnostics() {
    local raw_target="$1" host

    ui_card_start "PMTU / MSS 主动诊断"
    if [ -z "$(trim_whitespace "$raw_target")" ]; then
        ui_kv "目标" "未提供；未发送探测包"
        ui_card_end
        ui_info "可运行 bash $0 diagnose <IP或域名> 执行 tracepath 与 DF ping"
        return 0
    fi
    if ! parse_rtt_target "$raw_target"; then
        ui_kv "目标" "格式无效"
        ui_card_end
        return 1
    fi
    host="$RTT_TARGET_HOST"
    ui_kv "目标" "$host"
    ui_card_end
    ui_card_start "PMTU 结果"
    show_pmtu_family_diagnostic 4 "$host"
    show_pmtu_family_diagnostic 6 "$host"
    ui_card_end
    ui_info "MSS 按无 TCP 选项的 IPv4=PMTU-40、IPv6=PMTU-60 推导；仅诊断，不自动修改 MTU/MSS"
}

run_network_diagnostics() {
    local target="${1:-${DIAG_TARGET:-}}"

    show_detailed_bbr_status
    echo ""
    show_pmtu_diagnostics "$target"
}

show_actual_qdisc_status() {
    local dev root_kind leaf_kinds shown=0

    command -v tc >/dev/null 2>&1 || {
        ui_kv "实际网卡队列" "无法检查（缺少 tc）"
        return 1
    }
    for dev in $(eligible_ifaces); do
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        [ -n "$root_kind" ] || root_kind="无/未知"
        if [ "$root_kind" = "mq" ]; then
            leaf_kinds=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2 != "mq" && $2 != "ingress" && $2 != "clsact" {print $2}' | sort -u | tr '\n' ',' | sed 's/,$//')
            ui_kv "网卡 ${dev}" "root mq / leaf ${leaf_kinds:-未知}"
        else
            ui_kv "网卡 ${dev}" "root ${root_kind}"
        fi
        shown=$((shown + 1))
    done
    if [ "$shown" -eq 0 ]; then
        ui_kv "实际网卡队列" "未发现可管理网卡"
        return 1
    fi
}

show_detailed_bbr_status() {
    ui_banner
    ui_card_start "当前运行状态"
    ui_kv "内核版本" "$(uname -r)"

    local congestion="未知"
    local qdisc="未知"
    local tcp_wmem="未知"
    local tcp_rmem="未知"
    local core_wmem_max="未知"
    local core_rmem_max="未知"
    local tcp_notsent_lowat="未知"
    local tcp_no_metrics_save="未知"
    local tcp_slow_start_after_idle="未知"
    local tcp_retries2="未知"
    local somaxconn="未知"
    local syn_backlog="未知"
    local netdev_backlog="未知"
    local active_bbr_sockets="未知"
    local current_route=""
    local current_initcwnd="未显式设置（由内核决定）"
    local current_initrwnd="未显式设置（由内核决定）"

    if command -v sysctl >/dev/null 2>&1; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "未知")
        tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "未知")
        core_wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "未知")
        core_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "未知")
        tcp_notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "未知")
        tcp_no_metrics_save=$(sysctl -n net.ipv4.tcp_no_metrics_save 2>/dev/null || echo "未知")
        tcp_slow_start_after_idle=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "未知")
        tcp_retries2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null || echo "未知")
        somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "未知")
        syn_backlog=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "未知")
        netdev_backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "未知")
    fi
    if command -v ss >/dev/null 2>&1; then
        active_bbr_sockets=$(LC_ALL=C ss -tinH state established 2>/dev/null | grep -Ec 'bbr(2|3)?:' || true)
    fi

    if command -v ip >/dev/null 2>&1; then
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        local route_initcwnd route_initrwnd
        route_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
        route_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
        [ -n "$route_initcwnd" ] && current_initcwnd=$route_initcwnd
        [ -n "$route_initrwnd" ] && current_initrwnd=$route_initrwnd
    fi

    ui_kv "拥塞控制" "$congestion"
    ui_kv "默认队列" "$qdisc"
    ui_kv "发送缓冲区" "$tcp_wmem"
    ui_kv "接收缓冲区" "$tcp_rmem"
    ui_kv "core 发送/接收上限" "$core_wmem_max / $core_rmem_max"
    ui_kv "未发送队列阈值" "${tcp_notsent_lowat}（保留系统值）"
    ui_kv "路径指标缓存" "${tcp_no_metrics_save}（保留系统值）"
    ui_kv "idle 后慢启动" "$tcp_slow_start_after_idle"
    ui_kv "tcp_retries2" "${tcp_retries2}（保留系统值）"
    ui_kv "listen/SYN/netdev" "$somaxconn / $syn_backlog / $netdev_backlog"
    ui_kv "活动 BBR 连接" "$active_bbr_sockets"
    ui_kv "初始 cwnd/rwnd" "$current_initcwnd / $current_initrwnd"
    show_actual_qdisc_status || true

    if [ -s "$PROFILE_STATE" ]; then
        local profile_name saved_region saved_region_name bandwidth_mbps rtt_ms rtt_source memory_mb cpu_count buffer_mb
        local rtt_stats rmem_buffer_mb wmem_buffer_mb softnet_delta_dropped softnet_delta_squeeze
        local effective_bandwidth bandwidth_limit_reason
        profile_name=$(awk -F= '$1 == "profile_name" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
        saved_region=$(awk -F= '$1 == "region" {print $2}' "$PROFILE_STATE")
        saved_region_name=$(awk -F= '$1 == "region_name" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
        [ -z "$saved_region_name" ] && [ -n "$saved_region" ] && saved_region_name=$(region_label "$saved_region")
        bandwidth_mbps=$(awk -F= '$1 == "bandwidth_mbps" {print $2}' "$PROFILE_STATE")
        effective_bandwidth=$(awk -F= '$1 == "effective_bandwidth_mbps" {print $2}' "$PROFILE_STATE")
        bandwidth_limit_reason=$(awk -F= '$1 == "bandwidth_limit_reason" {print $2}' "$PROFILE_STATE")
        rtt_ms=$(awk -F= '$1 == "rtt_ms" {print $2}' "$PROFILE_STATE")
        rtt_source=$(awk -F= '$1 == "rtt_source" {print $2}' "$PROFILE_STATE")
        memory_mb=$(awk -F= '$1 == "memory_mb" {print $2}' "$PROFILE_STATE")
        cpu_count=$(awk -F= '$1 == "cpu_count" {print $2}' "$PROFILE_STATE")
        buffer_mb=$(awk -F= '$1 == "buffer_mb" {print $2}' "$PROFILE_STATE")
        rtt_stats=$(awk -F= '
            $1 == "rtt_min" {min=$2} $1 == "rtt_median" {median=$2} $1 == "rtt_avg" {avg=$2}
            $1 == "rtt_p95" {p95=$2} $1 == "rtt_max" {max=$2} $1 == "rtt_count" {count=$2}
            END {if (min != "") print min "/" median "/" avg "/" p95 "/" max " ms（" count " 样本）"}
        ' "$PROFILE_STATE")
        rmem_buffer_mb=$(awk -F= '$1 == "rmem_buffer_mb" {print $2}' "$PROFILE_STATE")
        wmem_buffer_mb=$(awk -F= '$1 == "wmem_buffer_mb" {print $2}' "$PROFILE_STATE")
        softnet_delta_dropped=$(awk -F= '$1 == "softnet_delta_dropped" {print $2}' "$PROFILE_STATE")
        softnet_delta_squeeze=$(awk -F= '$1 == "softnet_delta_time_squeeze" {print $2}' "$PROFILE_STATE")
        [ -n "$profile_name" ] && ui_kv "调优场景" "$profile_name"
        [ -n "$saved_region_name" ] && ui_kv "链路地区" "$saved_region_name"
        ui_kv "目标链路" "${bandwidth_mbps:-未知} Mbps / ${rtt_ms:-未知} ms（${rtt_source:-旧版配置}）"
        if [ -n "$effective_bandwidth" ]; then
            ui_kv "参数计算带宽" "${effective_bandwidth} Mbps（${bandwidth_limit_reason:-nominal}，不等于出口限速）"
        fi
        [ -n "$rtt_stats" ] && ui_kv "RTT min/med/avg/p95/max" "$rtt_stats"
        if [ -n "$rmem_buffer_mb" ] && [ -n "$wmem_buffer_mb" ]; then
            ui_kv "CPU/内存/收发窗口" "${cpu_count:-未知} 核 / ${memory_mb:-未知} MB / ${rmem_buffer_mb}/${wmem_buffer_mb} MB"
        else
            ui_kv "CPU/内存/窗口" "${cpu_count:-未知} 核 / ${memory_mb:-未知} MB / ${buffer_mb:-未知} MB"
        fi
        [ -n "$softnet_delta_dropped" ] && ui_kv "应用时 softnet Δ" "丢弃 ${softnet_delta_dropped} / 挤压 ${softnet_delta_squeeze:-0}"
    fi


    if [ -f "$SYSCTL_CONF" ]; then
        ui_kv "配置文件" "${gl_lv}已生成${gl_bai}"
    else
        ui_kv "配置文件" "${gl_huang}未生成${gl_bai}"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && \
       systemctl is-enabled bbr-optimize-persist.service >/dev/null 2>&1; then
        if systemctl is-active --quiet bbr-optimize-persist.service >/dev/null 2>&1; then
            ui_kv "重启持久化" "${gl_lv}已启用并运行${gl_bai}"
        else
            ui_kv "重启持久化" "${gl_huang}已启用但未运行${gl_bai}"
        fi
    elif command -v rc-update >/dev/null 2>&1 && [ -x "$OPENRC_START" ] && \
         openrc_local_is_enabled; then
        ui_kv "重启持久化" "${gl_lv}已启用${gl_bai}"
    elif [ -x "$SYSV_SERVICE" ] && { compgen -G '/etc/rc*.d/S*bbr-optimize-persist' >/dev/null || \
         compgen -G '/etc/rc.d/rc*.d/S*bbr-optimize-persist' >/dev/null; }; then
        ui_kv "重启持久化" "${gl_lv}已启用${gl_bai}"
    else
        ui_kv "重启持久化" "${gl_huang}未启用${gl_bai}"
    fi

    if [ -f "$MODULES_CONF" ]; then
        ui_kv "BBR 模块自启" "${gl_lv}已配置${gl_bai}"
    else
        ui_kv "BBR 模块自启" "${gl_huang}未配置${gl_bai}"
    fi

    if [ -f "$SNAPSHOT_READY" ]; then
        local snapshot_mode
        snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || echo "legacy")
        if [ "$snapshot_mode" = "fresh" ]; then
            ui_kv "恢复保护" "${gl_lv}网络状态已保存${gl_bai}"
        else
            ui_kv "恢复保护" "${gl_huang}旧版兼容模式${gl_bai}"
        fi
    else
        ui_kv "恢复保护" "${gl_hui}尚未创建${gl_bai}"
    fi
    ui_card_end
    show_network_counters
    show_iface_queue_diagnostics
}

runtime_qdisc_is_ready() {
    local dev original_kind current_kind saved_leaf_kind candidates=0
    command -v tc >/dev/null 2>&1 && [ -s "$QDISC_STATE" ] || return 1
    for dev in $(eligible_ifaces); do
        original_kind=$(awk -F '|' -v wanted="$dev" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
        [ -n "$original_kind" ] || return 1
        current_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        candidates=$((candidates + 1))
        case "$original_kind" in
            none|noqueue|pfifo_fast|fq_codel)
                [ "$current_kind" = "fq" ] || return 1
                ;;
            fq|pfifo|codel|sfq)
                [ "$current_kind" = "$original_kind" ] || return 1
                ;;
            mq)
                [ "$current_kind" = "mq" ] || return 1
                saved_leaf_kind=$(mq_state_leaf_kind "$dev" 2>/dev/null || true)
                case "$saved_leaf_kind" in
                    fq|fq_codel) [ "$(mq_leaf_kind "$dev" 2>/dev/null)" = "fq" ] || return 1 ;;
                    # unsupported 叶队列从未被脚本接管；根类型未变即保持原状。
                    unsupported) : ;;
                    *) return 1 ;;
                esac
                ;;
            *) [ "$current_kind" = "$original_kind" ] || return 1 ;;
        esac
    done
    [ "$candidates" -gt 0 ]
}

tuning_persistence_is_ready() {
    [ -x "$PERSIST_SCRIPT" ] && [ -f "$MODULES_CONF" ] || return 1

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl is-enabled --quiet bbr-optimize-persist.service >/dev/null 2>&1 &&
            systemctl is-active --quiet bbr-optimize-persist.service >/dev/null 2>&1
    elif command -v rc-update >/dev/null 2>&1; then
        [ -x "$OPENRC_START" ] && openrc_local_is_enabled
    elif [ -d /etc/init.d ]; then
        [ -x "$SYSV_SERVICE" ] &&
            { compgen -G '/etc/rc*.d/S*bbr-optimize-persist' >/dev/null ||
              compgen -G '/etc/rc.d/rc*.d/S*bbr-optimize-persist' >/dev/null; }
    else
        return 1
    fi
}

tuning_runtime_is_ready() {
    local profile congestion_control buffer_mb
    local tcp_rmem tcp_wmem rmem_max_bytes wmem_max_bytes somaxconn syn_backlog netdev_backlog
    local initcwnd initrwnd mss_clamp ip_local_port_range
    local current_route current_initcwnd current_initrwnd value

    command -v sysctl >/dev/null 2>&1 || return 1
    [ -s "$SYSCTL_CONF" ] && [ -s "$PROFILE_STATE" ] || return 1
    if grep -qE '^[[:space:]]*net\.ipv4\.tcp_(no_metrics_save|notsent_lowat|retries2)[[:space:]]*=' "$SYSCTL_CONF" 2>/dev/null; then
        # 旧配置仍在管理已退役的全局 TCP 行为，需要重新 apply 才算完成升级。
        return 1
    fi

    profile=$(awk -F= '$1 == "profile" {print $2}' "$PROFILE_STATE")
    congestion_control=$(awk -F= '$1 == "congestion_control" {print $2}' "$PROFILE_STATE")
    buffer_mb=$(awk -F= '$1 == "buffer_mb" {print $2}' "$PROFILE_STATE")
    tcp_rmem=$(awk -F= '$1 == "tcp_rmem" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
    tcp_wmem=$(awk -F= '$1 == "tcp_wmem" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
    somaxconn=$(awk -F= '$1 == "somaxconn" {print $2}' "$PROFILE_STATE")
    syn_backlog=$(awk -F= '$1 == "tcp_max_syn_backlog" {print $2}' "$PROFILE_STATE")
    netdev_backlog=$(awk -F= '$1 == "netdev_max_backlog" {print $2}' "$PROFILE_STATE")
    initcwnd=$(awk -F= '$1 == "initcwnd" {print $2}' "$PROFILE_STATE")
    initrwnd=$(awk -F= '$1 == "initrwnd" {print $2}' "$PROFILE_STATE")
    mss_clamp=$(awk -F= '$1 == "mss_clamp" {print $2}' "$PROFILE_STATE")

    case "$profile" in
        optimize|landing) ip_local_port_range="10240 65535" ;;
        website) ip_local_port_range="32768 65535" ;;
        *) return 1 ;;
    esac
    case "$congestion_control" in bbr|bbr2|bbr3) ;; *) return 1 ;; esac
    buffer_mb=$(normalize_uint "$buffer_mb" 1 512) || return 1
    rmem_max_bytes=$(awk '{print $3}' <<< "$tcp_rmem")
    wmem_max_bytes=$(awk '{print $3}' <<< "$tcp_wmem")
    rmem_max_bytes=$(normalize_uint "$rmem_max_bytes" 1 536870912) || return 1
    wmem_max_bytes=$(normalize_uint "$wmem_max_bytes" 1 536870912) || return 1
    for value in "$somaxconn" "$syn_backlog" "$netdev_backlog"; do
        normalize_uint "$value" 1 1000000000 >/dev/null || return 1
    done
    initcwnd=$(normalize_uint "$initcwnd" 0 1000000) || return 1
    initrwnd=$(normalize_uint "$initrwnd" 0 1000000) || return 1
    case "$mss_clamp" in 0|1) ;; *) return 1 ;; esac
    [ -n "$tcp_rmem" ] && [ -n "$tcp_wmem" ] || return 1

    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "$congestion_control" ] || return 1
    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || return 1
    [ "$(sysctl -n net.core.rmem_max 2>/dev/null)" = "$rmem_max_bytes" ] || return 1
    [ "$(sysctl -n net.core.wmem_max 2>/dev/null)" = "$wmem_max_bytes" ] || return 1
    [ "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{$1=$1; print}')" = "$tcp_rmem" ] || return 1
    [ "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{$1=$1; print}')" = "$tcp_wmem" ] || return 1
    [ "$(sysctl -n net.core.somaxconn 2>/dev/null)" = "$somaxconn" ] || return 1
    [ "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null)" = "$syn_backlog" ] || return 1
    [ "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)" = "$netdev_backlog" ] || return 1
    [ "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{$1=$1; print}')" = "$ip_local_port_range" ] || return 1

    for value in \
        'net.ipv4.tcp_window_scaling=1' 'net.ipv4.tcp_moderate_rcvbuf=1' \
        'net.ipv4.tcp_timestamps=1' 'net.ipv4.tcp_sack=1' 'net.ipv4.tcp_dsack=1' \
        'net.ipv4.tcp_slow_start_after_idle=0' 'net.ipv4.tcp_mtu_probing=1' \
        'net.ipv4.tcp_fin_timeout=30' 'net.ipv4.tcp_fastopen=3' \
        'net.ipv4.udp_rmem_min=8192' 'net.ipv4.udp_wmem_min=8192' \
        'net.ipv4.tcp_syncookies=1' 'net.ipv4.tcp_abort_on_overflow=0'; do
        [ "$(sysctl -n "${value%%=*}" 2>/dev/null)" = "${value#*=}" ] || return 1
    done

    if [ "$initcwnd" -gt 0 ] || [ "$initrwnd" -gt 0 ]; then
        command -v ip >/dev/null 2>&1 || return 1
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        current_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
        current_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
        [ -n "$current_initcwnd" ] || current_initcwnd=0
        [ -n "$current_initrwnd" ] || current_initrwnd=0
        [ "$current_initcwnd" = "$initcwnd" ] && [ "$current_initrwnd" = "$initrwnd" ] || return 1
    fi

    if [ "$mss_clamp" = "1" ]; then
        command -v iptables >/dev/null 2>&1 || return 1
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu -m comment --comment "$MSS_RULE_COMMENT" >/dev/null 2>&1 ||
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu >/dev/null 2>&1 || return 1
    fi

    runtime_qdisc_is_ready && tuning_persistence_is_ready
}

check_bbr_status() {
    show_detailed_bbr_status
    echo ""
    if tuning_runtime_is_ready; then
        ui_success "BBR 网络调优已完整生效，核心网络配置、队列调度与开机持久化均验证通过"
        return 0
    fi

    ui_warn "BBR 网络调优尚未完整生效，核心配置、队列调度或开机持久化验证未通过"
    ui_info "请重新执行一键应用网络调优，完成后再次验证"
    return 1
}

restore_bbr_direct() {
    local snapshot_mode="none"
    local restore_failed=0
    local swap_restore_status=0 swap_restore_partial=0
    local script_path=""
    if ! validate_state_file_paths; then
        return 1
    fi
    if ! validate_snapshot_structure; then
        return 1
    fi
    [ -f "$SNAPSHOT_MODE" ] && snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || echo "legacy")
    script_path=$(current_script_path 2>/dev/null || true)

    ui_banner
    ui_card_start "恢复与清理"
    ui_card_line "还原网络、启动项和脚本调整过的虚拟内存"
    ui_card_line "成功后清理恢复保护并删除当前脚本"
    ui_card_line "检测到关键网络状态变化时会停止"
    ui_card_end
    echo ""
    ui_info "成功恢复后会一并清理脚本状态、临时工具和已知旧备份"
    ui_warn "部分恢复失败时会保留恢复保护，便于重试"
    # 进入该函数已代表用户明确选择 restore；非交互执行时应继续，而不是静默取消。
    if ! confirm_yn "确认恢复、清理残留并删除当前脚本？" "n" "y"; then
        ui_info "已取消恢复"
        return 1
    fi

    ui_step 1 6 "停止并移除重启持久化"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    fi
    if [ -x "$SYSV_SERVICE" ]; then
        "$SYSV_SERVICE" stop >/dev/null 2>&1 || true
    fi
    command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f bbr-optimize-persist remove >/dev/null 2>&1 || true
    command -v chkconfig >/dev/null 2>&1 && chkconfig --del bbr-optimize-persist >/dev/null 2>&1 || true

    remove_tuning_files || restore_failed=1

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            ui_warn "系统服务状态未能重新加载"
            restore_failed=1
        fi
    fi

    ui_step 2 6 "恢复配置文件与脚本专属规则"
    if ! apply_mss_clamp disable >/dev/null 2>&1; then
        ui_warn "本脚本标记的 TCPMSS 规则未能完全移除"
        restore_failed=1
    fi
    if command -v iptables >/dev/null 2>&1 && \
       iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
        --clamp-mss-to-pmtu >/dev/null 2>&1; then
        ui_warn "检测到无脚本标记的 TCPMSS 规则，为避免误删已保留"
    fi

    if [ -f /etc/security/limits.conf ] && grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        if ! cp /etc/security/limits.conf "/etc/security/limits.conf.bak.bbr-restore.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || \
           ! sed -i '/^# BBR - 文件描述符优化$/,+2d' /etc/security/limits.conf 2>/dev/null; then
            ui_warn "旧版文件描述符配置未能完整清理"
            restore_failed=1
        fi
    fi

    local sysctl_conf_path=""
    if [ -s "$SYSCTL_CONFLICT_PATH_STATE" ]; then
        sysctl_conf_path=$(cat "$SYSCTL_CONFLICT_PATH_STATE" 2>/dev/null || true)
        if ! [[ "$sysctl_conf_path" == /etc/* ]] || \
           [ ! -f "$sysctl_conf_path" ] || [ -L "$sysctl_conf_path" ] || \
           ! sed -i 's/^# bbr-direct-tune disabled: //' "$sysctl_conf_path" 2>/dev/null; then
            ui_warn "无法恢复 /etc/sysctl.conf 中被脚本注释的冲突项"
            restore_failed=1
        fi
    elif grep -q '^# bbr-direct-tune disabled: ' /etc/sysctl.conf 2>/dev/null; then
        # 兼容旧版：旧状态没有记录实际路径，只能解析当前 sysctl.conf。
        if ! sysctl_conf_path=$(resolve_sysctl_conf_edit_path) || \
           ! sed -i 's/^# bbr-direct-tune disabled: //' "$sysctl_conf_path" 2>/dev/null; then
            ui_warn "无法恢复旧版 /etc/sysctl.conf 冲突标记"
            restore_failed=1
        fi
    fi
    restore_disabled_sysctl_files || restore_failed=1

    if [ "$snapshot_mode" != "fresh" ] && [ -f /etc/sysctl.conf.bak.original ]; then
        echo ""
        ui_warn "旧版备份恢复会覆盖调优后对 /etc/sysctl.conf 的手动修改"
        ui_info "本次恢复成功后会清理该旧备份；如需长期保留请先自行复制到其他位置"
        if confirm_yn "是否使用旧版完整备份覆盖 /etc/sysctl.conf？" "n" "n"; then
            if ! cp /etc/sysctl.conf "/etc/sysctl.conf.bak.before-restore.$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
                ui_warn "无法保存当前 sysctl.conf，已取消旧版覆盖恢复"
                restore_failed=1
            elif cp /etc/sysctl.conf.bak.original /etc/sysctl.conf 2>/dev/null; then
                ui_success "已从旧版备份恢复 /etc/sysctl.conf"
            else
                ui_warn "旧版 sysctl.conf 备份恢复失败"
                restore_failed=1
            fi
        fi
    fi

    ui_step 3 6 "恢复脚本调整前的 Swap"
    restore_swap_state
    swap_restore_status=$?
    case "$swap_restore_status" in
        0) ;;
        2) swap_restore_partial=1 ;;
        *) restore_failed=1 ;;
    esac

    ui_step 4 6 "重新加载系统配置"
    if command -v sysctl >/dev/null 2>&1; then
        sysctl --system >/dev/null 2>&1 || true
        if [ -n "$SWAP_RESTORE_SWAPPINESS" ] && \
           ! sysctl -w "vm.swappiness=$SWAP_RESTORE_SWAPPINESS" >/dev/null 2>&1; then
            ui_warn "未能恢复 Swap 调整前的 vm.swappiness"
            restore_failed=1
        fi
    elif [ -n "$SWAP_RESTORE_SWAPPINESS" ]; then
        ui_warn "缺少 sysctl，无法恢复 Swap 调整前的 vm.swappiness"
        restore_failed=1
    fi

    if [ "$snapshot_mode" = "fresh" ]; then
        ui_step 5 6 "恢复调优前运行状态"
        restore_runtime_snapshot || restore_failed=1
        restore_qdisc_snapshot || restore_failed=1
        restore_route_snapshot || restore_failed=1
        restore_rps_snapshot || restore_failed=1
        restore_thp_snapshot || restore_failed=1
    else
        ui_step 5 6 "旧版兼容恢复"
        restore_qdisc_snapshot || restore_failed=1
        restore_route_snapshot || restore_failed=1
        ui_warn "旧版没有完整 sysctl 快照；其余配置已移除，重启后按系统现有默认加载"
    fi

    ui_step 6 6 "验证恢复结果"
    if [ "$restore_failed" -eq 0 ]; then
        rm -f -- "$STATE_DIR/shaper.state" "$STATE_DIR/policer.state" "$STATE_DIR/iperf3.managed" 2>/dev/null || restore_failed=1
        cleanup_known_backup_residuals || restore_failed=1
    fi
    if [ "$restore_failed" -eq 0 ]; then
        if cleanup_state_snapshot; then
            ui_success "恢复快照与脚本专属状态目录已清理"
        else
            restore_failed=1
            ui_warn "无法清理脚本专属状态目录：$STATE_DIR"
        fi
    fi

    if [ "$restore_failed" -ne 0 ]; then
        ui_warn "部分状态或残留未能自动处理，快照与当前脚本已保留，便于后续重试"
        return 1
    fi

    if [ "$swap_restore_partial" -eq 1 ]; then
        ui_warn "网络调优与脚本残留已恢复并清理；当前 $SWAP_FILE 因归属无法确认而原样保留"
        ui_info "Swap 文件及相关启动配置未被覆盖，脚本已放弃对其恢复管理"
    else
        ui_success "恢复完成；为避免中断现有连接，当前已加载的 tcp_bbr 模块不会强制卸载"
    fi
    ui_info "可用 sysctl、tc qdisc 和 swapon --show 复核恢复结果；必要时安排一次维护重启"
    if [ -n "$script_path" ]; then
        if rm -f -- "$script_path"; then
            ui_success "已删除当前脚本：$script_path"
        else
            ui_warn "系统配置已恢复，但当前脚本删除失败，请手动删除：$script_path"
            return 1
        fi
    else
        ui_info "当前通过管道或非普通文件执行，无脚本文件需要删除"
    fi
    return 0
}

show_help() {
    ui_banner
    ui_card_start "常用命令"
    ui_card_line "sudo bash $0" "${gl_kjlan}sudo bash $0${gl_bai}  打开交互菜单"
    ui_card_line "sudo bash $0 apply" "${gl_kjlan}sudo bash $0 apply${gl_bai}  应用或更新"
    ui_card_line "bash $0 status" "${gl_zi}bash $0 status${gl_bai}  验证调优是否生效"
    ui_card_line "bash $0 diagnose <目标>" "${gl_zi}bash $0 diagnose <目标>${gl_bai}  PMTU/MSS 与网络栈诊断"
    ui_card_line "sudo bash $0 restore" "${gl_huang}sudo bash $0 restore${gl_bai}  恢复并清理"
    ui_card_end

    ui_card_start "自动处理"
    ui_card_line "按用途、地区、带宽和机器资源自动计算"
    ui_card_line "仅标记冲突键，并设置开机生效"
    ui_card_line "status 显示参数、队列和累计计数"
    ui_card_line "diagnose 可按目标执行 tracepath、DF ping 与 IPv4/IPv6 MSS 推导"
    ui_card_end

    ui_card_start "安全恢复"
    ui_card_line "首次应用会保存恢复保护"
    ui_card_line "关键网络状态变化时停止，避免覆盖"
    ui_card_line "完整恢复后清理状态并删除当前脚本"
    ui_card_line "脚本创建的临时工具、状态和已知旧备份一并清理"
    ui_card_end

    ui_card_start "高级用法"
    ui_card_line "AUTO_MODE=1 可用于非交互执行"
    ui_card_line "TUNE_PROFILE / SERVER_REGION / BANDWIDTH_MBPS 可覆盖自动选择"
    ui_card_line "TARGET_RTT_MS / RELAY_RTT_MS 可覆盖目标 RTT"
    ui_card_line "INIT_CWND / INIT_RWND 可显式覆盖自动初始窗口"
    ui_card_end
}

show_main_menu() {
    local menu_choice="" diagnostic_target=""
    local current_cc current_qdisc tuning_label tuning_color snapshot_label snapshot_color

    while true; do
        ui_clear
        ui_banner
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        tuning_label="待配置"
        tuning_color="$gl_hui"
        case "${current_cc}:${current_qdisc}" in
            bbr:fq|bbr2:fq|bbr3:fq)
                tuning_label="已启用"
                tuning_color="$gl_lv"
                ;;
            bbr:*|bbr2:*|bbr3:*|*:fq)
                tuning_label="需检查"
                tuning_color="$gl_huang"
                ;;
        esac
        if [ -f "$SNAPSHOT_READY" ]; then
            snapshot_label="已保存"
            snapshot_color="$gl_lv"
        else
            snapshot_label="未创建"
            snapshot_color="$gl_hui"
        fi

        ui_card_start "系统状态"
        ui_card_line "网络调优    ${tuning_label}" \
            "网络调优    ${tuning_color}${UI_LED} ${tuning_label}${gl_bai}"
        ui_card_line "恢复保护    ${snapshot_label}" \
            "恢复保护    ${snapshot_color}${UI_LED} ${snapshot_label}${gl_bai}"
        ui_card_line "拥塞控制    ${current_cc} + ${current_qdisc}" \
            "拥塞控制    ${gl_kjlan}${current_cc}${gl_bai} ${gl_hui}+${gl_bai} ${gl_zi}${current_qdisc}${gl_bai}"
        ui_card_end

        ui_card_start "操作台"
        ui_card_line "01  一键应用网络调优" \
            "${gl_bold}${gl_kjlan}01${gl_bai} ${gl_hui}${UI_SECTION}${gl_bai} 一键应用网络调优  ${gl_hui}${gl_dim}测速 ${UI_DOT} 计算 ${UI_DOT} 应用 ${UI_DOT} 持久化${gl_bai}"
        ui_card_line "02  验证调优是否生效" \
            "${gl_bold}${gl_zi}02${gl_bai} ${gl_hui}${UI_SECTION}${gl_bai} 验证调优是否生效  ${gl_hui}${gl_dim}配置 ${UI_DOT} 队列 ${UI_DOT} 持久化自检${gl_bai}"
        ui_card_line "03  恢复并清理" \
            "${gl_bold}${gl_huang}03${gl_bai} ${gl_hui}${UI_SECTION}${gl_bai} 恢复并清理        ${gl_hui}${gl_dim}还原调优前状态${gl_bai}"
        ui_card_line "04  网络与 PMTU 诊断" \
            "${gl_bold}${gl_zi}04${gl_bai} ${gl_hui}${UI_SECTION}${gl_bai} 网络与 PMTU 诊断  ${gl_hui}${gl_dim}只读检测${gl_bai}"
        ui_card_line "05  帮助与说明" \
            "${gl_bold}${gl_hui}05${gl_bai} ${gl_hui}${UI_SECTION}${gl_bai} 帮助与说明"
        ui_card_line "00  退出" \
            "${gl_bold}${gl_hui}00${gl_bai} ${gl_hui}${UI_SECTION}${gl_bai} 退出"
        ui_card_end
        echo ""
        if ! read -r -p "$(printf '%b%s%b 选择操作 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" menu_choice; then
            ui_info "输入流已关闭，退出菜单"
            return 0
        fi
        menu_choice=${menu_choice//$'\r'/}
        menu_choice=${menu_choice:-1}

        case "$menu_choice" in
            1|01)
                check_root
                run_locked_operation bbr_configure_direct
                cleanup_test_tools_after_tuning
                break_end
                ;;
            2|02)
                check_bbr_status
                break_end
                ;;
            3|03)
                check_root
                if run_locked_operation restore_bbr_direct; then
                    return 0
                fi
                break_end
                ;;
            4|04)
                diagnostic_target=""
                read -e -p "请输入 PMTU 测试目标（IP/域名，留空仅检查本机）: " diagnostic_target || diagnostic_target=""
                run_network_diagnostics "$diagnostic_target"
                break_end
                ;;
            5|05)
                ui_section "帮助"
                show_help
                break_end
                ;;
            0|00|q|Q)
                ui_info "已退出"
                return 0
                ;;
            *)
                ui_warn "无效选项，请输入 0-5"
                sleep 1
                ;;
        esac
    done
}

main() {
    local command="${1:-}"
    local apply_rc=0

    if [ -z "$command" ]; then
        if [ "$AUTO_MODE" = "1" ]; then
            command="apply"
        elif [ ! -t 0 ]; then
            command="help"
        else
            command="menu"
        fi
    fi

    case "$command" in
        menu)
            show_main_menu
            ;;
        apply)
            check_root
            run_locked_operation bbr_configure_direct
            apply_rc=$?
            cleanup_test_tools_after_tuning
            return "$apply_rc"
            ;;
        restore)
            check_root
            run_locked_operation restore_bbr_direct
            ;;
        status)
            check_bbr_status
            ;;
        diagnose|diagnostic)
            run_network_diagnostics "${2:-}"
            ;;
        -h|--help|help)
            show_help
            ;;
        -v|--version|version)
            echo "bbr-direct-tune.sh v${SCRIPT_VERSION}"
            ;;
        *)
            echo -e "${gl_hong}未知命令: ${command}${gl_bai}" >&2
            show_help
            exit 1
            ;;
    esac
}

main "$@"
