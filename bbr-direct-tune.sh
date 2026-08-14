#!/bin/bash
set -o pipefail

SCRIPT_VERSION="6.10.4"
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
SHAPER_STATE="${STATE_DIR}/shaper.state"
POLICER_STATE="${STATE_DIR}/policer.state"
IPERF3_MANAGED_STATE="${STATE_DIR}/iperf3.managed"
POLICER_EVIDENCE_MAX_AGE=86400
DEFAULT_TARGET_RTT_MS=150
RTT_SAMPLE_MIN=""
RTT_SAMPLE_MEDIAN=""
RTT_SAMPLE_AVG=""
RTT_SAMPLE_P95=""
RTT_SAMPLE_MAX=""
RTT_SAMPLE_COUNT=0
RTT_TARGETS_USED=""
ORIGIN_RTT_SOURCE=""
ORIGIN_RTT_MIN=""
ORIGIN_RTT_MEDIAN=""
ORIGIN_RTT_AVG=""
ORIGIN_RTT_P95=""
ORIGIN_RTT_MAX=""
ORIGIN_RTT_COUNT=0
ORIGIN_RTT_TARGETS=""
INIT_WINDOW_OVERRIDE=""
SHAPER_MEMORY_MB=1024
SHAPER_RTT_MS="$DEFAULT_TARGET_RTT_MS"
SHAPER_PRE_SCAN_GAP=15
SHAPER_TEST_GAP=3
SHAPER_IPERF_RETRY_GAP=8
INIT_WINDOW_MANAGED=0
INIT_WINDOW_CLEARED=0
INIT_WINDOW_RESTORE_CWND=0
INIT_WINDOW_RESTORE_RWND=0
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
PUBLIC_IPERF_HOST=""
PUBLIC_IPERF_PORT=""
PUBLIC_IPERF_RTT_MS=""
PUBLIC_IPERF_LABEL=""
IPERF_FAMILY="-4"
TRANSIENT_QDISC_IFACE=""
TRANSIENT_QDISC_BASELINE_KIND=""
TRANSIENT_QDISC_OWNED=0
SHAPER_APPLY_ERROR_STAGE=""
SHAPER_APPLY_ERROR_DETAIL=""
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

# 仅用于 iperf3 端口限速器测试，按 RTT 自动选择近端且端口可用的节点。
# 格式：主机|地区|位置|提供商。节点失效只会跳过实测，不影响基础调优。
PUBLIC_IPERF_PEERS=(
    "speedtest.hkg12.hk.leaseweb.net|asia|香港|Leaseweb"
    "speedtest.sin1.sg.leaseweb.net|asia|新加坡|Leaseweb"
    "sgp.proof.ovh.net|asia|新加坡|OVH"
    "speedtest.tyo11.jp.leaseweb.net|asia|东京|Leaseweb"
    "speedtest.fra1.de.leaseweb.net|europe|法兰克福|Leaseweb"
    "speedtest.ams2.nl.leaseweb.net|europe|阿姆斯特丹|Leaseweb"
    "ams.speedtest.clouvider.net|europe|阿姆斯特丹|Clouvider"
    "speedtest.lon12.uk.leaseweb.net|europe|伦敦|Leaseweb"
    "lon.speedtest.clouvider.net|europe|伦敦|Clouvider"
    "speedtest.lax12.us.leaseweb.net|america|洛杉矶|Leaseweb"
    "speedtest.sfo12.us.leaseweb.net|america|旧金山|Leaseweb"
    "speedtest.sea11.us.leaseweb.net|america|西雅图|Leaseweb"
    "speedtest.dal13.us.leaseweb.net|america|达拉斯|Leaseweb"
    "speedtest.chi11.us.leaseweb.net|america|芝加哥|Leaseweb"
    "speedtest.nyc1.us.leaseweb.net|america|纽约|Leaseweb"
    "speedtest.mia11.us.leaseweb.net|america|迈阿密|Leaseweb"
    "speedtest.mtl2.ca.leaseweb.net|america|蒙特利尔|Leaseweb"
    "speedtest.syd12.au.leaseweb.net|other|悉尼|Leaseweb"
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
        "$SHAPER_STATE" "$POLICER_STATE" "$IPERF3_MANAGED_STATE"
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

    [ "$OPERATION_LOCK_HELD" -eq 1 ] || return 0
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
    for temp_dir in "${MANAGED_TEMP_DIRS[@]}"; do
        case "$temp_dir" in
            /tmp/bbr-iperf-peers.[A-Za-z0-9]*|/tmp/bbr-iperf-run.[A-Za-z0-9]*)
                [ -d "$temp_dir" ] && [ ! -L "$temp_dir" ] && rm -rf -- "$temp_dir" 2>/dev/null || true
                ;;
        esac
    done
    cleanup_managed_iperf3 >/dev/null 2>&1 || true
}

cleanup_test_tools_after_tuning() {
    local speedtest_installed=0 iperf_installed=0 cleanup_failed=0
    speedtest_marker_is_owned && speedtest_installed=1
    iperf3_marker_is_owned && iperf_installed=1
    cleanup_runtime_artifacts
    if [ "$iperf_installed" -eq 1 ] && iperf3_marker_is_owned; then
        cleanup_failed=1
        ui_warn "脚本临时安装的 iperf3 未能自动卸载，恢复时将再次清理"
    fi
    if [ "$speedtest_installed" -eq 1 ] || [ "$iperf_installed" -eq 1 ]; then
        ui_info "测速完成，已清理脚本本次准备的测速工具与临时文件"
    fi
    return "$cleanup_failed"
}

cleanup_on_exit() {
    if restore_transient_qdisc >/dev/null 2>&1; then
        if [ -s "$SHAPER_STATE" ] && [ "$(awk -F= '$1 == "phase" {print $2; exit}' "$SHAPER_STATE" 2>/dev/null)" = "testing" ]; then
            rm -f -- "$SHAPER_STATE" 2>/dev/null || true
        fi
    fi
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
                # 未知 fq_codel 扩展参数不能安全重放；保留类型快照，但不允许后续整形覆盖。
                ui_warn "网卡 $dev 的 fq_codel 参数无法完整保存，出口整形将保持禁用"
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

iperf3_marker_is_owned() {
    [ -f "$IPERF3_MANAGED_STATE" ] && [ ! -L "$IPERF3_MANAGED_STATE" ] && \
        [ "$(stat -c '%u' -- "$IPERF3_MANAGED_STATE" 2>/dev/null)" = "0" ] && \
        [ "$(stat -c '%A' -- "$IPERF3_MANAGED_STATE" 2>/dev/null | cut -c6,9)" = "--" ]
}

cleanup_managed_iperf3() {
    local manager

    [ "$EUID" -eq 0 ] || return 1
    iperf3_marker_is_owned || return 0
    manager=$(awk -F= '$1 == "manager" {print $2; exit}' "$IPERF3_MANAGED_STATE")
    case "$manager" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get remove -y iperf3 >/dev/null 2>&1 || return 1
            ;;
        dnf)
            dnf remove -y iperf3 >/dev/null 2>&1 || return 1
            ;;
        yum)
            yum remove -y iperf3 >/dev/null 2>&1 || return 1
            ;;
        apk)
            apk del iperf3 >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    command -v iperf3 >/dev/null 2>&1 && return 1
    rm -f -- "$IPERF3_MANAGED_STATE"
}

ensure_iperf3() {
    local manager="" state_tmp="${IPERF3_MANAGED_STATE}.tmp.$$"

    if command -v iperf3 >/dev/null 2>&1; then
        return 0
    fi
    if iperf3_marker_is_owned; then
        rm -f -- "$IPERF3_MANAGED_STATE"
    fi

    ui_info "正在临时安装端口限速器测试所需的 iperf3，测试结束后会自动卸载"
    if command -v apt-get >/dev/null 2>&1; then
        manager="apt"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 >/dev/null 2>&1 || return 1
    elif command -v dnf >/dev/null 2>&1; then
        manager="dnf"
        dnf install -y iperf3 >/dev/null 2>&1 || return 1
    elif command -v yum >/dev/null 2>&1; then
        manager="yum"
        yum install -y iperf3 >/dev/null 2>&1 || return 1
    elif command -v apk >/dev/null 2>&1; then
        manager="apk"
        apk add iperf3 >/dev/null 2>&1 || return 1
    else
        ui_warn "无法识别包管理器，请手动安装 iperf3 后重试"
        return 1
    fi
    if ! command -v iperf3 >/dev/null 2>&1; then
        ui_warn "iperf3 安装未完成"
        return 1
    fi
    if ! mkdir -p "$STATE_DIR" || ! chmod 700 "$STATE_DIR" || \
       ! prepare_managed_temp_file "$state_tmp" || \
       ! printf 'manager=%s\npackage=iperf3\n' "$manager" > "$state_tmp" || \
       ! finalize_managed_temp_file "$state_tmp" "$IPERF3_MANAGED_STATE" 600; then
        case "$manager" in
            apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y iperf3 >/dev/null 2>&1 || true ;;
            dnf) dnf remove -y iperf3 >/dev/null 2>&1 || true ;;
            yum) yum remove -y iperf3 >/dev/null 2>&1 || true ;;
            apk) apk del iperf3 >/dev/null 2>&1 || true ;;
        esac
        ui_warn "无法记录 iperf3 所有权，已取消测试并尝试清理"
        return 1
    fi
    ui_success "iperf3 已临时准备完成"
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

detect_iperf_family() {
    local route_output="" address_output="" route_get_output=""

    IPERF_FAMILY="-4"
    command -v ip >/dev/null 2>&1 || return 0

    route_output=$(ip -4 route show default 2>/dev/null)
    address_output=$(ip -4 addr show scope global 2>/dev/null)
    route_get_output=$(ip -4 route get 1.1.1.1 2>/dev/null)
    if { [ -n "$route_output" ] && [[ "$address_output" == *"inet "* ]]; } || \
       [[ "$route_get_output" == *" src "* ]]; then
        return 0
    fi

    route_output=$(ip -6 route show default 2>/dev/null)
    address_output=$(ip -6 addr show scope global 2>/dev/null)
    route_get_output=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null)
    if { [ -n "$route_output" ] && [[ "$address_output" == *"inet6 "* ]]; } || \
       [[ "$route_get_output" == *" src "* ]]; then
        IPERF_FAMILY="-6"
    fi
}

resolve_iperf_host_address() {
    local host="$1" address=""

    if [ "$IPERF_FAMILY" = "-4" ] && [[ "$host" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    if [ "$IPERF_FAMILY" = "-6" ] && [[ "$host" == *:* ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    command -v getent >/dev/null 2>&1 || return 1
    if [ "$IPERF_FAMILY" = "-6" ]; then
        address=$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR == 1 {print $1}')
        [ -n "$address" ] || address=$(getent ahosts "$host" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
    else
        address=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}')
        [ -n "$address" ] || address=$(getent ahosts "$host" 2>/dev/null | awk '
            {
                count=split($1, octet, ".")
                if (count == 4 && octet[1] ~ /^[0-9]+$/ && octet[2] ~ /^[0-9]+$/ &&
                    octet[3] ~ /^[0-9]+$/ && octet[4] ~ /^[0-9]+$/) {
                    print $1
                    exit
                }
            }
        ')
    fi
    [ -n "$address" ] || return 1
    printf '%s\n' "$address"
}

probe_public_iperf_port() {
    local host="$1" address port index selected_port=""
    local ports=(5201 5202 5203 5200)
    local probe_pids=()

    command -v timeout >/dev/null 2>&1 || return 1
    address=$(resolve_iperf_host_address "$host") || return 1
    for port in "${ports[@]}"; do
        timeout 4 bash -c '</dev/tcp/$1/$2' _ "$address" "$port" >/dev/null 2>&1 &
        probe_pids+=("$!")
    done
    for index in "${!probe_pids[@]}"; do
        if wait "${probe_pids[$index]}"; then
            [ -n "$selected_port" ] || selected_port="${ports[$index]}"
        fi
    done
    [ -n "$selected_port" ] || return 1
    PUBLIC_IPERF_PORT="$selected_port"
    return 0
}

select_public_iperf_peer() {
    local entry host location provider rtt
    local tmp_dir index=0 result_file selected_line=""

    PUBLIC_IPERF_HOST=""
    PUBLIC_IPERF_PORT=""
    PUBLIC_IPERF_RTT_MS=""
    PUBLIC_IPERF_LABEL=""
    command -v ping >/dev/null 2>&1 || {
        ui_warn "缺少 ping，无法自动选择公共 iperf3 节点"
        return 1
    }
    detect_iperf_family
    tmp_dir=$(mktemp -d /tmp/bbr-iperf-peers.XXXXXX) || return 1
    MANAGED_TEMP_DIRS+=("$tmp_dir")

    ui_info "正在自动选择 RTT 最低且端口可用的公共 iperf3 节点"
    for entry in "${PUBLIC_IPERF_PEERS[@]}"; do
        IFS='|' read -r host _ location provider <<< "$entry"
        index=$((index + 1))
        result_file="$tmp_dir/$index"
        (
            rtt=$(ping "$IPERF_FAMILY" -n -c 2 -W 2 "$host" 2>/dev/null | \
                awk -F'=' '/rtt|round-trip/ {
                    split($2, values, "/")
                    value=values[2]+0
                    if (value < 1) value=1
                    printf "%.0f", value
                    exit
                }')
            if normalize_uint "$rtt" 1 2000 >/dev/null 2>&1; then
                printf '%s|%s|%s|%s\n' "$rtt" "$host" "$location" "$provider" > "$result_file"
            fi
        ) &
    done
    wait

    while IFS='|' read -r rtt host location provider; do
        [ -n "$host" ] || continue
        PUBLIC_IPERF_PORT=""
        if probe_public_iperf_port "$host"; then
            selected_line="$rtt|$host|$location|$provider|$PUBLIC_IPERF_PORT"
            break
        fi
    done < <(cat "$tmp_dir"/* 2>/dev/null | sort -t '|' -k1,1n)

    rm -rf -- "$tmp_dir"
    if [ -z "$selected_line" ]; then
        ui_warn "当前没有 RTT 可测且 iperf3 端口可用的公共节点"
        return 1
    fi

    IFS='|' read -r PUBLIC_IPERF_RTT_MS PUBLIC_IPERF_HOST location provider PUBLIC_IPERF_PORT <<< "$selected_line"
    PUBLIC_IPERF_LABEL="${location} / ${provider}"
    ui_success "已选择 ${PUBLIC_IPERF_LABEL}：${PUBLIC_IPERF_RTT_MS} ms / 端口 ${PUBLIC_IPERF_PORT}"
    ui_info "该 RTT 只用于选择 iperf3 测试节点，不参与 TCP 缓冲区计算"
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

ORIGIN_RTT_RESULT=""
prepare_origin_rtt() {
    local requested="${ORIGIN_RTT_MS:-}" default_rtt="${1:-$DEFAULT_TARGET_RTT_MS}" choice="" value="" raw_targets="" rc
    local relay_min="$RTT_SAMPLE_MIN" relay_median="$RTT_SAMPLE_MEDIAN" relay_avg="$RTT_SAMPLE_AVG"
    local relay_p95="$RTT_SAMPLE_P95" relay_max="$RTT_SAMPLE_MAX" relay_count="$RTT_SAMPLE_COUNT"
    local relay_targets="$RTT_TARGETS_USED"

    ORIGIN_RTT_RESULT=""
    ORIGIN_RTT_SOURCE="relay-fallback"
    ORIGIN_RTT_MIN=""; ORIGIN_RTT_MEDIAN=""; ORIGIN_RTT_AVG=""
    ORIGIN_RTT_P95=""; ORIGIN_RTT_MAX=""; ORIGIN_RTT_COUNT=0; ORIGIN_RTT_TARGETS=""

    if value=$(normalize_uint "$requested" 1 3000); then
        ORIGIN_RTT_RESULT="$value"
        ORIGIN_RTT_SOURCE="origin-override"
        ORIGIN_RTT_MIN="$value"; ORIGIN_RTT_MEDIAN="$value"; ORIGIN_RTT_AVG="$value"
        ORIGIN_RTT_P95="$value"; ORIGIN_RTT_MAX="$value"; ORIGIN_RTT_COUNT=1
        return 0
    fi
    [ -z "$requested" ] || ui_warn "ORIGIN_RTT_MS 无效，已进入回源 RTT 选择" >&2
    if [ -n "${ORIGIN_RTT_TEST_TARGETS:-}" ]; then
        if measure_target_rtt_list "$ORIGIN_RTT_TEST_TARGETS"; then
            ORIGIN_RTT_RESULT="$TARGET_RTT_MEASURED_MS"; ORIGIN_RTT_SOURCE="origin-target-max"
            ORIGIN_RTT_MIN="$RTT_SAMPLE_MIN"; ORIGIN_RTT_MEDIAN="$RTT_SAMPLE_MEDIAN"; ORIGIN_RTT_AVG="$RTT_SAMPLE_AVG"
            ORIGIN_RTT_P95="$RTT_SAMPLE_P95"; ORIGIN_RTT_MAX="$RTT_SAMPLE_MAX"; ORIGIN_RTT_COUNT="$RTT_SAMPLE_COUNT"
            ORIGIN_RTT_TARGETS="$RTT_TARGETS_USED"
        else
            ORIGIN_RTT_RESULT="$default_rtt"
            ORIGIN_RTT_MIN="$default_rtt"; ORIGIN_RTT_MEDIAN="$default_rtt"; ORIGIN_RTT_AVG="$default_rtt"
            ORIGIN_RTT_P95="$default_rtt"; ORIGIN_RTT_MAX="$default_rtt"; ORIGIN_RTT_COUNT=1
            ui_warn "ORIGIN_RTT_TEST_TARGETS 样本不足，已回退 ${default_rtt} ms" >&2
        fi
        RTT_SAMPLE_MIN="$relay_min"; RTT_SAMPLE_MEDIAN="$relay_median"; RTT_SAMPLE_AVG="$relay_avg"
        RTT_SAMPLE_P95="$relay_p95"; RTT_SAMPLE_MAX="$relay_max"; RTT_SAMPLE_COUNT="$relay_count"
        RTT_TARGETS_USED="$relay_targets"
        return 0
    fi
    if [ "$AUTO_MODE" = "1" ]; then
        ORIGIN_RTT_RESULT="$default_rtt"
        ORIGIN_RTT_MIN="$default_rtt"; ORIGIN_RTT_MEDIAN="$default_rtt"; ORIGIN_RTT_AVG="$default_rtt"
        ORIGIN_RTT_P95="$default_rtt"; ORIGIN_RTT_MAX="$default_rtt"; ORIGIN_RTT_COUNT=1
        return 0
    fi

    ui_card_start "落地机回源 RTT（用于接收缓冲区）" >&2
    ui_card_line "01  使用预设    ${default_rtt} ms" >&2
    ui_card_line "02  直接输入    回源 RTT 毫秒值" >&2
    ui_card_line "03  测试源站    持续数秒并取最大有效 RTT 推荐" >&2
    ui_card_end >&2
    if ! read -e -p "$(printf '%b%s%b 选择 [1]: ' "$gl_bold$gl_zi" "$UI_PROMPT" "$gl_bai")" choice; then
        choice=1
    fi
    case "${choice:-1}" in
        2|02)
            if ! read -e -p "请输入回源 RTT [1-3000] ms: " value; then value=""; fi
            if value=$(normalize_uint "$value" 1 3000); then
                ORIGIN_RTT_RESULT="$value"; ORIGIN_RTT_SOURCE="origin-manual"
                ORIGIN_RTT_MIN="$value"; ORIGIN_RTT_MEDIAN="$value"; ORIGIN_RTT_AVG="$value"
                ORIGIN_RTT_P95="$value"; ORIGIN_RTT_MAX="$value"; ORIGIN_RTT_COUNT=1
            else
                ORIGIN_RTT_RESULT="$default_rtt"
                ui_warn "回源 RTT 输入无效，已回退 ${default_rtt} ms" >&2
            fi
            ;;
        3|03)
            ui_info "请输入实际源站 IP、域名或 域名:端口；最多三个，英文逗号分隔" >&2
            if ! read -e -p "源站地址: " raw_targets; then raw_targets=""; fi
            if [ -n "$(trim_whitespace "$raw_targets")" ]; then
                measure_target_rtt_list "$raw_targets"; rc=$?
            else
                rc=1
            fi
            if [ "$rc" -eq 0 ]; then
                ORIGIN_RTT_RESULT="$TARGET_RTT_MEASURED_MS"; ORIGIN_RTT_SOURCE="origin-target-max"
                ORIGIN_RTT_MIN="$RTT_SAMPLE_MIN"; ORIGIN_RTT_MEDIAN="$RTT_SAMPLE_MEDIAN"; ORIGIN_RTT_AVG="$RTT_SAMPLE_AVG"
                ORIGIN_RTT_P95="$RTT_SAMPLE_P95"; ORIGIN_RTT_MAX="$RTT_SAMPLE_MAX"; ORIGIN_RTT_COUNT="$RTT_SAMPLE_COUNT"
                ORIGIN_RTT_TARGETS="$RTT_TARGETS_USED"
            else
                ORIGIN_RTT_RESULT="$default_rtt"
                ui_warn "源站 RTT 样本不足，已回退 ${default_rtt} ms" >&2
            fi
            ;;
        *) ORIGIN_RTT_RESULT="$default_rtt" ;;
    esac
    if [ -z "$ORIGIN_RTT_MIN" ]; then
        ORIGIN_RTT_MIN="$ORIGIN_RTT_RESULT"; ORIGIN_RTT_MEDIAN="$ORIGIN_RTT_RESULT"; ORIGIN_RTT_AVG="$ORIGIN_RTT_RESULT"
        ORIGIN_RTT_P95="$ORIGIN_RTT_RESULT"; ORIGIN_RTT_MAX="$ORIGIN_RTT_RESULT"; ORIGIN_RTT_COUNT=1
    fi

    # 回源测量复用了通用采样器，恢复此前到中转/用户方向的统计。
    RTT_SAMPLE_MIN="$relay_min"; RTT_SAMPLE_MEDIAN="$relay_median"; RTT_SAMPLE_AVG="$relay_avg"
    RTT_SAMPLE_P95="$relay_p95"; RTT_SAMPLE_MAX="$relay_max"; RTT_SAMPLE_COUNT="$relay_count"
    RTT_TARGETS_USED="$relay_targets"
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
        # 商加余数避免 quota + period - 1 在异常 cgroup 值下溢出。
        quota_count=$((quota / period))
        [ $((quota % period)) -gt 0 ] && quota_count=$((quota_count + 1))
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

    # 不继承旧调优脚本可能写入的 MiB 级中间值；高带宽且内存充足时提高新连接起步窗口。
    # 262144/262144 对齐 NodeSeek post-840965 实测零重传配置（4096 262144 16M）。
    if [ "$profile" != "website" ] && [ "$bandwidth" -ge 500 ] && [ "$memory_mb" -ge 2048 ]; then
        rmem_default=262144
        wmem_default=262144
    elif [ "$memory_mb" -le 256 ]; then
        rmem_default=87380
        wmem_default=16384
    fi

    [ "$rmem_default" -gt "$rmem_max_bytes" ] && rmem_default=$rmem_max_bytes
    [ "$wmem_default" -gt "$wmem_max_bytes" ] && wmem_default=$wmem_max_bytes

    printf '%s %s %s %s\n' "$rmem_min" "$rmem_default" "$wmem_min" "$wmem_default"
}

initial_window_override_requested() {
    normalize_uint "${INIT_CWND:-}" 10 32 >/dev/null 2>&1 || \
        normalize_uint "${INIT_RWND:-}" 10 32 >/dev/null 2>&1 || \
        case "${ENABLE_INIT_WINDOW_32:-}" in 1|yes|YES|true|TRUE) return 0 ;; *) return 1 ;; esac
}

initial_window_marker_is_valid() {
    local marker_cwnd marker_rwnd

    [ -s "$INIT_WINDOW_MARKER" ] && [ ! -L "$INIT_WINDOW_MARKER" ] || return 1
    marker_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$INIT_WINDOW_MARKER")
    marker_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$INIT_WINDOW_MARKER")
    normalize_uint "$marker_cwnd" 0 1000000 >/dev/null 2>&1 && \
        normalize_uint "$marker_rwnd" 0 1000000 >/dev/null 2>&1
}

initial_window_is_owned() {
    local profile_cwnd profile_rwnd baseline_cwnd baseline_rwnd

    initial_window_marker_is_valid && return 0
    if [ -f "$PERSIST_SCRIPT" ] && [ ! -L "$PERSIST_SCRIPT" ] && \
       grep -q '自动生成，勿手动编辑' "$PERSIST_SCRIPT" 2>/dev/null && \
       grep -Eq 'initcwnd[[:space:]]+32[[:space:]]+initrwnd[[:space:]]+32' "$PERSIST_SCRIPT" 2>/dev/null; then
        return 0
    fi
    if [ -s "$PROFILE_STATE" ] && [ ! -L "$PROFILE_STATE" ] && \
       [ -s "$ROUTE_STATE" ] && [ ! -L "$ROUTE_STATE" ]; then
        profile_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$PROFILE_STATE")
        profile_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$PROFILE_STATE")
        baseline_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$ROUTE_STATE")
        baseline_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$ROUTE_STATE")
        if [ "$profile_cwnd" = "32" ] && [ "$profile_rwnd" = "32" ] && \
           { [ "$baseline_cwnd" != "32" ] || [ "$baseline_rwnd" != "32" ]; }; then
            return 0
        fi
    fi
    return 1
}

rewrite_polluted_route_snapshot() {
    local saved_route saved_identity state_tmp="${ROUTE_STATE}.tmp.$$"

    [ -s "$ROUTE_STATE" ] && [ ! -L "$ROUTE_STATE" ] || return 1
    saved_route=$(awk -F= '$1 == "route" {sub(/^[^=]*=/, ""); print; exit}' "$ROUTE_STATE")
    saved_identity=$(awk -F= '$1 == "route_identity" {sub(/^[^=]*=/, ""); print; exit}' "$ROUTE_STATE")
    [ -n "$saved_route" ] || return 1
    prepare_managed_temp_file "$state_tmp" || return 1
    printf 'initcwnd=\ninitrwnd=\nroute_identity=%s\nroute=%s\n' \
        "$saved_identity" "$saved_route" > "$state_tmp" || return 1
    finalize_managed_temp_file "$state_tmp" "$ROUTE_STATE" 600
}

rewrite_profile_initial_window() {
    local expected_cwnd="$1" expected_rwnd="$2" target_cwnd="$3" target_rwnd="$4"
    local state_tmp="${PROFILE_STATE}.tmp.$$"

    [ -e "$PROFILE_STATE" ] || return 0
    [ -s "$PROFILE_STATE" ] && [ ! -L "$PROFILE_STATE" ] || return 1
    prepare_managed_temp_file "$state_tmp" || return 1
    if ! awk -F= -v expected_cwnd="$expected_cwnd" -v expected_rwnd="$expected_rwnd" \
        -v target_cwnd="$target_cwnd" -v target_rwnd="$target_rwnd" '
        BEGIN {cwnd_count=0; rwnd_count=0}
        $1 == "initcwnd" {
            cwnd_count++
            if (cwnd_count != 1 || ($2 != expected_cwnd && $2 != target_cwnd)) exit 2
            print "initcwnd=" target_cwnd
            next
        }
        $1 == "initrwnd" {
            rwnd_count++
            if (rwnd_count != 1 || ($2 != expected_rwnd && $2 != target_rwnd)) exit 2
            print "initrwnd=" target_rwnd
            next
        }
        {print}
        END {if (cwnd_count != 1 || rwnd_count != 1) exit 3}
    ' "$PROFILE_STATE" > "$state_tmp"; then
        rm -f -- "$state_tmp"
        return 1
    fi
    finalize_managed_temp_file "$state_tmp" "$PROFILE_STATE" 600
}

# 只清理能够证明由本项目旧版写入的窗口字段。重建路由时保留 metric、proto、
# src、onlink、mtu 等其余 token；无法证明所有权时不碰用户手工设置。
clear_owned_initial_window() {
    local current_route token skip=0 current_cwnd current_rwnd expected_cwnd="" expected_rwnd=""
    local baseline_cwnd baseline_rwnd legacy_owned=0 snapshot_was_polluted=0
    local route_args=() clean_args=() target_metrics=()

    INIT_WINDOW_CLEARED=0
    INIT_WINDOW_RESTORE_CWND=0
    INIT_WINDOW_RESTORE_RWND=0
    if [ -e "$INIT_WINDOW_MARKER" ] || [ -L "$INIT_WINDOW_MARKER" ]; then
        initial_window_marker_is_valid || return 1
    fi
    initial_window_is_owned || return 0
    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    [ -n "$current_route" ] || return 1
    current_cwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    current_rwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    [ -n "$current_cwnd" ] || current_cwnd=0
    [ -n "$current_rwnd" ] || current_rwnd=0

    if [ -s "$INIT_WINDOW_MARKER" ]; then
        expected_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$INIT_WINDOW_MARKER")
        expected_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$INIT_WINDOW_MARKER")
    fi
    if [ -z "$expected_cwnd" ] && [ -s "$PROFILE_STATE" ]; then
        expected_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$PROFILE_STATE")
        expected_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$PROFILE_STATE")
    fi
    if [ -f "$PERSIST_SCRIPT" ] && [ ! -L "$PERSIST_SCRIPT" ] && \
       grep -q '自动生成，勿手动编辑' "$PERSIST_SCRIPT" 2>/dev/null && \
       grep -Eq 'initcwnd[[:space:]]+32[[:space:]]+initrwnd[[:space:]]+32' "$PERSIST_SCRIPT" 2>/dev/null; then
        legacy_owned=1
        [ -n "$expected_cwnd" ] || expected_cwnd=32
        [ -n "$expected_rwnd" ] || expected_rwnd=32
    fi
    normalize_uint "${expected_cwnd:-}" 0 1000000 >/dev/null 2>&1 || return 0
    normalize_uint "${expected_rwnd:-}" 0 1000000 >/dev/null 2>&1 || return 0
    # 管理员在脚本运行后改过路由窗口时，不再套用旧快照。
    [ "$current_cwnd" = "$expected_cwnd" ] && [ "$current_rwnd" = "$expected_rwnd" ] || return 0
    if [ ! -e "$INIT_WINDOW_MARKER" ] && [ ! -L "$INIT_WINDOW_MARKER" ]; then
        printf 'initcwnd=%s\ninitrwnd=%s\n' "$expected_cwnd" "$expected_rwnd" > "$INIT_WINDOW_MARKER" || return 1
        chmod 600 "$INIT_WINDOW_MARKER" 2>/dev/null || return 1
    fi

    baseline_cwnd=$(awk -F= '$1 == "initcwnd" {print $2; exit}' "$ROUTE_STATE" 2>/dev/null)
    baseline_rwnd=$(awk -F= '$1 == "initrwnd" {print $2; exit}' "$ROUTE_STATE" 2>/dev/null)
    baseline_cwnd=${baseline_cwnd:-0}
    baseline_rwnd=${baseline_rwnd:-0}
    normalize_uint "$baseline_cwnd" 0 1000000 >/dev/null 2>&1 || baseline_cwnd=0
    normalize_uint "$baseline_rwnd" 0 1000000 >/dev/null 2>&1 || baseline_rwnd=0
    # 旧版持久化脚本与快照都是 32 时，快照已被污染，不能把 32 当原值恢复。
    if [ "$legacy_owned" -eq 1 ] && [ "$baseline_cwnd" = 32 ] && [ "$baseline_rwnd" = 32 ]; then
        baseline_cwnd=0
        baseline_rwnd=0
        snapshot_was_polluted=1
    fi
    INIT_WINDOW_RESTORE_CWND="$baseline_cwnd"
    INIT_WINDOW_RESTORE_RWND="$baseline_rwnd"

    read -r -a route_args <<< "$current_route"
    for token in "${route_args[@]}"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$token" in
            initcwnd|initrwnd) skip=1 ;;
            *) clean_args+=("$token") ;;
        esac
    done
    [ "${#clean_args[@]}" -gt 0 ] || return 1
    [ "$baseline_cwnd" -gt 0 ] && target_metrics+=(initcwnd "$baseline_cwnd")
    [ "$baseline_rwnd" -gt 0 ] && target_metrics+=(initrwnd "$baseline_rwnd")
    [ "$snapshot_was_polluted" -eq 0 ] || rewrite_polluted_route_snapshot || return 1
    rewrite_profile_initial_window "$expected_cwnd" "$expected_rwnd" "$baseline_cwnd" "$baseline_rwnd" || return 1
    if [ "$legacy_owned" -eq 1 ]; then
        sed -i '/initcwnd[[:space:]]\+32[[:space:]]\+initrwnd[[:space:]]\+32/d' "$PERSIST_SCRIPT" || return 1
    fi
    ip -4 route replace "${clean_args[@]}" "${target_metrics[@]}" >/dev/null 2>&1 || return 1
    rm -f -- "$INIT_WINDOW_MARKER"
    INIT_WINDOW_CLEARED=1
    return 0
}

prepare_initial_window_for_bandwidth() {
    local bandwidth="$1"

    INIT_WINDOW_MANAGED=0
    INIT_WINDOW_CLEARED=0
    INIT_WINDOW_RESTORE_CWND=0
    INIT_WINDOW_RESTORE_RWND=0
    if initial_window_override_requested; then
        INIT_WINDOW_MANAGED=1
        return 0
    fi
    if [ "$bandwidth" -le 100 ]; then
        if clear_owned_initial_window; then
            [ "$INIT_WINDOW_CLEARED" -eq 1 ] && \
                ui_success "小带宽路径：已清除本脚本旧版遗留的 initcwnd/initrwnd"
        else
            ui_warn "无法清除本脚本旧版初始窗口；当前路由请手工检查"
            return 1
        fi
    fi
}

# 首轮突发随 RTT/带宽放大，与高延迟链路的丢包、重传风险直接冲突，
# 因此只支持显式覆盖，或保留脚本执行前且不属于本项目旧版的路由基线。
calculate_initial_cwnd() {
    local requested="${INIT_CWND:-}"

    if [ "$INIT_WINDOW_CLEARED" -eq 1 ] && [ -z "$requested" ] && [ -z "$INIT_WINDOW_OVERRIDE" ]; then
        echo "$INIT_WINDOW_RESTORE_CWND"
        return 0
    fi
    if [ "$INIT_WINDOW_OVERRIDE" = "32" ]; then
        echo 32
        return 0
    fi
    local baseline_initcwnd=""
    local current_route=""
    local normalized_requested=""

    if normalized_requested=$(normalize_uint "$requested" 10 32); then
        echo "$normalized_requested"
        return 0
    fi

    # 默认保留脚本执行前的路由设置；没有原值时交给内核选择，避免人为放大首轮突发和重传。
    [ -s "$ROUTE_STATE" ] && baseline_initcwnd=$(awk -F= '$1 == "initcwnd" {print $2}' "$ROUTE_STATE")
    if [ -z "$baseline_initcwnd" ] && command -v ip >/dev/null 2>&1; then
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        baseline_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    fi
    if [[ "$baseline_initcwnd" =~ ^[0-9]+$ ]] && [ "$baseline_initcwnd" -gt 0 ]; then
        echo "$baseline_initcwnd"
    else
        echo "0"
    fi
}

calculate_initial_rwnd() {
    local initcwnd="$1"
    local requested="${INIT_RWND:-}"

    if [ "$INIT_WINDOW_CLEARED" -eq 1 ] && [ -z "$requested" ] && [ -z "$INIT_WINDOW_OVERRIDE" ]; then
        echo "$INIT_WINDOW_RESTORE_RWND"
        return 0
    fi
    if [ "$INIT_WINDOW_OVERRIDE" = "32" ]; then
        echo 32
        return 0
    fi
    local baseline_initrwnd=""
    local current_route=""
    local normalized_requested=""

    if normalized_requested=$(normalize_uint "$requested" 10 32); then
        echo "$normalized_requested"
        return 0
    fi
    if normalize_uint "${INIT_CWND:-}" 10 32 >/dev/null && [ "$initcwnd" -gt 0 ]; then
        echo "$initcwnd"
        return 0
    fi

    [ -s "$ROUTE_STATE" ] && baseline_initrwnd=$(awk -F= '$1 == "initrwnd" {print $2}' "$ROUTE_STATE")
    if [ -z "$baseline_initrwnd" ] && command -v ip >/dev/null 2>&1; then
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        baseline_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    fi
    if [[ "$baseline_initrwnd" =~ ^[0-9]+$ ]] && [ "$baseline_initrwnd" -gt 0 ]; then
        echo "$baseline_initrwnd"
    else
        echo "0"
    fi
}

select_initial_window_policy() {
    local profile="$1" bandwidth="${2:-1000}" requested="${ENABLE_INIT_WINDOW_32:-}"

    INIT_WINDOW_OVERRIDE=""
    if normalize_uint "${INIT_CWND:-}" 10 32 >/dev/null 2>&1 || \
       normalize_uint "${INIT_RWND:-}" 10 32 >/dev/null 2>&1; then
        INIT_WINDOW_MANAGED=1
        return 0
    fi
    case "$requested" in
        1|yes|YES|true|TRUE) INIT_WINDOW_OVERRIDE=32; INIT_WINDOW_MANAGED=1; return 0 ;;
        0|no|NO|false|FALSE) return 0 ;;
    esac
    if [ "$bandwidth" -le 100 ]; then
        ui_info "小带宽路径默认保留内核初始窗口；如确需覆盖请使用 INIT_CWND/INIT_RWND" >&2
        return 0
    fi
    [ "$AUTO_MODE" = "1" ] && return 0
    case "$profile" in
        landing|website)
            ui_info "该场景可选 initcwnd/initrwnd 32，加快新连接起步，但会增加首轮突发" >&2
            if confirm_yn "是否启用初始窗口 32？" "n" "n"; then
                INIT_WINDOW_OVERRIDE=32
                INIT_WINDOW_MANAGED=1
            fi
            ;;
        optimize)
            ui_info "跨境中转默认保留内核初始窗口；仅低 RTT 国内直连可考虑 32" >&2
            if confirm_yn "这是低 RTT 国内直连，是否启用初始窗口 32？" "n" "n"; then
                INIT_WINDOW_OVERRIDE=32
                INIT_WINDOW_MANAGED=1
            fi
            ;;
    esac
}

calculate_profile_buffer_size() {
    local bandwidth="$1"
    local rtt_ms="$2"
    local profile="$3"
    local memory_mb="$4"
    local bdp_mb required_mb memory_cap_mb profile_cap_mb buffer_mb
    local minimum_mb memory_divisor hard_cap_mb

    bandwidth=$(normalize_uint "$bandwidth" 1 1000000) || bandwidth=1000
    rtt_ms=$(normalize_uint "$rtt_ms" 1 3000) || rtt_ms="$DEFAULT_TARGET_RTT_MS"
    memory_mb=$(normalize_uint "$memory_mb" 1 1000000000) || memory_mb=512

    # BDP(MB) ≈ Mbps × RTT(ms) / 8000；2 倍余量兼顾自动窗口爬升、突发和重传。
    bdp_mb=$(( (bandwidth * rtt_ms + 7999) / 8000 ))
    [ "$bdp_mb" -lt 1 ] && bdp_mb=1

    case "$profile" in
        website)
            required_mb=$((bdp_mb * 2))
            minimum_mb=4
            memory_divisor=16
            # 建站单连接 64MB 窗口已覆盖网页/API/反代场景，与主流调优脚本上限一致。
            hard_cap_mb=64
            ;;
        *)
            required_mb=$((bdp_mb * 2))
            minimum_mb=4
            memory_divisor=16
            # 128MB 覆盖 2.5Gbps x 200ms 的 2xBDP；再放大只会让 BBR 在被
            # policer 限速的跨境线路囤积 cwnd、撞墙后重传暴涨（netshape 实测教训）。
            hard_cap_mb=128
            ;;
    esac
    [ "$bandwidth" -ge 500 ] && minimum_mb=8
    [ "$required_mb" -lt "$minimum_mb" ] && required_mb=$minimum_mb
    # 以 4 MiB 为粒度向上取整，避免整数 BDP 舍入后重新变得偏小。
    required_mb=$(( ((required_mb + 3) / 4) * 4 ))

    # 最大窗口不会预分配给每个连接；以总内存 1/16 和场景上限约束异常输入。
    # 1/16 与内核默认 tcp_mem 预算同量级，避免少数满速大流把全局 TCP 内存
    # 打进 pressure 导致窗口被自动收缩（RTT 推导的缓冲区在并发下静默失效）。
    memory_cap_mb=$((memory_mb / memory_divisor))
    [ "$memory_cap_mb" -lt "$minimum_mb" ] && memory_cap_mb=$minimum_mb
    [ "$memory_cap_mb" -gt "$hard_cap_mb" ] && memory_cap_mb=$hard_cap_mb
    profile_cap_mb=$memory_cap_mb

    buffer_mb=$required_mb
    [ "$buffer_mb" -gt "$profile_cap_mb" ] && buffer_mb=$profile_cap_mb

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

remove_conflict_mapping() {
    local original_file="$1"
    local disabled_file="$2"
    local state_tmp="${CONFLICT_STATE}.tmp.$$"

    prepare_managed_temp_file "$state_tmp" || return 1
    if ! awk -F '|' -v original="$original_file" -v disabled="$disabled_file" \
        '!(NF == 2 && $1 == original && $2 == disabled)' "$CONFLICT_STATE" > "$state_tmp"; then
        return 1
    fi
    finalize_managed_temp_file "$state_tmp" "$CONFLICT_STATE" 600
}

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
                [[ "$value" =~ ^[0-9]+([KMGTPkmgpt]?[bB]?)?$ ]] || return 1
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

fq_spec_is_valid() {
    local spec="$1" parsed

    [ -n "$spec" ] && [[ "$spec" != *'|'* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
    if [ "$spec" = "default" ]; then
        parsed=$(fq_record_from_output "qdisc fq 0: root") || return 1
    else
        parsed=$(fq_record_from_output "qdisc fq 0: root $spec") || return 1
    fi
    [ "$parsed" = "$spec" ]
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
mq_leaf_count() { mq_leaf_snapshot "$1" | awk -F'|' '{print $2}'; }
mq_leaf_spec() { mq_leaf_snapshot "$1" | awk -F'|' '{print $3}'; }

mq_state_value() {
    local iface="$1" column="$2"

    [ -s "$MQ_STATE" ] && [ ! -L "$MQ_STATE" ] || return 1
    [ "$(head -n 1 "$MQ_STATE" 2>/dev/null)" = "# mq-state-v2" ] || return 1
    awk -F'|' -v wanted="$iface" -v column="$column" '$1 == wanted && NF == 4 {print $column; exit}' "$MQ_STATE"
}

mq_state_leaf_kind() { mq_state_value "$1" 2; }
mq_state_leaf_count() { mq_state_value "$1" 3; }
mq_state_leaf_spec() { mq_state_value "$1" 4; }

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

install_htb_root() {
    local iface="$1" htb_was_owned="${2:-0}" current_kind command_error class_output

    current_kind=$(qdisc_root_kind "$iface")
    case "$current_kind" in
        mq)
            if ! qdisc_remove_root "$iface"; then
                printf '%s\n' "无法安全移除 mq root"
                return 2
            fi
            if ! command_error=$(tc qdisc add dev "$iface" root handle 1: htb default 10 2>&1); then
                printf '%s\n' "${command_error:-无法创建 HTB root}"
                return 2
            fi
            ;;
        htb)
            class_output=$(tc class show dev "$iface" 2>/dev/null)
            if [ "$htb_was_owned" -ne 1 ] || ! managed_htb_root_is_recognizable "$iface" || \
               ! awk '$0 ~ /(^|[[:space:]])1:10([[:space:]]|$)/ {found=1} END {exit !found}' <<< "$class_output"; then
                printf '%s\n' "当前 HTB 不属于本次整形事务"
                return 1
            fi
            if ! command_error=$(tc qdisc del dev "$iface" root 2>&1); then
                printf '%s\n' "${command_error:-无法删除本次事务的 HTB root}"
                return 1
            fi
            if ! command_error=$(tc qdisc add dev "$iface" root handle 1: htb default 10 2>&1); then
                printf '%s\n' "${command_error:-无法重建 HTB root}"
                return 2
            fi
            ;;
        *)
            # 内核自动创建的 fq/fq_codel 常使用 0: handle，可能拒绝 del root；
            # replace 可直接原子切换为 HTB，且不会触碰独立的 clsact/ingress。
            if ! command_error=$(tc qdisc replace dev "$iface" root handle 1: htb default 10 2>&1); then
                printf '%s\n' "${command_error:-无法替换为 HTB root}"
                return 1
            fi
            ;;
    esac
}

qdisc_set_mq_leaves() {
    local iface="$1" leaf_kind="$2" leaf_spec="${3:-default}"
    local output handle major parents parent
    local options=()

    case "$leaf_kind" in
        fq)
            fq_spec_is_valid "$leaf_spec" || return 1
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
    [ "$(mq_leaf_kind "$iface" 2>/dev/null)" = "$leaf_kind" ] && \
        [ "$(mq_leaf_spec "$iface" 2>/dev/null)" = "$leaf_spec" ]
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
    local iface="$1" current_kind

    current_kind=$(qdisc_root_kind "$iface")
    case "$current_kind" in
        mq) qdisc_set_mq_leaves "$iface" fq ;;
        fq) return 0 ;;
        ''|noqueue) tc qdisc add dev "$iface" root fq >/dev/null 2>&1 ;;
        *)
            qdisc_remove_root "$iface" || return 1
            current_kind=$(qdisc_root_kind "$iface")
            case "$current_kind" in
                mq) qdisc_set_mq_leaves "$iface" fq ;;
                fq) return 0 ;;
                *) tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;;
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

    # 兼容 v6.7.5 及更早快照：只在当前仍是原 fq_codel 时补录，绝不从 HTB/FQ 猜原参数。
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

restore_shaper_baseline() {
    local iface="$1" baseline_kind="$2"

    case "$baseline_kind" in
        mq) qdisc_restore_mq "$iface" "$(mq_state_leaf_kind "$iface")" ;;
        fq_codel) restore_fq_codel_root "$iface" ;;
        none|pfifo_fast) qdisc_set_fq "$iface" ;;
        *) return 1 ;;
    esac
}

finish_shaper_test_restore() {
    if restore_transient_qdisc; then
        rm -f -- "$SHAPER_STATE"
        return 0
    fi
    ui_warn "临时出口队列未能恢复，已保留事务状态供下次运行或 restore 重试"
    return 1
}

# tc fq 立即生效（无需重启）
apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        ui_error "未检测到 tc（iproute2），无法应用 fq"
        return 1
    fi
    local failed=0
    local candidates=0
    local root_kind original_kind
    for dev in $(eligible_ifaces); do
        candidates=$((candidates + 1))
        original_kind=$(awk -F'|' -v wanted="$dev" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$root_kind" in
            mq)
                case "$(mq_state_leaf_kind "$dev" 2>/dev/null)" in
                    fq|fq_codel) mq_current_matches_snapshot "$dev" || failed=$((failed + 1)) ;;
                    *) ui_warn "网卡 $dev 的 mq 叶队列无法安全重建，已保持原样" ;;
                esac
                ;;
            fq)
                if [ "$original_kind" = "fq_codel" ] && fq_codel_state_record "$dev" >/dev/null 2>&1; then
                    restore_fq_codel_root "$dev" || failed=$((failed + 1))
                fi
                ;;
            fq_codel)
                if [ "$original_kind" = "fq_codel" ]; then
                    ensure_fq_codel_snapshot_for_iface "$dev" || failed=$((failed + 1))
                fi
                ;;
            ''|pfifo_fast)
                if ! tc qdisc replace dev "$dev" root fq 2>/dev/null; then
                    failed=$((failed + 1))
                fi
                ;;
            *)
                # 无法无损保存参数的队列保持现状，由内核 TCP pacing 继续工作。
                ;;
        esac
    done
    if [ "$candidates" -eq 0 ]; then
        ui_error "未发现可管理的出口网卡，fq 未应用"
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

shaper_state_value() {
    local key="$1"

    [ -s "$SHAPER_STATE" ] || return 1
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$SHAPER_STATE"
}

calculate_fq_limits() {
    local rate="$1" rtt_ms="${2:-$SHAPER_RTT_MS}" memory_mb="${3:-$SHAPER_MEMORY_MB}"
    local cap_limit cap_flow bdp_quarter flow_limit limit

    rate=$(normalize_uint "$rate" 1 100000) || rate=1000
    rtt_ms=$(normalize_uint "$rtt_ms" 1 3000) || rtt_ms="$DEFAULT_TARGET_RTT_MS"
    memory_mb=$(normalize_uint "$memory_mb" 1 1000000000) || memory_mb=1024
    if [ "$memory_mb" -lt 512 ]; then
        cap_limit=4096; cap_flow=512
    elif [ "$memory_mb" -lt 1024 ]; then
        cap_limit=10240; cap_flow=2048
    elif [ "$memory_mb" -lt 2048 ]; then
        cap_limit=20480; cap_flow=4096
    else
        cap_limit=40960; cap_flow=8192
    fi
    # 约 1/4 BDP 的 MTU 包作为单流本地排队预算；FQ 仍由 TCP pacing 控制出队。
    bdp_quarter=$(((rate * rtt_ms + 47) / 48))
    [ "$bdp_quarter" -lt 100 ] && bdp_quarter=100
    flow_limit="$bdp_quarter"
    [ "$flow_limit" -gt "$cap_flow" ] && flow_limit="$cap_flow"
    limit=$((flow_limit * 8))
    [ "$limit" -lt 1024 ] && limit=1024
    [ "$limit" -gt "$cap_limit" ] && limit="$cap_limit"
    [ "$limit" -lt "$flow_limit" ] && limit="$flow_limit"
    printf '%s %s\n' "$limit" "$flow_limit"
}

write_policer_state() {
    local status="$1" loss="$2" peer="$3" port="$4" goodput="$5" delivery="$6"
    local state_tmp="${POLICER_STATE}.tmp.$$" timestamp

    case "$status" in present|absent|unknown) ;; *) return 1 ;; esac
    [[ "$loss" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    normalize_uint "$port" 1 65535 >/dev/null || return 1
    case "$peer" in ''|*'='*|*'|'*|*$'\n'*|*$'\r'*) return 1 ;; esac
    timestamp=$(date +%s 2>/dev/null) || return 1
    normalize_uint "$timestamp" 1 99999999999 >/dev/null || return 1
    prepare_managed_temp_file "$state_tmp" || return 1
    printf '# bbr-policer-state-v1\nstatus=%s\ntimestamp=%s\nloss_pct=%s\npeer=%s\npeer_port=%s\ngoodput_mbps=%s\ndelivery_mbps=%s\n' \
        "$status" "$timestamp" "$loss" "$peer" "$port" "$goodput" "$delivery" > "$state_tmp" || return 1
    finalize_managed_temp_file "$state_tmp" "$POLICER_STATE" 600
}

policer_evidence_status() {
    local status timestamp loss now age

    [ -s "$POLICER_STATE" ] || { printf 'unknown\n'; return 0; }
    status=$(awk -F= '$1 == "status" {print $2; exit}' "$POLICER_STATE")
    timestamp=$(awk -F= '$1 == "timestamp" {print $2; exit}' "$POLICER_STATE")
    loss=$(awk -F= '$1 == "loss_pct" {print $2; exit}' "$POLICER_STATE")
    case "$status" in present|absent|unknown) ;; *) printf 'unknown\n'; return 0 ;; esac
    [[ "$timestamp" =~ ^[0-9]+$ && "$loss" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'unknown\n'; return 0; }
    now=$(date +%s 2>/dev/null || echo 0)
    age=$((now - timestamp))
    if [ "$age" -lt 0 ] || [ "$age" -gt "$POLICER_EVIDENCE_MAX_AGE" ]; then
        printf 'stale\n'
        return 0
    fi
    if [ "$status" = "absent" ] && ! awk -v loss="$loss" 'BEGIN {exit !(loss < 0.1)}'; then
        printf 'unknown\n'
        return 0
    fi
    printf '%s\n' "$status"
}

write_shaper_state() {
    local phase="$1" iface="$2" family="$3" baseline_kind="$4" rate="$5"
    local knee="$6" margin="$7" peer="$8" port="$9"
    local burst_mode="${10:-policer}" fq_limit="${11:-}" fq_flow_limit="${12:-}" kind="${13:-policer}"
    local state_tmp="${SHAPER_STATE}.tmp.$$" limits

    case "$phase" in testing|active) ;; *) return 1 ;; esac
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [ -e "/sys/class/net/$iface" ] || return 1
    case "$family" in 4|6) ;; *) return 1 ;; esac
    case "$baseline_kind" in none|pfifo_fast|fq_codel|mq) ;; *) return 1 ;; esac
    case "$burst_mode" in policer|throughput) ;; *) return 1 ;; esac
    case "$kind" in policer|manual-total|testing) ;; *) return 1 ;; esac
    normalize_uint "$rate" 0 100000 >/dev/null || return 1
    normalize_uint "$knee" 0 100000 >/dev/null || return 1
    normalize_uint "$margin" 0 100000 >/dev/null || return 1
    normalize_uint "$port" 1 65535 >/dev/null || return 1
    case "$peer" in ''|*'='*|*'|'*|*$'\n'*|*$'\r'*) return 1 ;; esac
    if ! fq_limit=$(normalize_uint "$fq_limit" 1024 1000000) ||
       ! fq_flow_limit=$(normalize_uint "$fq_flow_limit" 100 1000000); then
        if [ "$rate" -gt 0 ]; then
            limits=$(calculate_fq_limits "$rate")
            read -r fq_limit fq_flow_limit <<< "$limits"
        else
            fq_limit=1024; fq_flow_limit=100
        fi
    fi

    prepare_managed_temp_file "$state_tmp" || return 1
    if ! printf '# bbr-shaper-state-v2\nphase=%s\niface=%s\nfamily=%s\nbaseline_kind=%s\nrate_mbit=%s\nknee_mbit=%s\nmargin_mbit=%s\npeer=%s\npeer_port=%s\nburst_mode=%s\nfq_limit=%s\nfq_flow_limit=%s\nkind=%s\n' \
        "$phase" "$iface" "$family" "$baseline_kind" "$rate" "$knee" "$margin" "$peer" "$port" \
        "$burst_mode" "$fq_limit" "$fq_flow_limit" "$kind" > "$state_tmp"; then
        return 1
    fi
    finalize_managed_temp_file "$state_tmp" "$SHAPER_STATE" 600
}

managed_shaper_is_active() {
    local wanted_iface="${1:-}" phase iface baseline_kind rate root_kind class_output fq_limit fq_flow_limit

    [ -s "$SHAPER_STATE" ] || return 1
    phase=$(shaper_state_value phase)
    iface=$(shaper_state_value iface)
    baseline_kind=$(shaper_state_value baseline_kind)
    rate=$(shaper_state_value rate_mbit)
    [ "$phase" = "active" ] || return 1
    case "$baseline_kind" in
        none|pfifo_fast) ;;
        fq_codel) ensure_fq_codel_snapshot_for_iface "$iface" || return 1 ;;
        mq) case "$(mq_state_leaf_kind "$iface" 2>/dev/null)" in fq|fq_codel) ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    [ -z "$wanted_iface" ] || [ "$iface" = "$wanted_iface" ] || return 1
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [ -e "/sys/class/net/$iface" ] || return 1
    normalize_uint "$rate" 1 100000 >/dev/null || return 1
    root_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    [ "$root_kind" = "htb" ] || return 1
    class_output=$(tc class show dev "$iface" 2>/dev/null)
    awk '$0 ~ /(^|[[:space:]])1:10([[:space:]]|$)/ {found=1} END {exit !found}' <<< "$class_output" || return 1
    tc qdisc show dev "$iface" 2>/dev/null | awk '$2 == "fq" && $0 ~ /parent 1:10/ {found=1} END {exit !found}' || return 1
    fq_limit=$(shaper_state_value fq_limit); fq_flow_limit=$(shaper_state_value fq_flow_limit)
    [ -n "$fq_limit" ] || fq_limit=40960
    [ -n "$fq_flow_limit" ] || fq_flow_limit=8192
    managed_fq_limits_match "$iface" "$fq_limit" "$fq_flow_limit" || return 1
    managed_shaper_rate_matches "$iface" "$rate"
}

restore_transient_qdisc() {
    local iface="$TRANSIENT_QDISC_IFACE" baseline_kind="$TRANSIENT_QDISC_BASELINE_KIND" root_kind

    [ -n "$iface" ] || return 0
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [ -e "/sys/class/net/$iface" ] || return 1
    case "$baseline_kind" in none|pfifo_fast|fq_codel|mq) ;; *) return 1 ;; esac
    root_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    case "$root_kind" in
        fq)
            case "$baseline_kind" in
                fq_codel) restore_fq_codel_root "$iface" || return 1 ;;
                mq) qdisc_restore_mq "$iface" "$(mq_state_leaf_kind "$iface")" || return 1 ;;
            esac
            ;;
        fq_codel)
            [ "$baseline_kind" = "fq_codel" ] && fq_codel_current_matches_snapshot "$iface" || return 1
            ;;
        mq)
            if [ "$baseline_kind" = "mq" ]; then
                mq_current_matches_snapshot "$iface" || return 1
            else
                [ "$TRANSIENT_QDISC_OWNED" -eq 1 ] || return 1
                restore_shaper_baseline "$iface" "$baseline_kind" || return 1
            fi
            ;;
        htb)
            [ "$TRANSIENT_QDISC_OWNED" -eq 1 ] || return 1
            restore_shaper_baseline "$iface" "$baseline_kind" || return 1
            ;;
        '')
            [ "$TRANSIENT_QDISC_OWNED" -eq 1 ] || return 1
            restore_shaper_baseline "$iface" "$baseline_kind" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    TRANSIENT_QDISC_IFACE=""
    TRANSIENT_QDISC_BASELINE_KIND=""
    TRANSIENT_QDISC_OWNED=0
    return 0
}

managed_htb_root_is_recognizable() {
    local iface="$1" qdisc_output

    qdisc_output=$(tc qdisc show dev "$iface" root 2>/dev/null)
    awk '$1 == "qdisc" && $2 == "htb" && $3 == "1:" && $0 ~ / root / &&
         ($0 ~ / default 10([[:space:]]|$)/ || $0 ~ / default 0x10([[:space:]]|$)/) {found=1}
         END {exit !found}' <<< "$qdisc_output"
}

restore_managed_shaper() {
    local phase iface baseline_kind root_kind class_output

    [ -s "$SHAPER_STATE" ] || return 0
    phase=$(shaper_state_value phase)
    iface=$(shaper_state_value iface)
    baseline_kind=$(shaper_state_value baseline_kind)
    case "$phase" in testing|active) ;; *) ui_warn "整形状态无效，已保留供人工检查"; return 1 ;; esac
    case "$baseline_kind" in none|pfifo_fast|fq_codel|mq) ;; *) ui_warn "整形基线状态无效，已拒绝覆盖"; return 1 ;; esac
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [ -e "/sys/class/net/$iface" ] || {
        ui_warn "整形网卡已不存在，状态文件已保留"
        return 1
    }
    [ "$baseline_kind" != "fq_codel" ] || ensure_fq_codel_snapshot_for_iface "$iface" || {
        ui_warn "找不到可验证的 fq_codel 参数快照，已拒绝覆盖"
        return 1
    }
    root_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    case "$root_kind" in
        fq)
            case "$baseline_kind" in
                fq_codel) restore_fq_codel_root "$iface" || return 1 ;;
                mq) qdisc_restore_mq "$iface" "$(mq_state_leaf_kind "$iface")" || return 1 ;;
            esac
            ;;
        fq_codel)
            [ "$baseline_kind" = "fq_codel" ] && fq_codel_current_matches_snapshot "$iface" || {
                ui_warn "当前 fq_codel 参数与快照不同，已拒绝覆盖"
                return 1
            }
            ;;
        mq)
            if [ "$baseline_kind" != "mq" ] || ! mq_current_matches_snapshot "$iface"; then
                ui_warn "当前 mq 叶队列与快照不同，已拒绝覆盖"
                return 1
            fi
            ;;
        htb)
            class_output=$(tc class show dev "$iface" 2>/dev/null)
            if ! awk '$0 ~ /(^|[[:space:]])1:10([[:space:]]|$)/ {found=1} END {exit !found}' <<< "$class_output" && \
               ! managed_htb_root_is_recognizable "$iface"; then
                ui_warn "检测到非本脚本结构的 HTB，已拒绝覆盖"
                return 1
            fi
            if ! restore_shaper_baseline "$iface" "$baseline_kind"; then
                ui_warn "未能恢复出口整形前的 ${baseline_kind} 队列"
                return 1
            fi
            ;;
        '')
            if ! restore_shaper_baseline "$iface" "$baseline_kind"; then
                ui_warn "空 root 队列未能恢复为整形前的 ${baseline_kind}"
                return 1
            fi
            ;;
        *)
            ui_warn "网卡 $iface 的队列已被后续修改为 ${root_kind:-未知}，未自动覆盖"
            return 1
            ;;
    esac
    TRANSIENT_QDISC_IFACE=""
    TRANSIENT_QDISC_BASELINE_KIND=""
    TRANSIENT_QDISC_OWNED=0
    rm -f -- "$SHAPER_STATE"
    return 0
}

recover_incomplete_shaper_state() {
    local phase

    [ -s "$SHAPER_STATE" ] || return 0
    phase=$(shaper_state_value phase)
    case "$phase" in
        active)
            if managed_shaper_is_active; then
                ui_info "已检测到本脚本管理的出口整形，本次未重测时将继续保留"
            elif restore_managed_shaper; then
                ui_warn "出口整形未完整生效，已恢复整形前队列并清理旧状态"
            else
                ui_error "出口整形状态与实际队列不一致，已停止应用以避免覆盖"
                return 1
            fi
            ;;
        testing)
            restore_managed_shaper || return 1
            ui_warn "检测到上次中断的队列测试，已恢复整形前队列"
            ;;
        *)
            ui_error "出口整形状态无效，已停止应用以避免覆盖当前队列"
            return 1
            ;;
    esac
}

tc_rate_mbit() {
    local output="${1:-}"

    awk '
        {
            for (i = 1; i < NF; i++) {
                if ($i != "rate" || $(i + 1) !~ /^[0-9.]+[KMGTkmgt]?bit$/) continue
                value = $(i + 1)
                unit = value
                sub(/^[0-9.]+/, "", unit)
                sub(/bit$/, "", unit)
                number = value + 0
                if (unit == "K" || unit == "k") number /= 1000
                else if (unit == "G" || unit == "g") number *= 1000
                else if (unit == "T" || unit == "t") number *= 1000000
                else if (unit == "") number /= 1000000
                printf "%.3f\n", number
                exit
            }
        }
    ' <<< "$output"
}

managed_shaper_rate_matches() {
    local iface="$1" expected="$2" actual

    actual=$(tc_rate_mbit "$(tc class show dev "$iface" 2>/dev/null)")
    [[ "$actual" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v actual="$actual" -v expected="$expected" 'BEGIN {
        difference = actual - expected
        if (difference < 0) difference = -difference
        tolerance = expected * 0.01
        if (tolerance < 1) tolerance = 1
        exit !(difference <= tolerance)
    }'
}

managed_fq_limits_match() {
    local iface="$1" expected_limit="$2" expected_flow_limit="$3"

    normalize_uint "$expected_limit" 1024 1000000 >/dev/null || return 1
    normalize_uint "$expected_flow_limit" 100 1000000 >/dev/null || return 1
    LC_ALL=C tc -d qdisc show dev "$iface" 2>/dev/null | awk \
        -v expected_limit="$expected_limit" -v expected_flow="$expected_flow_limit" '
        $2 == "fq" && $0 ~ /parent 1:10/ {
            limit=""; flow=""
            for (i = 1; i < NF; i++) {
                if ($i == "limit") {limit=$(i + 1); gsub(/p$/, "", limit)}
                else if ($i == "flow_limit") {flow=$(i + 1); gsub(/p$/, "", flow)}
            }
            if (limit == expected_limit && flow == expected_flow) found=1
        }
        END {exit !found}
    '
}

set_shaper_apply_error() {
    local stage="$1" detail="${2:-}"

    SHAPER_APPLY_ERROR_STAGE="$stage"
    detail=$(printf '%s\n' "$detail" | tr '\n\r\t' '   ' | awk '{$1=$1; print}')
    SHAPER_APPLY_ERROR_DETAIL="${detail:0:240}"
}

report_shaper_apply_error() {
    [ -n "$SHAPER_APPLY_ERROR_STAGE" ] && ui_warn "出口整形失败阶段：$SHAPER_APPLY_ERROR_STAGE"
    [ -n "$SHAPER_APPLY_ERROR_DETAIL" ] && ui_info "tc 返回：$SHAPER_APPLY_ERROR_DETAIL"
}

rollback_failed_shaper_apply() {
    local iface="$1" baseline_kind="$2"

    if restore_shaper_baseline "$iface" "$baseline_kind" >/dev/null 2>&1; then
        TRANSIENT_QDISC_IFACE=""
        TRANSIENT_QDISC_BASELINE_KIND=""
        TRANSIENT_QDISC_OWNED=0
        return 0
    fi
    return 1
}

apply_test_shaper() {
    local iface="$1" rate="$2" burst_mode="${3:-policer}" baseline_kind="$TRANSIENT_QDISC_BASELINE_KIND"
    local burst_kb limits fq_limit fq_flow_limit command_error install_rc htb_was_owned

    SHAPER_APPLY_ERROR_STAGE=""
    SHAPER_APPLY_ERROR_DETAIL=""
    normalize_uint "$rate" 1 100000 >/dev/null || { set_shaper_apply_error "参数校验" "整形速率无效"; return 1; }
    case "$burst_mode" in policer|throughput) ;; *) set_shaper_apply_error "参数校验" "突发模式无效"; return 1 ;; esac
    if [ "$burst_mode" = "throughput" ] && [ "$(policer_evidence_status)" != "absent" ]; then
        set_shaper_apply_error "证据校验" "缺少近期无 policer 证据"
        return 1
    fi
    burst_kb=$(calculate_shaper_burst_kb "$rate" "$burst_mode")
    limits=$(calculate_fq_limits "$rate")
    read -r fq_limit fq_flow_limit <<< "$limits"
    case "$baseline_kind" in none|pfifo_fast|fq_codel|mq) ;; *) set_shaper_apply_error "原队列校验" "不支持的原队列 ${baseline_kind:-unknown}"; return 1 ;; esac
    if [ "$baseline_kind" = "fq_codel" ] && ! ensure_fq_codel_snapshot_for_iface "$iface"; then
        set_shaper_apply_error "原队列快照" "fq_codel 参数快照不可用"
        return 1
    fi
    if [ "$baseline_kind" = "mq" ]; then
        case "$(mq_state_leaf_kind "$iface" 2>/dev/null)" in fq|fq_codel) ;; *) set_shaper_apply_error "原队列校验" "mq 叶队列无法安全重建"; return 1 ;; esac
        case "$(qdisc_root_kind "$iface")" in
            mq) mq_current_matches_snapshot "$iface" || { set_shaper_apply_error "原队列校验" "mq 运行结构与快照不一致"; return 1; } ;;
            htb) [ "$TRANSIENT_QDISC_OWNED" -eq 1 ] || { set_shaper_apply_error "原队列校验" "当前 HTB 不属于本次事务"; return 1; } ;;
            *) set_shaper_apply_error "原队列校验" "当前队列不是可管理的 mq/HTB"; return 1 ;;
        esac
    fi
    TRANSIENT_QDISC_IFACE="$iface"
    htb_was_owned="$TRANSIENT_QDISC_OWNED"
    if command_error=$(install_htb_root "$iface" "$htb_was_owned"); then
        install_rc=0
    else
        install_rc=$?
    fi
    if [ "$install_rc" -ne 0 ]; then
        set_shaper_apply_error "切换为 HTB root" "$command_error"
        if [ "$install_rc" -eq 2 ]; then
            TRANSIENT_QDISC_OWNED=1
            rollback_failed_shaper_apply "$iface" "$baseline_kind" || true
        fi
        return 1
    fi
    TRANSIENT_QDISC_OWNED=1
    if ! command_error=$(tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" \
        burst "${burst_kb}kb" cburst "${burst_kb}kb" quantum 1514 2>&1); then
        set_shaper_apply_error "创建 HTB class 1:10" "$command_error"
        rollback_failed_shaper_apply "$iface" "$baseline_kind" || true
        return 1
    fi
    if ! command_error=$(tc qdisc add dev "$iface" parent 1:10 handle 10: fq limit "$fq_limit" flow_limit "$fq_flow_limit" \
        maxrate "${rate}mbit" 2>&1); then
        set_shaper_apply_error "创建 FQ 叶队列" "$command_error"
        rollback_failed_shaper_apply "$iface" "$baseline_kind" || true
        return 1
    fi
    if ! managed_shaper_rate_matches "$iface" "$rate"; then
        set_shaper_apply_error "校验 HTB 速率" "未读取到期望的 ${rate} Mbit class"
        rollback_failed_shaper_apply "$iface" "$baseline_kind" || true
        return 1
    fi
    if ! managed_fq_limits_match "$iface" "$fq_limit" "$fq_flow_limit"; then
        set_shaper_apply_error "校验 FQ 叶队列" "未读取到期望的 limit=${fq_limit} flow_limit=${fq_flow_limit}"
        rollback_failed_shaper_apply "$iface" "$baseline_kind" || true
        return 1
    fi
    return 0
}

terminate_process_tree() {
    local pid="$1" signal="${2:-TERM}" child children=""

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
    case "$signal" in TERM|KILL) ;; *) return 1 ;; esac
    if [ -r "/proc/$pid/task/$pid/children" ]; then
        read -r children < "/proc/$pid/task/$pid/children" || true
        for child in $children; do
            terminate_process_tree "$child" "$signal"
        done
    fi
    kill -s "$signal" "$pid" 2>/dev/null || true
}

IPERF_SAMPLE_GOODPUT=""
IPERF_SAMPLE_RECEIVER=""
IPERF_SAMPLE_RETRANS=""
IPERF_SAMPLE_PORT=""
IPERF_SAMPLE_ERROR=""

run_iperf_sample() {
    local host="$1" preferred_port="$2" duration="${3:-6}"
    local port seen="" tmp_file output receiver_output parsed runner_pid error_output
    local timeout_args=()

    IPERF_SAMPLE_GOODPUT=""
    IPERF_SAMPLE_RECEIVER=""
    IPERF_SAMPLE_RETRANS=""
    IPERF_SAMPLE_PORT=""
    IPERF_SAMPLE_ERROR=""
    tmp_file=$(mktemp /tmp/bbr-iperf-run.XXXXXX) || { IPERF_SAMPLE_ERROR="无法创建 iperf3 临时输出文件"; return 1; }
    MANAGED_TEMP_FILES+=("$tmp_file")
    timeout --foreground 1 true >/dev/null 2>&1 && timeout_args=(--foreground)
    for port in "$preferred_port" 5201 5202 5203 5200; do
        case " $seen " in *" $port "*) continue ;; esac
        seen="$seen $port"
        : > "$tmp_file"
        timeout "${timeout_args[@]}" $((duration + 20)) iperf3 "$IPERF_FAMILY" -c "$host" -p "$port" -t "$duration" -P 1 -f m \
            > "$tmp_file" 2>&1 &
        runner_pid=$!
        trap 'terminate_process_tree "$runner_pid" TERM; kill -TERM -- "-$runner_pid" 2>/dev/null || true; sleep 1; terminate_process_tree "$runner_pid" KILL; kill -KILL -- "-$runner_pid" 2>/dev/null || true; rm -f -- "$tmp_file"; exit 130' INT TERM HUP
        wait "$runner_pid" 2>/dev/null || true
        trap - INT TERM HUP
        output=$(LC_ALL=C awk '/sender$/ {line=$0} END {print line}' "$tmp_file")
        receiver_output=$(LC_ALL=C awk '/receiver$/ {line=$0} END {print line}' "$tmp_file")
        IPERF_SAMPLE_GOODPUT=""
        IPERF_SAMPLE_RECEIVER=""
        IPERF_SAMPLE_RETRANS=""
        parsed=$(LC_ALL=C awk '
            {
                if (NF < 4) exit
                goodput=$(NF-3); retrans=$(NF-1)
                if (goodput ~ /^[0-9]+([.][0-9]+)?$/ && retrans ~ /^[0-9]+$/)
                    print goodput, retrans
            }
        ' <<< "$output")
        [ -n "$parsed" ] && read -r IPERF_SAMPLE_GOODPUT IPERF_SAMPLE_RETRANS <<< "$parsed"
        IPERF_SAMPLE_RECEIVER=$(LC_ALL=C awk '
            {
                if (NF < 3) exit
                value=$(NF-2)
                if (value ~ /^[0-9]+([.][0-9]+)?$/) print value
            }
        ' <<< "$receiver_output")
        if [ -s "$tmp_file" ]; then
            error_output=$(tail -n 4 "$tmp_file" 2>/dev/null | tr '\n\r\t' '   ' | awk '{$1=$1; print}')
            [ -n "$error_output" ] && IPERF_SAMPLE_ERROR="${error_output:0:240}"
        fi
        if [[ "$IPERF_SAMPLE_GOODPUT" =~ ^[0-9]+([.][0-9]+)?$ && "$IPERF_SAMPLE_RETRANS" =~ ^[0-9]+$ ]]; then
            IPERF_SAMPLE_PORT="$port"
            IPERF_SAMPLE_ERROR=""
            rm -f -- "$tmp_file"
            return 0
        fi
    done
    rm -f -- "$tmp_file"
    [ -n "$IPERF_SAMPLE_ERROR" ] || IPERF_SAMPLE_ERROR="iperf3 未返回可解析的 sender 结果"
    return 1
}

run_iperf_sample_with_retries() {
    local host="$1" port="$2" duration="$3" max_attempts="${4:-3}"
    local attempt last_error=""

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if run_iperf_sample "$host" "$port" "$duration"; then
            return 0
        fi
        last_error="$IPERF_SAMPLE_ERROR"
        if [ "$attempt" -lt "$max_attempts" ]; then
            ui_info "iperf3 暂无有效结果，等待 ${SHAPER_IPERF_RETRY_GAP} 秒后重试（$((attempt + 1))/${max_attempts}）"
            sleep "$SHAPER_IPERF_RETRY_GAP"
        fi
    done
    IPERF_SAMPLE_ERROR="$last_error"
    return 1
}

iperf_loss_percent() {
    local retrans="$1" goodput="$2" duration="$3"

    awk -v rt="$retrans" -v gp="$goodput" -v d="$duration" 'BEGIN {
        packets = gp * 1000000 * d / 8 / 1448
        if (packets < 1) packets = 1
        printf "%.4f", rt * 100 / packets
    }'
}

calculate_shaper_burst_kb() {
    local rate="$1" mode="${2:-policer}" burst_kb

    case "$mode" in
        throughput)
            burst_kb=$(((rate * 1250 + 1023) / 1024))
            [ "$burst_kb" -lt 64 ] && burst_kb=64
            [ "$burst_kb" -gt 4096 ] && burst_kb=4096
            ;;
        *)
            burst_kb=$(((rate * 125 + 1023) / 1024))
            [ "$burst_kb" -lt 32 ] && burst_kb=32
            [ "$burst_kb" -gt 256 ] && burst_kb=256
            ;;
    esac
    printf '%s\n' "$burst_kb"
}

SHAPER_TEST_LOSS=""
SHAPER_BASE_LOSS=""
SHAPER_TEST_ERROR_KIND=""
SHAPER_TEST_ERROR_DETAIL=""

set_shaper_test_error() {
    SHAPER_TEST_ERROR_KIND="$1"
    SHAPER_TEST_ERROR_DETAIL="${2:0:240}"
}

report_shaper_test_error() {
    case "$SHAPER_TEST_ERROR_KIND" in
        shaper) report_shaper_apply_error ;;
        iperf)
            ui_warn "出口整形测试失败阶段：iperf3 测速"
            [ -n "$SHAPER_TEST_ERROR_DETAIL" ] && ui_info "iperf3 返回：$SHAPER_TEST_ERROR_DETAIL"
            ;;
    esac
}

shaper_loss_is_spike() {
    local loss="$1"

    # 同时满足绝对阈值和相对本底阈值才算跳变。相对阈值最高封顶 1%，
    # 避免 0.1%-0.3% 的稳定线路底噪遮住真实 policer 拐点。
    awk -v loss="$loss" -v base="${SHAPER_BASE_LOSS:-0}" 'BEGIN {
        need=0.1
        if (base > 0 && base * 5 > need) need=base * 5
        if (need > 1) need=1
        exit !(loss > need)
    }'
}

test_shaper_rate_is_clean() {
    local iface="$1" rate="$2" host="$3" port="$4" duration="${5:-6}" establish_base="${6:-0}"
    local hits=0 retry retry_loss valid_samples=1 min_loss clean_loss=""

    SHAPER_TEST_ERROR_KIND=""
    SHAPER_TEST_ERROR_DETAIL=""
    if ! apply_test_shaper "$iface" "$rate" policer; then
        set_shaper_test_error shaper "${rate} Mbit 临时整形创建失败"
        return 2
    fi
    sleep "$SHAPER_TEST_GAP"
    if ! run_iperf_sample_with_retries "$host" "$port" "$duration" 3; then
        set_shaper_test_error iperf "${rate} Mbit：${IPERF_SAMPLE_ERROR:-未返回有效结果}"
        return 2
    fi
    SHAPER_TEST_LOSS=$(iperf_loss_percent "$IPERF_SAMPLE_RETRANS" "$IPERF_SAMPLE_GOODPUT" "$duration")
    min_loss="$SHAPER_TEST_LOSS"
    ui_info "测试 ${rate} Mbit：吞吐 ${IPERF_SAMPLE_GOODPUT} Mbps / 重传 ${IPERF_SAMPLE_RETRANS} / 估算 ${SHAPER_TEST_LOSS}%"
    if [ "$establish_base" = "1" ]; then
        if awk -v loss="$SHAPER_TEST_LOSS" 'BEGIN {exit !(loss <= 0.1)}'; then
            SHAPER_BASE_LOSS="$SHAPER_TEST_LOSS"
            return 0
        fi
        hits=1
        for retry in 2 3; do
            sleep "$SHAPER_TEST_GAP"
            if ! run_iperf_sample "$host" "$port" "$duration"; then
                continue
            fi
            valid_samples=$((valid_samples + 1))
            retry_loss=$(iperf_loss_percent "$IPERF_SAMPLE_RETRANS" "$IPERF_SAMPLE_GOODPUT" "$duration")
            ui_info "基线复测 ${rate} Mbit（${retry}/3）：吞吐 ${IPERF_SAMPLE_GOODPUT} Mbps / 重传 ${IPERF_SAMPLE_RETRANS} / 估算 ${retry_loss}%"
            awk -v x="$retry_loss" -v y="$min_loss" 'BEGIN {exit !(x < y)}' && min_loss="$retry_loss"
            if awk -v loss="$retry_loss" 'BEGIN {exit !(loss > 0.1)}'; then
                hits=$((hits + 1))
            else
                clean_loss="$retry_loss"
            fi
        done
        if [ "$hits" -ge 2 ]; then
            SHAPER_TEST_LOSS="$min_loss"
            return 1
        fi
        if [ -n "$clean_loss" ]; then
            SHAPER_TEST_LOSS="$clean_loss"
            SHAPER_BASE_LOSS="$clean_loss"
            ui_info "${rate} Mbit 的浅丢包未稳定复现，采用干净复测建立本底"
            return 0
        fi
        if [ "$valid_samples" -lt 2 ]; then
            set_shaper_test_error iperf "${rate} Mbit 复测：${IPERF_SAMPLE_ERROR:-有效样本不足}"
        fi
        ui_warn "${rate} Mbit 的线路本底无法完成确认"
        return 2
    fi

    shaper_loss_is_spike "$SHAPER_TEST_LOSS" || return 0
    hits=1
    for retry in 2 3; do
        sleep "$SHAPER_TEST_GAP"
        if ! run_iperf_sample "$host" "$port" "$duration"; then
            continue
        fi
        valid_samples=$((valid_samples + 1))
        retry_loss=$(iperf_loss_percent "$IPERF_SAMPLE_RETRANS" "$IPERF_SAMPLE_GOODPUT" "$duration")
        ui_info "复测 ${rate} Mbit（${retry}/3）：吞吐 ${IPERF_SAMPLE_GOODPUT} Mbps / 重传 ${IPERF_SAMPLE_RETRANS} / 估算 ${retry_loss}%"
        awk -v x="$retry_loss" -v y="$min_loss" 'BEGIN {exit !(x < y)}' && min_loss="$retry_loss"
        if shaper_loss_is_spike "$retry_loss"; then
            hits=$((hits + 1))
        else
            clean_loss="$retry_loss"
        fi
    done
    if [ "$hits" -ge 2 ]; then
        SHAPER_TEST_LOSS="$min_loss"
        return 1
    fi
    if [ "$valid_samples" -lt 2 ]; then
        set_shaper_test_error iperf "${rate} Mbit 复测：${IPERF_SAMPLE_ERROR:-有效样本不足}"
        ui_warn "${rate} Mbit 的丢包跳变无法完成复测"
        return 2
    fi
    if [ -n "$clean_loss" ]; then
        SHAPER_TEST_LOSS="$clean_loss"
    fi
    ui_info "${rate} Mbit 的单次丢包跳变未在复测中确认，按瞬时波动处理"
    return 0
}

verify_recommended_shaper_rate() {
    local iface="$1" rate="$2" host="$3" port="$4" duration="${5:-6}"
    local attempt loss

    SHAPER_TEST_ERROR_KIND=""
    SHAPER_TEST_ERROR_DETAIL=""
    if ! apply_test_shaper "$iface" "$rate"; then
        set_shaper_test_error shaper "${rate} Mbit 推荐值整形创建失败"
        return 2
    fi
    for attempt in 1 2; do
        if ! run_iperf_sample_with_retries "$host" "$port" "$duration" 3; then
            set_shaper_test_error iperf "${rate} Mbit 推荐值验证：${IPERF_SAMPLE_ERROR:-未返回有效结果}"
            return 2
        fi
        loss=$(iperf_loss_percent "$IPERF_SAMPLE_RETRANS" "$IPERF_SAMPLE_GOODPUT" "$duration")
        ui_info "验证推荐值 ${rate} Mbit（${attempt}/2）：吞吐 ${IPERF_SAMPLE_GOODPUT} Mbps / 重传 ${IPERF_SAMPLE_RETRANS} / 估算 ${loss}%"
        if shaper_loss_is_spike "$loss"; then
            return 1
        fi
        [ "$attempt" -eq 2 ] || sleep "$SHAPER_TEST_GAP"
    done
    return 0
}

calculate_shaper_margin() {
    local bandwidth="$1"

    if [ "$bandwidth" -le 30 ]; then echo 1
    elif [ "$bandwidth" -le 60 ]; then echo 2
    elif [ "$bandwidth" -le 100 ]; then echo 5
    elif [ "$bandwidth" -le 300 ]; then echo 10
    elif [ "$bandwidth" -le 600 ]; then echo 15
    elif [ "$bandwidth" -le 1000 ]; then echo 25
    else echo 40
    fi
}

configure_manual_total_shaper() {
    local iface="$1" family="$2" baseline_kind="$3" max_rate="$4" duration="$5"
    local baseline_goodput="$6" baseline_delivery="$7" baseline_loss="$8"
    local requested="${EGRESS_LIMIT_MBPS:-}" rate="" post_loss limits fq_limit fq_flow_limit

    if ! rate=$(normalize_uint "$requested" 1 100000); then
        if [ "$AUTO_MODE" = "1" ]; then
            return 0
        fi
        if ! confirm_yn "是否设置整机总出口保护值（throughput 模式）？" "n" "n"; then
            return 0
        fi
        while true; do
            if ! read -e -p "请输入整机总出口上限 [1-${max_rate}] Mbit: " requested; then
                requested=""
            fi
            if rate=$(normalize_uint "$requested" 1 "$max_rate"); then
                break
            fi
            ui_warn "请输入 1-${max_rate} 之间的整数"
        done
    fi
    if [ "$rate" -gt "$max_rate" ]; then
        ui_warn "整机总出口上限 ${rate} Mbit 超过本次选择带宽 ${max_rate} Mbit，未应用整形"
        return 0
    fi
    if [ "$(policer_evidence_status)" != "absent" ]; then
        ui_warn "近期主动测试证据不足，throughput 模式未解锁"
        return 0
    fi

    limits=$(calculate_fq_limits "$rate")
    read -r fq_limit fq_flow_limit <<< "$limits"
    if ! write_shaper_state testing "$iface" "$family" "$baseline_kind" "$rate" 0 0 \
        "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" throughput "$fq_limit" "$fq_flow_limit" testing; then
        ui_warn "无法记录 throughput 测试事务，未修改出口队列"
        return 0
    fi
    TRANSIENT_QDISC_IFACE="$iface"
    TRANSIENT_QDISC_BASELINE_KIND="$baseline_kind"
    TRANSIENT_QDISC_OWNED=0
    if ! apply_test_shaper "$iface" "$rate" throughput; then
        report_shaper_apply_error
        if finish_shaper_test_restore; then
            ui_warn "整机总出口保护未启用；原队列已恢复，基础网络调优继续有效"
            return 0
        fi
        ui_error "整机总出口保护失败且原队列未能恢复"
        return 1
    fi
    if ! run_iperf_sample_with_retries "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration" 3; then
        [ -z "$IPERF_SAMPLE_ERROR" ] || ui_info "iperf3 返回：$IPERF_SAMPLE_ERROR"
        if ! finish_shaper_test_restore; then
            ui_error "throughput 验证失败且原队列未能恢复"
            return 1
        fi
        ui_warn "throughput 模式验证失败，已恢复原队列；基础网络调优继续有效"
        return 0
    fi
    post_loss=$(iperf_loss_percent "$IPERF_SAMPLE_RETRANS" "$IPERF_SAMPLE_GOODPUT" "$duration")
    ui_info "throughput 验证：吞吐 ${IPERF_SAMPLE_GOODPUT} Mbps / 重传 ${IPERF_SAMPLE_RETRANS} / 估算 ${post_loss}%"
    if ! awk -v loss="$post_loss" 'BEGIN {exit !(loss < 0.1)}'; then
        if ! finish_shaper_test_restore; then
            ui_error "throughput 验证未通过且原队列未能恢复"
            return 1
        fi
        ui_warn "throughput 模式验证重传率未低于 0.1%，已恢复原队列；基础网络调优继续有效"
        return 0
    fi
    if ! write_shaper_state active "$iface" "$family" "$baseline_kind" "$rate" 0 0 \
        "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" throughput "$fq_limit" "$fq_flow_limit" manual-total; then
        if ! finish_shaper_test_restore; then
            ui_error "无法保存整形状态且原队列未能恢复"
            return 1
        fi
        ui_warn "无法保存整机出口保护状态，已恢复原队列；基础网络调优继续有效"
        return 0
    fi
    TRANSIENT_QDISC_IFACE=""
    TRANSIENT_QDISC_BASELINE_KIND=""
    TRANSIENT_QDISC_OWNED=0
    ui_success "已应用整机总出口保护 ${rate} Mbit（throughput≈10ms，FQ ${fq_limit}/${fq_flow_limit}）"
    ui_info "主动基线：发送 ${baseline_goodput} / 送达 ${baseline_delivery} Mbps，重传估算 ${baseline_loss}%"
    return 0
}

maybe_configure_egress_shaper() {
    local selected_bandwidth="${1:-1000}"
    local iface original_kind current_kind family=4
    local duration=6 baseline_loss baseline_goodput baseline_delivery baseline_retrans
    local confirm_loss confirm_goodput confirm_delivery confirm_retrans
    local limits fq_limit fq_flow_limit
    local low high mid margin recommended knee test_rc high_confirmed=0
    local control_rate control_loss known_broke known_loss control_attempts lower_rc
    local search_precision search_round=0 max_search_rounds=9
    local verify_rc adjustment=0 max_adjustments=3 verified=0 auto_test=n

    selected_bandwidth=$(normalize_uint "$selected_bandwidth" 1 100000) || selected_bandwidth=1000
    if normalize_uint "${EGRESS_LIMIT_MBPS:-}" 1 100000 >/dev/null 2>&1 || \
       [ "${RUN_POLICER_TEST:-0}" = "1" ]; then
        auto_test=y
    fi
    ui_info "可继续检测 VPS 出口是否存在端口限速器；通常约 1-2 分钟，链路波动时最多约 4 分钟"
    if ! confirm_yn "是否自动检测并计算出口整形值？" "y" "$auto_test"; then
        return 0
    fi
    command -v tc >/dev/null 2>&1 || { ui_warn "缺少 tc，已跳过出口整形"; return 0; }
    command -v timeout >/dev/null 2>&1 || { ui_warn "缺少 timeout，已跳过出口整形"; return 0; }
    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_htb >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
    fi
    if managed_shaper_is_active; then
        if ! restore_managed_shaper; then
            ui_warn "现有出口整形无法安全暂停，已取消重测"
            return 1
        fi
        ui_info "已暂停旧整形，开始重新检测"
    fi

    detect_iperf_family
    iface=$(default_egress_iface)
    [ -n "$iface" ] || { ui_warn "找不到默认出口网卡，已跳过出口整形"; return 0; }
    original_kind=$(awk -F '|' -v wanted="$iface" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
    current_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    case "$original_kind:$current_kind" in
        none:fq|pfifo_fast:fq)
            ;;
        fq_codel:fq_codel)
            if ! ensure_fq_codel_snapshot_for_iface "$iface" || ! fq_codel_current_matches_snapshot "$iface"; then
                ui_warn "网卡 $iface 的 fq_codel 参数无法完整保存并验证，已跳过整形"
                return 0
            fi
            ui_success "已保存并验证网卡 $iface 的完整 fq_codel 参数，测试后可精确恢复"
            ;;
        mq:mq)
            if ! mq_current_matches_snapshot "$iface"; then
                ui_warn "网卡 $iface 的 mq 叶队列类型、参数或队列数与快照不一致，已跳过整形"
                return 0
            fi
            case "$(mq_state_leaf_kind "$iface" 2>/dev/null)" in
                fq|fq_codel) ;;
                *) ui_warn "网卡 $iface 的 mq 叶队列无法安全重建，已跳过整形"; return 0 ;;
            esac
            ui_success "已验证网卡 $iface 的多队列结构，测试后将恢复 mq 及原叶队列"
            ;;
        *)
            ui_warn "网卡 $iface 的原队列为 ${original_kind:-未知}、当前为 ${current_kind:-未知}；无法保证精确恢复，已跳过整形"
            return 0
            ;;
    esac

    if ! ensure_iperf3; then
        ui_warn "iperf3 不可用，已跳过端口限速器测试"
        return 0
    fi
    if ! select_public_iperf_peer; then
        ui_warn "无法自动选择公共 iperf3 节点，已跳过端口限速器测试"
        return 0
    fi
    [ "$IPERF_FAMILY" = "-6" ] && family=6
    if ! write_shaper_state testing "$iface" "$family" "$original_kind" 0 0 0 \
        "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" policer 1024 100 testing; then
        ui_warn "无法记录队列测试事务，已跳过整形"
        return 0
    fi
    TRANSIENT_QDISC_IFACE="$iface"
    TRANSIENT_QDISC_BASELINE_KIND="$original_kind"
    TRANSIENT_QDISC_OWNED=0

    ui_info "先按当前 ${current_kind} 队列进行不限速基线测试"
    if ! run_iperf_sample "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration"; then
        if ! finish_shaper_test_restore; then return 1; fi
        ui_warn "公共节点当前繁忙或不可达，已跳过整形"
        return 0
    fi
    baseline_goodput="$IPERF_SAMPLE_GOODPUT"
    baseline_delivery="${IPERF_SAMPLE_RECEIVER:-$IPERF_SAMPLE_GOODPUT}"
    baseline_retrans="$IPERF_SAMPLE_RETRANS"
    PUBLIC_IPERF_PORT="$IPERF_SAMPLE_PORT"
    baseline_loss=$(iperf_loss_percent "$baseline_retrans" "$baseline_goodput" "$duration")
    ui_info "不限速：发送 ${baseline_goodput} Mbps / 送达 ${baseline_delivery} Mbps / 重传 ${baseline_retrans} / 估算 ${baseline_loss}%"
    if awk -v loss="$baseline_loss" 'BEGIN {exit !(loss < 0.1)}'; then
        ui_info "首次基线低重传，等待 ${SHAPER_TEST_GAP} 秒后复测以确认无 policer 证据"
        sleep "$SHAPER_TEST_GAP"
        if ! run_iperf_sample "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration"; then
            write_policer_state unknown "$baseline_loss" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" \
                "$baseline_goodput" "$baseline_delivery" || true
            if ! finish_shaper_test_restore; then return 1; fi
            ui_warn "第二次基线测试失败，policer 状态保持未确认"
            return 0
        fi
        confirm_goodput="$IPERF_SAMPLE_GOODPUT"
        confirm_delivery="${IPERF_SAMPLE_RECEIVER:-$IPERF_SAMPLE_GOODPUT}"
        confirm_retrans="$IPERF_SAMPLE_RETRANS"
        confirm_loss=$(iperf_loss_percent "$confirm_retrans" "$confirm_goodput" "$duration")
        ui_info "不限速复测：发送 ${confirm_goodput} Mbps / 送达 ${confirm_delivery} Mbps / 重传 ${confirm_retrans} / 估算 ${confirm_loss}%"
        if awk -v loss="$confirm_loss" 'BEGIN {exit !(loss < 0.1)}'; then
            if ! write_policer_state absent "$confirm_loss" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" \
                "$confirm_goodput" "$confirm_delivery"; then
                ui_warn "无法保存主动测试证据，throughput 模式不会解锁"
            fi
            if ! finish_shaper_test_restore; then return 1; fi
            ui_success "连续两次主动测试未发现明显端口 policer（重传估算均 <0.1%）"
            configure_manual_total_shaper "$iface" "$family" "$original_kind" "$selected_bandwidth" "$duration" \
                "$confirm_goodput" "$confirm_delivery" "$confirm_loss"
            return $?
        fi
        baseline_goodput="$confirm_goodput"
        baseline_delivery="$confirm_delivery"
        baseline_retrans="$confirm_retrans"
        baseline_loss="$confirm_loss"
        ui_warn "第二次基线重传升高，不能证明无 policer；继续检查是否存在可复现拐点"
    fi
    write_policer_state unknown "$baseline_loss" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" \
        "$baseline_goodput" "$baseline_delivery" || true

    low=$(awk -v g="$baseline_delivery" 'BEGIN {v=int(g*0.80); if(v<1)v=1; print v}')
    high=$(awk -v g="$baseline_delivery" -v loss="$baseline_loss" 'BEGIN {
        factor = 1.25 + loss / 100 * 2
        if (factor > 2.5) factor = 2.5
        value = int(g * factor + 0.5)
        if (value <= g) value = int(g) + 2
        if (value > 100000) value = 100000
        print value
    }')
    ui_warn "不限速测试出现明显重传，按实测送达量在 ${low}-${high} Mbit 内查找干净上限"
    ui_info "等待 ${SHAPER_PRE_SCAN_GAP} 秒，让上一轮不限速测试的令牌桶与重传状态恢复"
    sleep "$SHAPER_PRE_SCAN_GAP"

    test_shaper_rate_is_clean "$iface" "$low" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration" 1
    test_rc=$?
    if [ "$test_rc" -eq 1 ]; then
        # 自动区间首档连续浅丢包时向下测控制点。低档干净说明首档就是丢包
        # 上界；只有多档损失稳定、均不超过 0.5% 且差值不超过 0.1 个百分点，
        # 才把它确认为路径底噪。
        known_broke="$low"
        known_loss="$SHAPER_TEST_LOSS"
        control_attempts=0
        while [ "$control_attempts" -lt 3 ]; do
            control_attempts=$((control_attempts + 1))
            control_rate=$((known_broke * 3 / 4))
            [ "$control_rate" -lt 1 ] && control_rate=1
            [ "$control_rate" -lt "$known_broke" ] || break
            ui_info "首档持续浅丢包，向下测试 ${control_rate} Mbit 控制点（${control_attempts}/3）"
            SHAPER_BASE_LOSS=""
            test_shaper_rate_is_clean "$iface" "$control_rate" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration" 1
            lower_rc=$?
            control_loss="$SHAPER_TEST_LOSS"
            if [ "$lower_rc" -eq 0 ]; then
                low="$control_rate"
                high="$known_broke"
                high_confirmed=1
                break
            fi
            if [ "$lower_rc" -eq 1 ] && \
               awk -v a="$control_loss" -v b="$known_loss" 'BEGIN {
                   d=a-b; if(d<0)d=-d
                   exit !(a<=0.5 && b<=0.5 && d<=0.1)
               }'; then
                SHAPER_BASE_LOSS=$(awk -v a="$control_loss" -v b="$known_loss" 'BEGIN {print (a<b?a:b)}')
                low="$control_rate"
                ui_info "确认约 ${SHAPER_BASE_LOSS}% 的稳定路径底噪，继续向上定位拐点"
                break
            fi
            if [ "$lower_rc" -eq 2 ]; then
                break
            fi
            [ "$lower_rc" -eq 1 ] || break
            known_broke="$control_rate"
            known_loss="$control_loss"
        done
        if [ -z "$SHAPER_BASE_LOSS" ] && [ "$high_confirmed" -ne 1 ]; then
            [ "$lower_rc" -ne 2 ] || report_shaper_test_error
            if ! finish_shaper_test_restore; then return 1; fi
            ui_warn "向下三档仍未找到干净控制点，也无法证明是稳定底噪；未应用整形"
            return 0
        fi
    elif [ "$test_rc" -eq 2 ]; then
        report_shaper_test_error
        if ! finish_shaper_test_restore; then return 1; fi
        ui_warn "低速测试无法完成，未应用整形"
        return 0
    fi

    if [ "$high_confirmed" -ne 1 ]; then
        test_shaper_rate_is_clean "$iface" "$high" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration"
        test_rc=$?
        if [ "$test_rc" -eq 0 ]; then
            if ! finish_shaper_test_restore; then return 1; fi
            ui_info "扫描上界仍然干净，未确认端口限速拐点；不应用整形"
            return 0
        elif [ "$test_rc" -eq 2 ]; then
            report_shaper_test_error
            if ! finish_shaper_test_restore; then return 1; fi
            ui_warn "扫描测试失败，未应用整形"
            return 0
        fi
    fi

    search_precision=$(calculate_shaper_margin "$low")
    if [ "$low" -le 100 ]; then
        search_precision=1
    elif [ "$search_precision" -lt 2 ]; then
        search_precision=2
    fi
    ui_info "开始细化拐点：最多 ${max_search_rounds} 轮，目标精度约 ${search_precision} Mbit"
    while [ $((high - low)) -gt "$search_precision" ] && [ "$search_round" -lt "$max_search_rounds" ]; do
        search_round=$((search_round + 1))
        mid=$(( (low + high) / 2 ))
        [ "$mid" -gt "$low" ] && [ "$mid" -lt "$high" ] || break
        ui_info "细化 ${search_round}/${max_search_rounds}：当前干净 ${low} / 丢包 ${high} Mbit，测试 ${mid} Mbit"
        test_shaper_rate_is_clean "$iface" "$mid" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration"
        test_rc=$?
        if [ "$test_rc" -eq 0 ]; then
            low="$mid"
        elif [ "$test_rc" -eq 1 ]; then
            high="$mid"
        else
            report_shaper_test_error
            if ! finish_shaper_test_restore; then return 1; fi
            ui_warn "细化测试失败，未应用整形"
            return 0
        fi
    done
    if [ "$search_round" -ge "$max_search_rounds" ] && [ $((high - low)) -gt "$search_precision" ]; then
        ui_info "已达到最大细化轮数，按当前已确认的干净上限继续"
    fi

    knee="$low"
    if ! write_policer_state present "$baseline_loss" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" \
        "$baseline_goodput" "$baseline_delivery"; then
        if ! finish_shaper_test_restore; then return 1; fi
        ui_warn "已确认 policer 拐点但无法保存证据，未应用整形"
        return 1
    fi
    margin=$(calculate_shaper_margin "$knee")
    recommended=$((knee - margin))
    [ "$recommended" -gt 0 ] || recommended="$knee"
    restore_transient_qdisc || {
        ui_warn "测试后未能恢复原 ${original_kind} 队列，状态已保留供 restore 处理"
        return 1
    }
    ui_success "检测到可用上限约 ${knee} Mbit，初步建议整形为 ${recommended} Mbit"
    if ! confirm_yn "是否验证并应用 HTB + FQ 出口整形？" "n" "n"; then
        rm -f -- "$SHAPER_STATE"
        ui_info "已保留原 ${original_kind} 队列，不应用出口限速"
        return 0
    fi
    TRANSIENT_QDISC_IFACE="$iface"
    TRANSIENT_QDISC_BASELINE_KIND="$original_kind"
    TRANSIENT_QDISC_OWNED=0
    ui_info "等待 ${SHAPER_PRE_SCAN_GAP} 秒，让扫描阶段的令牌桶与重传状态恢复后再验证"
    sleep "$SHAPER_PRE_SCAN_GAP"
    while [ "$adjustment" -le "$max_adjustments" ]; do
        verify_recommended_shaper_rate "$iface" "$recommended" "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" "$duration"
        verify_rc=$?
        if [ "$verify_rc" -eq 0 ]; then
            verified=1
            break
        fi
        if [ "$verify_rc" -eq 2 ]; then
            report_shaper_test_error
            if ! finish_shaper_test_restore; then return 1; fi
            ui_warn "推荐值验证失败，未应用出口整形"
            return 0
        fi
        if [ "$adjustment" -ge "$max_adjustments" ] || [ "$recommended" -le "$margin" ]; then
            break
        fi
        adjustment=$((adjustment + 1))
        recommended=$((recommended - margin))
        ui_warn "当前推荐值重传仍高于线路本底阈值，自动降至 ${recommended} Mbit 后重新验证"
        sleep "$SHAPER_TEST_GAP"
    done
    if [ "$verified" -ne 1 ]; then
        if ! finish_shaper_test_restore; then return 1; fi
        ui_warn "连续降档后仍未找到稳定整形值，已恢复原 ${original_kind} 队列"
        return 0
    fi
    if ! managed_shaper_is_active_structure "$iface"; then
        if ! finish_shaper_test_restore; then return 1; fi
        ui_warn "推荐值验证后的出口整形结构异常，已恢复原 ${original_kind} 队列"
        return 1
    fi
    ui_success "推荐值 ${recommended} Mbit 已连续两次通过线路本底验证"
    margin=$((knee - recommended))
    limits=$(calculate_fq_limits "$recommended")
    read -r fq_limit fq_flow_limit <<< "$limits"
    if ! write_shaper_state active "$iface" "$family" "$original_kind" "$recommended" "$knee" "$margin" \
        "$PUBLIC_IPERF_HOST" "$PUBLIC_IPERF_PORT" policer "$fq_limit" "$fq_flow_limit" policer; then
        if ! finish_shaper_test_restore; then return 1; fi
        ui_warn "无法保存出口整形状态，已恢复原 ${original_kind} 队列"
        return 1
    fi
    TRANSIENT_QDISC_IFACE=""
    TRANSIENT_QDISC_BASELINE_KIND=""
    TRANSIENT_QDISC_OWNED=0
    ui_success "出口整形已应用（policer≈1ms，FQ ${fq_limit}/${fq_flow_limit}），重启与 restore 将按所有权状态处理"
    return 0
}

managed_shaper_is_active_structure() {
    local iface="$1" root_kind class_output

    root_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    [ "$root_kind" = "htb" ] || return 1
    class_output=$(tc class show dev "$iface" 2>/dev/null)
    awk '$0 ~ /(^|[[:space:]])1:10([[:space:]]|$)/ {found=1} END {exit !found}' <<< "$class_output" || return 1
    tc qdisc show dev "$iface" 2>/dev/null | awk '$2 == "fq" && $0 ~ /parent 1:10/ {found=1} END {exit !found}'
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

    # 同一菜单进程内重复应用时，不能沿用上一次出口测试选中的公共节点。
    PUBLIC_IPERF_HOST=""
    PUBLIC_IPERF_PORT=""
    PUBLIC_IPERF_RTT_MS=""
    PUBLIC_IPERF_LABEL=""
    ORIGIN_RTT_SOURCE=""
    ORIGIN_RTT_MIN=""
    ORIGIN_RTT_MEDIAN=""
    ORIGIN_RTT_AVG=""
    ORIGIN_RTT_P95=""
    ORIGIN_RTT_MAX=""
    ORIGIN_RTT_COUNT=0
    ORIGIN_RTT_TARGETS=""
    INIT_WINDOW_OVERRIDE=""

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
    local target_rtt_ms
    local relay_rtt_ms
    local origin_rtt_ms
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
    prepare_target_rtt "$region" "$profile" || return 1
    target_rtt_ms="$TARGET_RTT_RESULT"
    relay_rtt_ms="$target_rtt_ms"
    origin_rtt_ms="$target_rtt_ms"
    rtt_source="$TARGET_RTT_SOURCE"
    if [ "$profile" = "landing" ]; then
        prepare_origin_rtt "$target_rtt_ms" || return 1
        origin_rtt_ms="$ORIGIN_RTT_RESULT"
    fi
    rmem_buffer_mb=$(calculate_profile_buffer_size "$detected_bandwidth" "$origin_rtt_ms" "$profile" "$memory_mb")
    wmem_buffer_mb=$(calculate_profile_buffer_size "$detected_bandwidth" "$relay_rtt_ms" "$profile" "$memory_mb")
    rmem_buffer_bytes=$((rmem_buffer_mb * 1024 * 1024))
    wmem_buffer_bytes=$((wmem_buffer_mb * 1024 * 1024))
    buffer_mb="$rmem_buffer_mb"
    [ "$wmem_buffer_mb" -gt "$buffer_mb" ] && buffer_mb="$wmem_buffer_mb"
    buffer_defaults=$(select_tcp_buffer_defaults "$profile" "$detected_bandwidth" "$memory_mb" "$rmem_buffer_bytes" "$wmem_buffer_bytes")
    read -r tcp_rmem_min tcp_rmem_default tcp_wmem_min tcp_wmem_default <<< "$buffer_defaults"
    prepare_initial_window_for_bandwidth "$detected_bandwidth" || return 1
    select_initial_window_policy "$profile" "$detected_bandwidth"
    initcwnd=$(calculate_initial_cwnd)
    initrwnd=$(calculate_initial_rwnd "$initcwnd")
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
# RTT send/receive: ${relay_rtt_ms}/${origin_rtt_ms} ms | Source: ${rtt_source}/${ORIGIN_RTT_SOURCE:-same-direction}
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
       ! printf 'profile=%s\nprofile_name=%s\nregion=%s\nregion_name=%s\ncongestion_control=%s\nbandwidth_mbps=%s\nrtt_ms=%s\nrtt_source=%s\nrtt_min=%s\nrtt_median=%s\nrtt_avg=%s\nrtt_p95=%s\nrtt_max=%s\nrtt_count=%s\nrtt_targets=%s\nrelay_rtt_ms=%s\norigin_rtt_ms=%s\norigin_rtt_source=%s\norigin_rtt_min=%s\norigin_rtt_median=%s\norigin_rtt_avg=%s\norigin_rtt_p95=%s\norigin_rtt_max=%s\norigin_rtt_count=%s\norigin_rtt_targets=%s\npublic_peer=%s\npublic_peer_port=%s\nmemory_mb=%s\ncpu_count=%s\nbuffer_mb=%s\nrmem_buffer_mb=%s\nwmem_buffer_mb=%s\ntcp_rmem=%s %s %s\ntcp_wmem=%s %s %s\nsomaxconn=%s\ntcp_max_syn_backlog=%s\nnetdev_max_backlog=%s\nsoftnet_delta_dropped=%s\nsoftnet_delta_time_squeeze=%s\ninitcwnd=%s\ninitrwnd=%s\nmss_clamp=%s\n' \
        "$profile" "$profile_name" "$region" "$region_name" "$congestion_control" "$detected_bandwidth" "$target_rtt_ms" \
        "$rtt_source" "$RTT_SAMPLE_MIN" "$RTT_SAMPLE_MEDIAN" "$RTT_SAMPLE_AVG" "$RTT_SAMPLE_P95" "$RTT_SAMPLE_MAX" "$RTT_SAMPLE_COUNT" "$RTT_TARGETS_USED" \
        "$relay_rtt_ms" "$origin_rtt_ms" "${ORIGIN_RTT_SOURCE:-same-direction}" "${ORIGIN_RTT_MIN:-$RTT_SAMPLE_MIN}" \
        "${ORIGIN_RTT_MEDIAN:-$RTT_SAMPLE_MEDIAN}" "${ORIGIN_RTT_AVG:-$RTT_SAMPLE_AVG}" "${ORIGIN_RTT_P95:-$RTT_SAMPLE_P95}" \
        "${ORIGIN_RTT_MAX:-$RTT_SAMPLE_MAX}" "${ORIGIN_RTT_COUNT:-$RTT_SAMPLE_COUNT}" "${ORIGIN_RTT_TARGETS:-$RTT_TARGETS_USED}" \
        "$PUBLIC_IPERF_HOST" "${PUBLIC_IPERF_PORT:-0}" "$memory_mb" "$cpu_count" "$buffer_mb" "$rmem_buffer_mb" "$wmem_buffer_mb" \
        "$tcp_rmem_min" "$tcp_rmem_default" "$rmem_buffer_bytes" "$tcp_wmem_min" "$tcp_wmem_default" "$wmem_buffer_bytes" "$somaxconn" "$syn_backlog" \
        "$netdev_backlog" "${SOFTNET_DELTA_DROPPED:-0}" "${SOFTNET_DELTA_SQUEEZE:-0}" "$initcwnd" "$initrwnd" "$mss_clamp_enabled" > "$profile_state_tmp" || \
       ! finalize_managed_temp_file "$profile_state_tmp" "$PROFILE_STATE" 600; then
        ui_error "无法保存调优状态"
        return 1
    fi

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
    local shaper_apply_failed=0
    if ! recover_incomplete_shaper_state; then
        ui_error "旧出口整形状态无法安全恢复，已停止继续应用"
        return 1
    fi
    if ! apply_tc_fq_now; then
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
    SHAPER_MEMORY_MB="$memory_mb"
    SHAPER_RTT_MS="$relay_rtt_ms"
    if [ "$qdisc_apply_failed" -eq 0 ] && ! maybe_configure_egress_shaper "$detected_bandwidth"; then
        shaper_apply_failed=1
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
SHAPER_STATE="/var/lib/bbr-direct-tune/shaper.state"
MSS_CLAMP_ENABLED=0
INITCWND=0
INITRWND=0
BUFFER_MB=0
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
                [[ "$value" =~ ^[0-9]+([KMGTPkmgpt]?[bB]?)?$ ]] || return 1
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
fq_spec_is_valid() {
    local spec="$1" parsed
    [ -n "$spec" ] && [[ "$spec" != *'|'* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
    if [ "$spec" = default ]; then parsed=$(fq_record_from_output "qdisc fq 0: root") || return 1
    else parsed=$(fq_record_from_output "qdisc fq 0: root $spec") || return 1; fi
    [ "$parsed" = "$spec" ]
}
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
mq_state_leaf_spec() { mq_state_value "$1" 4; }
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
install_htb_root() {
    local iface="$1" current
    current=$(qdisc_root_kind "$iface")
    case "$current" in
        mq)
            qdisc_remove_root "$iface" || return 1
            tc qdisc add dev "$iface" root handle 1: htb default 10 >/dev/null 2>&1
            ;;
        htb)
            shaper_root_recognizable "$iface" || return 1
            tc qdisc del dev "$iface" root >/dev/null 2>&1 || return 1
            tc qdisc add dev "$iface" root handle 1: htb default 10 >/dev/null 2>&1
            ;;
        *)
            tc qdisc replace dev "$iface" root handle 1: htb default 10 >/dev/null 2>&1
            ;;
    esac
}
qdisc_set_mq_leaves() {
    local iface="$1" kind="$2" spec="${3:-default}" output handle major parents parent options=()
    case "$kind" in
        fq) fq_spec_is_valid "$spec" || return 1; [ "$spec" = default ] || read -r -a options <<< "$spec" ;;
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
    local iface="$1" current
    current=$(qdisc_root_kind "$iface")
    case "$current" in
        mq) qdisc_set_mq_leaves "$iface" fq default ;;
        fq) return 0 ;;
        ''|noqueue) tc qdisc add dev "$iface" root fq >/dev/null 2>&1 ;;
        *) qdisc_remove_root "$iface" || return 1
           current=$(qdisc_root_kind "$iface")
           case "$current" in mq) qdisc_set_mq_leaves "$iface" fq default ;; fq) return 0 ;; *) tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 ;; esac ;;
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
restore_shaper_baseline() {
    case "$2" in
        mq) qdisc_restore_mq "$1" ;;
        fq_codel) restore_fq_codel_root "$1" ;;
        none|pfifo_fast) qdisc_set_fq "$1" ;;
        *) return 1 ;;
    esac
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
shaper_root_recognizable() {
    local iface="$1" root_output

    root_output=$(tc qdisc show dev "$iface" root 2>/dev/null)
    awk '$1 == "qdisc" && $2 == "htb" && $3 == "1:" && $0 ~ / root / &&
         ($0 ~ / default 10([[:space:]]|$)/ || $0 ~ / default 0x10([[:space:]]|$)/) {found=1}
         END {exit !found}' <<< "$root_output"
}
shaper_structure_matches() {
    local iface="$1" expected="$2" expected_limit="$3" expected_flow="$4" root_output class_output leaf_output actual

    root_output=$(tc qdisc show dev "$iface" root 2>/dev/null)
    class_output=$(tc class show dev "$iface" 2>/dev/null)
    leaf_output=$(LC_ALL=C tc -d qdisc show dev "$iface" 2>/dev/null)
    awk 'NR == 1 && $2 == "htb" {found=1} END {exit !found}' <<< "$root_output" || return 1
    awk '$0 ~ /(^|[[:space:]])1:10([[:space:]]|$)/ {found=1} END {exit !found}' <<< "$class_output" || return 1
    awk -v expected_limit="$expected_limit" -v expected_flow="$expected_flow" '
        $2 == "fq" && $0 ~ /parent 1:10/ {
            limit=""; flow=""
            for (i=1; i<NF; i++) {
                if ($i == "limit") {limit=$(i+1); gsub(/p$/, "", limit)}
                else if ($i == "flow_limit") {flow=$(i+1); gsub(/p$/, "", flow)}
            }
            if (limit == expected_limit && flow == expected_flow) found=1
        }
        END {exit !found}
    ' <<< "$leaf_output" || return 1
    actual=$(tc_rate_mbit "$class_output")
    [[ "$actual" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v actual="$actual" -v expected="$expected" 'BEGIN {
        difference = actual - expected; if (difference < 0) difference = -difference
        tolerance = expected * 0.01; if (tolerance < 1) tolerance = 1
        exit !(difference <= tolerance)
    }'
}
calculate_shaper_burst_kb() {
    local rate="$1" mode="${2:-policer}" burst_kb
    if [ "$mode" = throughput ]; then
        burst_kb=$(((rate * 1250 + 1023) / 1024))
        [ "$burst_kb" -lt 64 ] && burst_kb=64
        [ "$burst_kb" -gt 4096 ] && burst_kb=4096
    else
        burst_kb=$(((rate * 125 + 1023) / 1024))
        [ "$burst_kb" -lt 32 ] && burst_kb=32
        [ "$burst_kb" -gt 256 ] && burst_kb=256
    fi
    printf '%s\n' "$burst_kb"
}
apply_managed_shaper() {
    local iface="$1" rate="$2" baseline="$3" burst_mode="$4" fq_limit="$5" fq_flow_limit="$6"
    local root_kind burst_kb
    burst_kb=$(calculate_shaper_burst_kb "$rate" "$burst_mode")
    root_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
    case "$baseline:$root_kind" in
        mq:mq) mq_current_matches_snapshot "$iface" || return 1 ;;
        mq:fq|mq:fq_codel) qdisc_restore_mq "$iface" || return 1 ;;
        fq_codel:fq_codel) fq_codel_current_matches_snapshot "$iface" || return 1 ;;
        fq_codel:fq) restore_fq_codel_root "$iface" || return 1 ;;
        none:fq|pfifo_fast:fq) ;;
        mq:htb|fq_codel:htb|none:htb|pfifo_fast:htb) shaper_root_recognizable "$iface" || return 1 ;;
        *) return 1 ;;
    esac
    if ! install_htb_root "$iface" || \
       ! tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" \
        burst "${burst_kb}kb" cburst "${burst_kb}kb" quantum 1514 >/dev/null 2>&1 || \
       ! tc qdisc add dev "$iface" parent 1:10 handle 10: fq limit "$fq_limit" flow_limit "$fq_flow_limit" \
        maxrate "${rate}mbit" >/dev/null 2>&1 || \
       ! shaper_structure_matches "$iface" "$rate" "$fq_limit" "$fq_flow_limit"; then
        restore_shaper_baseline "$iface" "$baseline" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
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
    [ ! -s "$SHAPER_STATE" ] || modprobe sch_htb >/dev/null 2>&1 || true
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
# 应用 tc fq 到所有物理网卡；失败时让启动服务返回非零，避免误报成功。
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
        [ -n "$original_kind" ] || \
            awk -F '|' -v wanted="$dev" '$1 == wanted {found=1} END {exit !found}' "$QDISC_STATE" 2>/dev/null || continue
        QDISC_CANDIDATES=$((QDISC_CANDIDATES + 1))
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$original_kind" in
            none|''|pfifo_fast)
                case "$root_kind" in
                    fq) ;;
                    ''|pfifo_fast) tc qdisc replace dev "$dev" root fq 2>/dev/null || QDISC_FAILED=1 ;;
                    *) ;;
                esac
                ;;
            fq_codel)
                if fq_codel_state_record "$dev" >/dev/null 2>&1; then
                    case "$root_kind" in
                        fq_codel) fq_codel_current_matches_snapshot "$dev" || QDISC_FAILED=1 ;;
                        fq) restore_fq_codel_root "$dev" || QDISC_FAILED=1 ;;
                        htb|'')
                            if [ ! -s "$SHAPER_STATE" ] || \
                               [ "$(awk -F= '$1 == "iface" {print $2; exit}' "$SHAPER_STATE")" != "$dev" ]; then
                                QDISC_FAILED=1
                            fi
                            ;; # 对应事务由下方 SHAPER_STATE 继续验证或恢复
                        *) QDISC_FAILED=1 ;;
                    esac
                else
                    # 兼容旧快照：没有参数明细时只能保留未被替换的现有 fq_codel。
                    [ "$root_kind" = fq_codel ] || QDISC_FAILED=1
                fi
                ;;
            mq)
                if [ "$root_kind" = mq ]; then
                    [ "$(mq_state_leaf_kind "$dev" 2>/dev/null)" = unsupported ] || \
                        mq_current_matches_snapshot "$dev" || QDISC_FAILED=1
                elif [ ! -s "$SHAPER_STATE" ] || \
                     [ "$(awk -F= '$1 == "iface" {print $2; exit}' "$SHAPER_STATE")" != "$dev" ]; then
                    QDISC_FAILED=1
                fi
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
SHAPER_FAILED=0
if [ -s "$SHAPER_STATE" ]; then
    phase=$(awk -F= '$1 == "phase" {print $2; exit}' "$SHAPER_STATE")
    shaper_iface=$(awk -F= '$1 == "iface" {print $2; exit}' "$SHAPER_STATE")
    shaper_family=$(awk -F= '$1 == "family" {print $2; exit}' "$SHAPER_STATE")
    shaper_baseline=$(awk -F= '$1 == "baseline_kind" {print $2; exit}' "$SHAPER_STATE")
    shaper_rate=$(awk -F= '$1 == "rate_mbit" {print $2; exit}' "$SHAPER_STATE")
    shaper_burst_mode=$(awk -F= '$1 == "burst_mode" {print $2; exit}' "$SHAPER_STATE")
    shaper_fq_limit=$(awk -F= '$1 == "fq_limit" {print $2; exit}' "$SHAPER_STATE")
    shaper_fq_flow_limit=$(awk -F= '$1 == "fq_flow_limit" {print $2; exit}' "$SHAPER_STATE")
    [ -n "$shaper_burst_mode" ] || shaper_burst_mode=policer
    [ -n "$shaper_fq_limit" ] || shaper_fq_limit=40960
    [ -n "$shaper_fq_flow_limit" ] || shaper_fq_flow_limit=8192
    case "$shaper_burst_mode" in policer|throughput) ;; *) SHAPER_FAILED=1 ;; esac
    if ! shaper_fq_limit=$(normalize_uint "$shaper_fq_limit" 1024 1000000) || \
       ! shaper_fq_flow_limit=$(normalize_uint "$shaper_fq_flow_limit" 100 1000000); then
        SHAPER_FAILED=1
    fi
    case "$phase:$shaper_family:$shaper_baseline" in
        active:4:none|active:4:pfifo_fast|active:4:fq_codel|active:4:mq|testing:4:none|testing:4:pfifo_fast|testing:4:fq_codel|testing:4:mq)
            default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
            ;;
        active:6:none|active:6:pfifo_fast|active:6:fq_codel|active:6:mq|testing:6:none|testing:6:pfifo_fast|testing:6:fq_codel|testing:6:mq)
            default_iface=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
            ;;
        *) SHAPER_FAILED=1; default_iface="" ;;
    esac
    if ! [[ "$shaper_iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || [ "$default_iface" != "$shaper_iface" ]; then
        SHAPER_FAILED=1
    fi
    if [ "$shaper_baseline" = fq_codel ] && ! fq_codel_state_record "$shaper_iface" >/dev/null 2>&1; then
        SHAPER_FAILED=1
    elif [ "$shaper_baseline" = mq ]; then
        case "$(mq_state_leaf_kind "$shaper_iface" 2>/dev/null)" in
            fq|fq_codel) ;;
            *) SHAPER_FAILED=1 ;;
        esac
    fi
    if [ "$phase" = active ]; then
        if ! normalized=$(normalize_uint "$shaper_rate" 1 100000); then
            SHAPER_FAILED=1
        else
            shaper_rate="$normalized"
        fi
        if [ "$SHAPER_FAILED" -eq 0 ]; then
            root_kind=$(tc qdisc show dev "$shaper_iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
            if [ "$root_kind" = htb ] && shaper_structure_matches "$shaper_iface" "$shaper_rate" "$shaper_fq_limit" "$shaper_fq_flow_limit"; then
                :
            else
                if [ -z "$root_kind" ]; then
                    restore_shaper_baseline "$shaper_iface" "$shaper_baseline" || SHAPER_FAILED=1
                fi
                if [ "$SHAPER_FAILED" -eq 0 ] && \
                   ! apply_managed_shaper "$shaper_iface" "$shaper_rate" "$shaper_baseline" \
                    "$shaper_burst_mode" "$shaper_fq_limit" "$shaper_fq_flow_limit"; then
                    SHAPER_FAILED=1
                fi
            fi
        fi
    elif [ "$phase" = testing ] && [ "$SHAPER_FAILED" -eq 0 ]; then
        root_kind=$(tc qdisc show dev "$shaper_iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$root_kind" in
            htb)
                if shaper_root_recognizable "$shaper_iface" && restore_shaper_baseline "$shaper_iface" "$shaper_baseline"; then
                    rm -f -- "$SHAPER_STATE"
                else
                    SHAPER_FAILED=1
                fi
                ;;
            fq)
                case "$shaper_baseline" in
                    fq_codel) restore_fq_codel_root "$shaper_iface" || SHAPER_FAILED=1 ;;
                    mq) qdisc_restore_mq "$shaper_iface" || SHAPER_FAILED=1 ;;
                esac
                [ "$SHAPER_FAILED" -eq 0 ] && rm -f -- "$SHAPER_STATE"
                ;;
            fq_codel)
                if [ "$shaper_baseline" = mq ]; then
                    qdisc_restore_mq "$shaper_iface" || SHAPER_FAILED=1
                else
                    [ "$shaper_baseline" = fq_codel ] && fq_codel_current_matches_snapshot "$shaper_iface" || SHAPER_FAILED=1
                fi
                [ "$SHAPER_FAILED" -eq 0 ] && rm -f -- "$SHAPER_STATE"
                ;;
            mq)
                [ "$shaper_baseline" = mq ] && mq_current_matches_snapshot "$shaper_iface" || SHAPER_FAILED=1
                [ "$SHAPER_FAILED" -eq 0 ] && rm -f -- "$SHAPER_STATE"
                ;;
            '')
                if restore_shaper_baseline "$shaper_iface" "$shaper_baseline"; then
                    rm -f -- "$SHAPER_STATE"
                else
                    SHAPER_FAILED=1
                fi
                ;;
            *) SHAPER_FAILED=1 ;;
        esac
    fi
    if [ "$SHAPER_FAILED" -ne 0 ] && [[ "$shaper_iface" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        root_kind=$(tc qdisc show dev "$shaper_iface" root 2>/dev/null | awk 'NR == 1 {print $2}')
        if { [ "$root_kind" = htb ] && shaper_root_recognizable "$shaper_iface"; } || [ -z "$root_kind" ]; then
            restore_shaper_baseline "$shaper_iface" "$shaper_baseline" >/dev/null 2>&1 || true
        fi
    fi
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
    [ "$SHAPER_FAILED" -eq 0 ] && [ "$MSS_FAILED" -eq 0 ] || exit 1
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
       [ "$qdisc_runtime_ready" -eq 1 ] && [ "$shaper_apply_failed" -eq 0 ] && \
       [ "$route_apply_failed" -eq 0 ] && [ "$mss_apply_failed" -eq 0 ] && \
       [ "$persistence_ready" -eq 1 ]; then
        ui_success "网络调优完成并已生效"
    else
        apply_result=1
        ui_error "网络调优未完全生效，请执行 status 复核调优是否生效"
    fi
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
    local dev qdisc_kind current_kind saved_leaf_kind restored_count=0 failed_count=0

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
                if [ "$current_kind" != "mq" ] || \
                   { [ "$saved_leaf_kind" != "unsupported" ] && ! mq_current_matches_snapshot "$dev"; }; then
                    ui_warn "网卡 $dev 的 mq 结构未恢复到调优前快照"
                    failed_count=$((failed_count + 1))
                fi
                ;;
            none|''|pfifo_fast)
                if [ "$qdisc_kind" = "pfifo_fast" ] && [ "$current_kind" = "pfifo_fast" ]; then
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
                if [ "$qdisc_kind" = "none" ] || [ -z "$qdisc_kind" ]; then
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
            noqueue|pfifo|codel|sfq)
                # apply 不会替换这些队列，因此恢复阶段只核对，不修改。
                if [ "$current_kind" != "$qdisc_kind" ]; then
                    ui_warn "网卡 $dev 的原队列为 $qdisc_kind，当前已变为 ${current_kind:-未知}，未自动覆盖"
                    failed_count=$((failed_count + 1))
                fi
                ;;
            *)
                # CAKE/HTB 等自定义队列从未被 apply 改动，恢复阶段也绝不重建。
                ui_info "网卡 $dev 的自定义队列 $qdisc_kind 未被脚本改动，已保留"
                ;;
        esac
    done < "$QDISC_STATE"
    [ "$restored_count" -gt 0 ] && ui_success "已恢复 ${restored_count} 个由脚本替换的简单网卡队列"
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

show_policer_evidence() {
    local evidence raw_status timestamp loss peer port now age="未知"

    evidence=$(policer_evidence_status)
    raw_status=$(awk -F= '$1 == "status" {print $2; exit}' "$POLICER_STATE" 2>/dev/null)
    timestamp=$(awk -F= '$1 == "timestamp" {print $2; exit}' "$POLICER_STATE" 2>/dev/null)
    loss=$(awk -F= '$1 == "loss_pct" {print $2; exit}' "$POLICER_STATE" 2>/dev/null)
    peer=$(awk -F= '$1 == "peer" {sub(/^[^=]*=/, ""); print; exit}' "$POLICER_STATE" 2>/dev/null)
    port=$(awk -F= '$1 == "peer_port" {print $2; exit}' "$POLICER_STATE" 2>/dev/null)
    if [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        now=$(date +%s 2>/dev/null || echo 0)
        [ "$now" -ge "$timestamp" ] && age="$((now - timestamp)) 秒前"
    fi

    ui_card_start "线路 policer 证据"
    case "$evidence" in
        present)
            ui_kv "判定" "已确认存在（近期主动 iperf3 拐点测试）"
            ;;
        absent)
            ui_kv "判定" "近期主动测试未发现（连续两次重传估算 <0.1%）"
            ;;
        stale)
            ui_kv "判定" "未测试或证据已过期（上次 ${raw_status:-未知}）"
            ;;
        *)
            ui_kv "判定" "未测试或证据不足"
            ;;
    esac
    [ -n "$peer" ] && ui_kv "测试节点" "${peer}:${port:-未知} / ${age}"
    [ -n "$loss" ] && ui_kv "记录重传估算" "${loss}%"
    ui_card_end
    ui_info "qdisc、softnet、网卡错误和 PMTU 只能定位本机或路径异常，不能单独证明没有 policer"
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
        local profile_name saved_region saved_region_name bandwidth_mbps rtt_ms rtt_source public_peer public_peer_port memory_mb cpu_count buffer_mb
        local rtt_stats relay_rtt origin_rtt origin_source rmem_buffer_mb wmem_buffer_mb softnet_delta_dropped softnet_delta_squeeze
        profile_name=$(awk -F= '$1 == "profile_name" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
        saved_region=$(awk -F= '$1 == "region" {print $2}' "$PROFILE_STATE")
        saved_region_name=$(awk -F= '$1 == "region_name" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
        [ -z "$saved_region_name" ] && [ -n "$saved_region" ] && saved_region_name=$(region_label "$saved_region")
        bandwidth_mbps=$(awk -F= '$1 == "bandwidth_mbps" {print $2}' "$PROFILE_STATE")
        rtt_ms=$(awk -F= '$1 == "rtt_ms" {print $2}' "$PROFILE_STATE")
        rtt_source=$(awk -F= '$1 == "rtt_source" {print $2}' "$PROFILE_STATE")
        public_peer=$(awk -F= '$1 == "public_peer" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
        public_peer_port=$(awk -F= '$1 == "public_peer_port" {print $2}' "$PROFILE_STATE")
        memory_mb=$(awk -F= '$1 == "memory_mb" {print $2}' "$PROFILE_STATE")
        cpu_count=$(awk -F= '$1 == "cpu_count" {print $2}' "$PROFILE_STATE")
        buffer_mb=$(awk -F= '$1 == "buffer_mb" {print $2}' "$PROFILE_STATE")
        rtt_stats=$(awk -F= '
            $1 == "rtt_min" {min=$2} $1 == "rtt_median" {median=$2} $1 == "rtt_avg" {avg=$2}
            $1 == "rtt_p95" {p95=$2} $1 == "rtt_max" {max=$2} $1 == "rtt_count" {count=$2}
            END {if (min != "") print min "/" median "/" avg "/" p95 "/" max " ms（" count " 样本）"}
        ' "$PROFILE_STATE")
        relay_rtt=$(awk -F= '$1 == "relay_rtt_ms" {print $2}' "$PROFILE_STATE")
        origin_rtt=$(awk -F= '$1 == "origin_rtt_ms" {print $2}' "$PROFILE_STATE")
        origin_source=$(awk -F= '$1 == "origin_rtt_source" {print $2}' "$PROFILE_STATE")
        rmem_buffer_mb=$(awk -F= '$1 == "rmem_buffer_mb" {print $2}' "$PROFILE_STATE")
        wmem_buffer_mb=$(awk -F= '$1 == "wmem_buffer_mb" {print $2}' "$PROFILE_STATE")
        softnet_delta_dropped=$(awk -F= '$1 == "softnet_delta_dropped" {print $2}' "$PROFILE_STATE")
        softnet_delta_squeeze=$(awk -F= '$1 == "softnet_delta_time_squeeze" {print $2}' "$PROFILE_STATE")
        [ -n "$profile_name" ] && ui_kv "调优场景" "$profile_name"
        [ -n "$saved_region_name" ] && ui_kv "链路地区" "$saved_region_name"
        ui_kv "目标链路" "${bandwidth_mbps:-未知} Mbps / ${rtt_ms:-未知} ms（${rtt_source:-旧版配置}）"
        [ -n "$rtt_stats" ] && ui_kv "RTT min/med/avg/p95/max" "$rtt_stats"
        if [ -n "$relay_rtt" ] && [ -n "$origin_rtt" ]; then
            ui_kv "发送/回源 RTT" "${relay_rtt}/${origin_rtt} ms（回源 ${origin_source:-未知}）"
        fi
        [ -n "$public_peer" ] && ui_kv "公共测试节点" "${public_peer}:${public_peer_port:-5201}"
        if [ -n "$rmem_buffer_mb" ] && [ -n "$wmem_buffer_mb" ]; then
            ui_kv "CPU/内存/收发窗口" "${cpu_count:-未知} 核 / ${memory_mb:-未知} MB / ${rmem_buffer_mb}/${wmem_buffer_mb} MB"
        else
            ui_kv "CPU/内存/窗口" "${cpu_count:-未知} 核 / ${memory_mb:-未知} MB / ${buffer_mb:-未知} MB"
        fi
        [ -n "$softnet_delta_dropped" ] && ui_kv "应用时 softnet Δ" "丢弃 ${softnet_delta_dropped} / 挤压 ${softnet_delta_squeeze:-0}"
    fi

    if [ -s "$SHAPER_STATE" ]; then
        local shaper_phase shaper_iface shaper_rate shaper_knee shaper_mode shaper_kind shaper_fq_limit shaper_fq_flow
        shaper_phase=$(shaper_state_value phase)
        shaper_iface=$(shaper_state_value iface)
        shaper_rate=$(shaper_state_value rate_mbit)
        shaper_knee=$(shaper_state_value knee_mbit)
        shaper_mode=$(shaper_state_value burst_mode); shaper_mode=${shaper_mode:-policer}
        shaper_kind=$(shaper_state_value kind); shaper_kind=${shaper_kind:-policer}
        shaper_fq_limit=$(shaper_state_value fq_limit); shaper_fq_limit=${shaper_fq_limit:-40960}
        shaper_fq_flow=$(shaper_state_value fq_flow_limit); shaper_fq_flow=${shaper_fq_flow:-8192}
        if managed_shaper_is_active; then
            ui_kv "出口整形" "${shaper_iface} / ${shaper_rate} Mbit（${shaper_kind} / ${shaper_mode}）"
            ui_kv "整形 FQ limit/flow" "${shaper_fq_limit} / ${shaper_fq_flow}"
            [ "$shaper_knee" -gt 0 ] 2>/dev/null && ui_kv "policer 实测上限" "${shaper_knee} Mbit"
        else
            ui_kv "出口整形" "状态 ${shaper_phase:-异常}，当前未完整生效"
        fi
    else
        ui_kv "出口整形" "未启用"
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
    show_policer_evidence
}

runtime_qdisc_is_ready() {
    local dev original_kind current_kind saved_leaf_kind candidates=0

    command -v tc >/dev/null 2>&1 && [ -s "$QDISC_STATE" ] || return 1
    for dev in $(eligible_ifaces); do
        original_kind=$(awk -F '|' -v wanted="$dev" '$1 == wanted {print $2; exit}' "$QDISC_STATE")
        [ -n "$original_kind" ] || return 1
        current_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        candidates=$((candidates + 1))
        if managed_shaper_is_active "$dev"; then
            [ "$current_kind" = "htb" ] || return 1
            continue
        fi
        case "$original_kind" in
            none|pfifo_fast|fq)
                [ "$current_kind" = "fq" ] || return 1
                ;;
            fq_codel)
                if managed_shaper_is_active "$dev"; then
                    [ "$current_kind" = "htb" ] || return 1
                else
                    [ "$current_kind" = "fq_codel" ] || return 1
                    if fq_codel_state_record "$dev" >/dev/null 2>&1; then
                        fq_codel_current_matches_snapshot "$dev" || return 1
                    fi
                fi
                ;;
            mq)
                if managed_shaper_is_active "$dev"; then
                    [ "$current_kind" = "htb" ] || return 1
                else
                    [ "$current_kind" = "mq" ] || return 1
                    saved_leaf_kind=$(mq_state_leaf_kind "$dev" 2>/dev/null)
                    [ "$saved_leaf_kind" = "unsupported" ] || mq_current_matches_snapshot "$dev" || return 1
                fi
                ;;
            noqueue|pfifo|codel|sfq)
                [ "$current_kind" = "$original_kind" ] || [ "$current_kind" = "fq" ] || return 1
                ;;
            *)
                [ "$current_kind" = "$original_kind" ] || return 1
                ;;
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
        restore_managed_shaper || restore_failed=1
        restore_qdisc_snapshot || restore_failed=1
        restore_route_snapshot || restore_failed=1
        restore_rps_snapshot || restore_failed=1
        restore_thp_snapshot || restore_failed=1
    else
        ui_step 5 6 "旧版兼容恢复"
        restore_managed_shaper || restore_failed=1
        restore_qdisc_snapshot || restore_failed=1
        restore_route_snapshot || restore_failed=1
        ui_warn "旧版没有完整 sysctl 快照；其余配置已移除，重启后按系统现有默认加载"
    fi

    ui_step 6 6 "验证恢复结果"
    if [ "$restore_failed" -eq 0 ]; then
        cleanup_managed_iperf3 || restore_failed=1
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
    ui_card_line "自动选择近端公共节点进行端口 policer 检测"
    ui_card_line "仅标记冲突键，并设置开机生效"
    ui_card_line "status 显示参数、队列、policer 三态和累计计数"
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
    ui_card_line "TARGET_RTT_MS / ORIGIN_RTT_MS / RELAY_RTT_MS 可覆盖 RTT"
    ui_card_line "INIT_CWND / INIT_RWND / ENABLE_INIT_WINDOW_32 仅建议熟悉网络时使用"
    ui_card_line "RUN_POLICER_TEST=1 / EGRESS_LIMIT_MBPS 可用于非交互主动测试与总出口保护"
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
