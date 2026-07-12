#!/usr/bin/env bash
# Standalone BBR tuning for optimize, landing and website servers.
# Source: https://github.com/Eric86777/vps-tcp-tune/blob/main/net-tcp-tune.sh
# Originally extracted from upstream v5.3.0 and independently maintained.

set -o pipefail

SCRIPT_VERSION="6.1.4-standalone"
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
RPS_STATE="${STATE_DIR}/rps.state"
ROUTE_STATE="${STATE_DIR}/route.state"
THP_STATE="${STATE_DIR}/thp.state"
PROFILE_STATE="${STATE_DIR}/profile.state"
CONFLICT_STATE="${STATE_DIR}/disabled-sysctl-files.map"
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
MSS_RULE_COMMENT="bbr-direct-tune"
AUTO_MODE="${AUTO_MODE:-0}"
UI_BOX_WIDTH=62

SPEEDTEST_TMP_MARKER="/tmp/bbr-direct-tune-speedtest-dir.$$"
SPEEDTEST_CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/ookla/speedtest-cli.json"
SPEEDTEST_CONFIG_EXISTED=0
SPEEDTEST_BIN=""
[ -e "$SPEEDTEST_CONFIG_FILE" ] && SPEEDTEST_CONFIG_EXISTED=1

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    gl_hong=$'\033[38;5;174m'
    gl_lv=$'\033[38;5;108m'
    gl_huang=$'\033[38;5;180m'
    gl_bai=$'\033[0m'
    gl_kjlan=$'\033[38;5;110m'
    gl_zi=$'\033[38;5;139m'
    gl_hui=$'\033[38;5;245m'
else
    gl_hong=''
    gl_lv=''
    gl_huang=''
    gl_bai=''
    gl_kjlan=''
    gl_zi=''
    gl_hui=''
fi

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
    net.ipv4.tcp_notsent_lowat
    net.ipv4.tcp_fin_timeout
    net.ipv4.tcp_fastopen
    net.ipv4.udp_rmem_min
    net.ipv4.udp_wmem_min
    net.ipv4.tcp_syncookies
)

ui_text_width() {
    local text="$1"
    local byte width=0

    for byte in $(printf '%s' "$text" | od -An -tu1); do
        if [ "$byte" -lt 128 ]; then
            width=$((width + 1))
        elif [ "$byte" -ge 194 ] && [ "$byte" -le 244 ]; then
            width=$((width + 2))
        fi
    done
    printf '%s\n' "$width"
}

ui_box_rule() {
    local left="$1"
    local right="$2"
    local rule

    printf -v rule '%*s' "$UI_BOX_WIDTH" ''
    rule=${rule// /─}
    printf '%b%s%s%s%b\n' "$gl_hui" "$left" "$rule" "$right" "$gl_bai"
}

ui_box_line() {
    local plain_text="$1"
    local rendered_text="${2:-$1}"
    local text_width padding

    text_width=$(ui_text_width "$plain_text")
    padding=$((UI_BOX_WIDTH - text_width))
    [ "$padding" -lt 0 ] && padding=0
    printf '%b│%b%s%*s%b│%b\n' "$gl_hui" "$gl_bai" "$rendered_text" "$padding" '' "$gl_hui" "$gl_bai"
}

ui_banner() {
    ui_box_rule "╭" "╮"
    ui_box_line "  BBR DIRECT TUNE  网络调优" \
        "  ${gl_kjlan}BBR DIRECT TUNE${gl_bai}  ${gl_zi}网络调优${gl_bai}"
    ui_box_line "  适用于优化机 / 落地机 / 建站机等场景" \
        "  ${gl_zi}适用于优化机 / 落地机 / 建站机等场景${gl_bai}"
    ui_box_rule "╰" "╯"
}

ui_section() {
    printf '\n%b%s%b\n' "${gl_hui}─── " "${gl_kjlan}$1" " ${gl_hui}────────────────────────────────────────${gl_bai}"
}

ui_step() {
    printf '%b[%s/%s]%b %s\n' "$gl_zi" "$1" "$2" "$gl_bai" "$3"
}

ui_success() {
    printf '%b✓%b %s\n' "$gl_lv" "$gl_bai" "$1"
}

ui_warn() {
    printf '%b!%b %s\n' "$gl_huang" "$gl_bai" "$1"
}

ui_error() {
    printf '%b×%b %s\n' "$gl_hong" "$gl_bai" "$1"
}

ui_info() {
    printf '%b›%b %s\n' "$gl_kjlan" "$gl_bai" "$1"
}

confirm_yn() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local auto_answer="${3:-$default_answer}"
    local answer=""
    local suffix="[y/n，默认 n]"

    [ "$default_answer" = "y" ] && suffix="[y/n，默认 y]"
    if [ "$AUTO_MODE" = "1" ]; then
        [ "$auto_answer" = "y" ]
        return
    fi

    while true; do
        if ! read -r -p "$(printf '%b%s %s:%b ' "$gl_huang" "$prompt" "$suffix" "$gl_bai")" answer; then
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

cleanup_runtime_artifacts() {
    local temp_dir=""
    local managed_speedtest=0

    if [ -f "$SPEEDTEST_TMP_MARKER" ]; then
        managed_speedtest=1
        temp_dir=$(cat "$SPEEDTEST_TMP_MARKER" 2>/dev/null)
        case "$temp_dir" in
            /tmp/bbr-speedtest.*) rm -rf -- "$temp_dir" 2>/dev/null || true ;;
        esac
        rm -f "$SPEEDTEST_TMP_MARKER" 2>/dev/null || true
    fi

    if [ "$managed_speedtest" -eq 1 ] && [ "$SPEEDTEST_CONFIG_EXISTED" -eq 0 ]; then
        rm -f "$SPEEDTEST_CONFIG_FILE" 2>/dev/null || true
        rmdir "$(dirname "$SPEEDTEST_CONFIG_FILE")" 2>/dev/null || true
    fi
}

cleanup_speedtest_after_tuning() {
    local installed_by_script=0
    [ -f "$SPEEDTEST_TMP_MARKER" ] && installed_by_script=1
    cleanup_runtime_artifacts
    [ "$installed_by_script" -eq 1 ] && ui_info "测速完成，已清理脚本临时安装的 speedtest 与本次新增残留"
}

trap cleanup_runtime_artifacts EXIT

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

clean_sysctl_conf() {
    # 备份主配置文件
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi

    # 使用专属标记注释，恢复时只还原本脚本处理的行，不覆盖用户后续修改。
    sed -i '/^[[:space:]]*net\.core\.rmem_max[[:space:]]*=/s/^/# bbr-direct-tune disabled: /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^[[:space:]]*net\.core\.wmem_max[[:space:]]*=/s/^/# bbr-direct-tune disabled: /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_rmem[[:space:]]*=/s/^/# bbr-direct-tune disabled: /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_wmem[[:space:]]*=/s/^/# bbr-direct-tune disabled: /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/s/^/# bbr-direct-tune disabled: /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/s/^/# bbr-direct-tune disabled: /' /etc/sysctl.conf 2>/dev/null
}

snapshot_initial_state() {
    local key value dev qdisc_kind current_route initcwnd initrwnd

    [ -f "$SNAPSHOT_READY" ] && return 0
    if ! mkdir -p "$STATE_DIR" || ! chmod 700 "$STATE_DIR"; then
        ui_error "无法创建恢复快照目录 $STATE_DIR"
        return 1
    fi
    if ! snapshot_openrc_local_state; then
        ui_error "无法保存 OpenRC local 服务原始注册状态"
        return 1
    fi

    : > "$CONFLICT_STATE"
    if [ -f "$SYSCTL_CONF" ] || [ -f "$PERSIST_SCRIPT" ] || [ -f "$SYSTEMD_SERVICE" ]; then
        printf '%s\n' "legacy" > "$SNAPSHOT_MODE"
        touch "$SNAPSHOT_READY"
        chmod 600 "$SNAPSHOT_MODE" "$SNAPSHOT_READY" "$CONFLICT_STATE" 2>/dev/null || true
        ui_warn "检测到旧版调优痕迹：没有执行前快照，恢复时将采用安全兼容模式"
        return 0
    fi

    printf '%s\n' "fresh" > "$SNAPSHOT_MODE"
    : > "$SYSCTL_STATE"
    for key in "${TUNED_SYSCTL_KEYS[@]}"; do
        value=$(sysctl -n "$key" 2>/dev/null) || continue
        printf '%s=%s\n' "$key" "$value" >> "$SYSCTL_STATE"
    done

    : > "$QDISC_STATE"
    if command -v tc >/dev/null 2>&1; then
        for dev in $(eligible_ifaces); do
            qdisc_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR==1 {print $2}')
            printf '%s|%s\n' "$dev" "${qdisc_kind:-none}" >> "$QDISC_STATE"
        done
    fi

    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    printf 'initcwnd=%s\ninitrwnd=%s\n' "$initcwnd" "$initrwnd" > "$ROUTE_STATE"

    if [ -f /etc/sysctl.conf ]; then
        cp -p /etc/sysctl.conf "$STATE_DIR/sysctl.conf.before" 2>/dev/null || true
    else
        touch "$STATE_DIR/sysctl.conf.absent"
    fi

    chmod 600 "$STATE_DIR"/* 2>/dev/null || true
    touch "$SNAPSHOT_READY"
    chmod 600 "$SNAPSHOT_READY" 2>/dev/null || true
    ui_success "已保存调优前状态，可从主菜单安全恢复"
}

cleanup_legacy_runtime_before_apply() {
    local snapshot_mode="legacy"
    local key setting restored_count=0
    local legacy_keys=(
        net.ipv4.tcp_keepalive_time
        net.ipv4.tcp_keepalive_intvl
        net.ipv4.tcp_keepalive_probes
        net.ipv4.tcp_tw_reuse
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
            fi
        done
        [ -s "$RPS_STATE" ] && restore_rps_snapshot >/dev/null 2>&1 || true
        [ -s "$THP_STATE" ] && restore_thp_snapshot >/dev/null 2>&1 || true
        [ "$restored_count" -gt 0 ] && ui_success "已从快照恢复 ${restored_count} 项旧版非网络运行参数"
    elif { [ -s "$SYSCTL_CONF" ] || [ -s "$PERSIST_SCRIPT" ]; } && \
         grep -qE '(vm\.|kernel\.numa_balancing|kernel\.sched_autogroup_enabled|tcp_keepalive|tcp_tw_reuse|transparent_hugepage|rps_cpus|rps_flow_cnt)' \
             "$SYSCTL_CONF" "$PERSIST_SCRIPT" 2>/dev/null; then
        ui_warn "检测到旧版额外 TCP/VM/THP/RPS 调优，但没有精确快照；本次不猜测原值"
        ui_info "新配置会停止持久化这些参数，建议应用后安排一次维护重启清除旧运行态"
    fi

    if [ -f /etc/security/limits.conf ] && grep -q "^# BBR - 文件描述符优化$" /etc/security/limits.conf 2>/dev/null; then
        cp -p /etc/security/limits.conf "/etc/security/limits.conf.bak.bbr-upgrade.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        sed -i '/^# BBR - 文件描述符优化$/,+2d' /etc/security/limits.conf 2>/dev/null || true
        ui_success "已移除旧版脚本写入的全局文件描述符块"
    fi
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

snapshot_openrc_local_state() {
    local enabled=0

    [ -f "$OPENRC_LOCAL_STATE" ] && return 0
    openrc_local_is_enabled && enabled=1
    printf '%s\n' "$enabled" > "$OPENRC_LOCAL_STATE" || return 1
    chmod 600 "$OPENRC_LOCAL_STATE" 2>/dev/null || true
}

restore_openrc_local_state() {
    local original_state="" current_state=0

    if [ -s "$OPENRC_LOCAL_STATE" ]; then
        original_state=$(head -n 1 "$OPENRC_LOCAL_STATE" 2>/dev/null || true)
    elif [ -s "$SWAP_STATE" ]; then
        original_state=$(awk -F= '$1 == "openrc_local_default" {print $2}' "$SWAP_STATE")
    fi
    case "$original_state" in
        0|1) ;;
        *) return 0 ;;
    esac

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
    if ! printf 'status=%s\nmanaged_uuid=%s\nmanaged_header_bytes=%s\n' \
        "$status" "$managed_uuid" "$managed_header_bytes" > "$state_tmp" || \
       ! chmod 600 "$state_tmp" || ! mv -f "$state_tmp" "$SWAP_MANAGED_STATE"; then
        rm -f -- "$state_tmp"
        return 1
    fi
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
    local existed=0 active=0 size_bytes=0 mode="" uid="" gid="" priority="" swap_type="" swap_uuid="" swap_label="" header_bytes=0
    local managed_status managed_uuid managed_header_bytes current_uuid current_type openrc_local_default=0

    if [ -f "$SWAP_SNAPSHOT_READY" ]; then
        if [ ! -s "$SWAP_MANAGED_STATE" ]; then
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
            ui_error "$SWAP_FILE 已不再是本脚本管理的 Swap，已拒绝覆盖"
            return 1
        fi
        return 0
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
        : > "$SWAP_HEADER_STATE"
    fi

    if swapfile_is_active; then
        active=1
        priority=$(swapfile_priority)
    fi

    if [ -f "$FSTAB_FILE" ]; then
        rm -f -- "$SWAP_FSTAB_STATE.absent"
        cp -p "$FSTAB_FILE" "$SWAP_FSTAB_STATE" || {
            ui_error "无法保存 $FSTAB_FILE，已停止调整"
            return 1
        }
    else
        rm -f -- "$SWAP_FSTAB_STATE"
        : > "${SWAP_FSTAB_STATE}.absent"
    fi

    if [ -e "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; then
        if [ ! -f "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; then
            ui_error "$ALPINE_SWAP_START 不是普通文件，已停止调整"
            return 1
        fi
        rm -f -- "$SWAP_ALPINE_START_STATE.absent"
        cp -p "$ALPINE_SWAP_START" "$SWAP_ALPINE_START_STATE" || {
            ui_error "无法保存 $ALPINE_SWAP_START，已停止调整"
            return 1
        }
    else
        rm -f -- "$SWAP_ALPINE_START_STATE"
        : > "${SWAP_ALPINE_START_STATE}.absent"
    fi

    openrc_local_is_enabled && openrc_local_default=1
    printf 'existed=%s\nactive=%s\nsize_bytes=%s\nmode=%s\nuid=%s\ngid=%s\npriority=%s\nuuid=%s\nlabel=%s\nheader_bytes=%s\nopenrc_local_default=%s\n' \
        "$existed" "$active" "$size_bytes" "$mode" "$uid" "$gid" "$priority" "$swap_uuid" "$swap_label" "$header_bytes" \
        "$openrc_local_default" > "$SWAP_STATE" || return 1
    chmod 600 "$SWAP_STATE" "$SWAP_HEADER_STATE" "$SWAP_FSTAB_STATE" "$SWAP_FSTAB_STATE.absent" \
        "$SWAP_ALPINE_START_STATE" "$SWAP_ALPINE_START_STATE.absent" 2>/dev/null || true
    touch "$SWAP_SNAPSHOT_READY"
    chmod 600 "$SWAP_SNAPSHOT_READY" 2>/dev/null || true
    return 0
}

restore_swap_state() {
    local existed active size_bytes mode uid gid priority swap_uuid swap_label header_bytes
    local managed_status managed_uuid managed_header_bytes current_uuid="" current_type="" current_size="" current_priority=""
    local file_state="absent" restore_failed=0 fstab_failed=0 alpine_failed=0
    local fstab_tmp="${FSTAB_FILE}.bbr-direct-tune.tmp"

    if [ ! -f "$SWAP_MANAGED_STATE" ]; then
        if [ -f "$SWAP_SNAPSHOT_READY" ]; then
            ui_warn "Swap 管理状态缺失，无法安全判断 $SWAP_FILE 的归属；恢复快照已保留"
            return 1
        fi
        restore_openrc_local_state
        return $?
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
            ui_warn "$SWAP_FILE 已变成非普通文件，为避免误删已停止恢复"
            return 1
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
        ui_warn "$SWAP_FILE 已不再匹配脚本 Swap 或原 Swap，为避免覆盖用户修改已停止恢复"
        return 1
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

    rm -f -- "$fstab_tmp" || fstab_failed=1
    if [ "$fstab_failed" -eq 0 ] && [ ! -f "$FSTAB_FILE" ]; then
        if [ -f "$SWAP_FSTAB_STATE" ]; then
            cp -p "$SWAP_FSTAB_STATE" "$FSTAB_FILE" || fstab_failed=1
        else
            : > "$FSTAB_FILE" || fstab_failed=1
        fi
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
        ' "$FSTAB_FILE" > "$fstab_tmp" || fstab_failed=1
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
        else
            cat "$fstab_tmp" > "$FSTAB_FILE" || fstab_failed=1
            rm -f -- "$fstab_tmp" || fstab_failed=1
        fi
    fi
    unset SWAPFILE_MANAGED_UUID SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL
    if [ "$fstab_failed" -ne 0 ]; then
        rm -f -- "$fstab_tmp"
        ui_warn "未能完整恢复 $FSTAB_FILE 中的 Swap 配置"
        restore_failed=1
    fi

    if [ -f "$SWAP_ALPINE_START_STATE" ]; then
        if { [ -e "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; } && \
           { [ ! -f "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; }; then
            ui_warn "$ALPINE_SWAP_START 已变成非普通文件，为避免覆盖已保留"
            alpine_failed=1
        elif ! mkdir -p "$(dirname "$ALPINE_SWAP_START")" || \
             ! cp -p "$SWAP_ALPINE_START_STATE" "$ALPINE_SWAP_START"; then
            alpine_failed=1
        fi
    elif [ -f "$SWAP_ALPINE_START_STATE.absent" ]; then
        if { [ -e "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; } && \
           { [ ! -f "$ALPINE_SWAP_START" ] || [ -L "$ALPINE_SWAP_START" ]; }; then
            ui_warn "$ALPINE_SWAP_START 已变成非普通文件，为避免误删已保留"
            alpine_failed=1
        elif ! rm -f -- "$ALPINE_SWAP_START"; then
            alpine_failed=1
        fi
    fi
    if [ "$alpine_failed" -ne 0 ]; then
        ui_warn "未能恢复 Alpine Swap 启动文件"
        restore_failed=1
    elif ! restore_openrc_local_state; then
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
    rm -f -- "$SWAP_STATE" "$SWAP_HEADER_STATE" "$SWAP_MANAGED_HEADER_STATE" "$SWAP_FSTAB_STATE" "$SWAP_FSTAB_STATE.absent" \
        "$SWAP_ALPINE_START_STATE" "$SWAP_ALPINE_START_STATE.absent" "$SWAP_SNAPSHOT_READY" "$SWAP_MANAGED_STATE" \
        "${SWAP_MANAGED_STATE}.tmp" "${SWAP_MANAGED_HEADER_STATE}.new" "${FSTAB_FILE}.bbr-direct-tune.tmp"
}

rollback_swap_change() {
    rm -f -- "${SWAP_MANAGED_STATE}.tmp" "${SWAP_MANAGED_HEADER_STATE}.new" "${FSTAB_FILE}.bbr-direct-tune.tmp"
    if restore_swap_state; then
        cleanup_swap_snapshot_files
        ui_success "Swap 调整失败，已恢复原状态"
        return 0
    fi
    ui_error "Swap 调整失败且自动回滚未完成，已保留快照供卸载重试"
    return 1
}

add_swap() {
    local new_swap=$1
    local dev_swap_list swapfile_size previous_managed=0 previous_managed_uuid="" previous_managed_header_bytes=0
    local new_managed_uuid new_managed_header_bytes original_swap_uuid original_swap_label
    local managed_header_tmp="${SWAP_MANAGED_HEADER_STATE}.new"
    local fstab_tmp="${FSTAB_FILE}.bbr-direct-tune.tmp"

    ui_section "调整虚拟内存（仅管理 $SWAP_FILE）"

    if ! [[ "$new_swap" =~ ^[0-9]+$ ]] || [ "$new_swap" -le 0 ]; then
        ui_error "Swap 大小必须是正整数 MB"
        return 1
    fi

    dev_swap_list=$(awk 'NR>1 && $1 ~ /^\/dev\// {printf "  • %s (大小: %d MB, 已用: %d MB)\n", $1, int(($3+512)/1024), int(($4+512)/1024)}' "$PROC_SWAPS_FILE")
    if [ -n "$dev_swap_list" ]; then
        echo -e "${gl_huang}检测到以下 /dev/ 虚拟内存处于激活状态：${gl_bai}"
        echo "$dev_swap_list"
        echo ""
        echo -e "${gl_huang}提示:${gl_bai} 本脚本不会修改这些 Swap 分区。"
        echo ""
    fi

    echo -e "${gl_huang}警告:${gl_bai} 即将停用并重建 $SWAP_FILE，同时更新 $FSTAB_FILE；卸载时会恢复原状态。"
    if [ -f "$SWAP_FILE" ]; then
        swapfile_size=$(du -h "$SWAP_FILE" 2>/dev/null | awk '{print $1}')
        echo -e "当前 $SWAP_FILE 大小: ${gl_huang}${swapfile_size:-未知}${gl_bai}"
    else
        echo "当前未发现 $SWAP_FILE。"
    fi
    if grep -qF "$SWAP_FILE" "$FSTAB_FILE" 2>/dev/null; then
        echo "当前 $FSTAB_FILE 中的 $SWAP_FILE 记录："
        grep -F "$SWAP_FILE" "$FSTAB_FILE" 2>/dev/null
    fi
    echo ""

    if ! snapshot_swap_state; then
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

    echo "正在创建 ${new_swap}MB 虚拟内存..."
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

    if [ ! -f "$FSTAB_FILE" ]; then
        if ! : > "$FSTAB_FILE"; then
            rollback_swap_change
            return 1
        fi
    fi
    original_swap_uuid=$(awk -F= '$1 == "uuid" {sub(/^[^=]*=/, ""); print}' "$SWAP_STATE")
    original_swap_label=$(awk -F= '$1 == "label" {sub(/^[^=]*=/, ""); print}' "$SWAP_STATE")
    SWAPFILE_ORIGINAL_UUID="$original_swap_uuid"
    SWAPFILE_ORIGINAL_LABEL="$original_swap_label"
    SWAPFILE_PREVIOUS_UUID="$previous_managed_uuid"
    SWAPFILE_MANAGED_UUID="$new_managed_uuid"
    export SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
    rm -f -- "$fstab_tmp"
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
    ' "$FSTAB_FILE" > "$fstab_tmp" || {
        unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
        rollback_swap_change
        return 1
    }
    if ! printf '%s swap swap defaults 0 0\n' "$SWAP_FILE" >> "$fstab_tmp" || \
       ! cat "$fstab_tmp" > "$FSTAB_FILE"; then
        unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
        rm -f -- "$fstab_tmp"
        rollback_swap_change
        return 1
    fi
    unset SWAPFILE_ORIGINAL_UUID SWAPFILE_ORIGINAL_LABEL SWAPFILE_PREVIOUS_UUID SWAPFILE_MANAGED_UUID
    rm -f -- "$fstab_tmp"

    if [ -f "$ALPINE_RELEASE_FILE" ]; then
        if ! mkdir -p "$(dirname "$ALPINE_SWAP_START")" || \
           ! printf 'swapon %s\n' "$SWAP_FILE" > "$ALPINE_SWAP_START" || \
           ! chmod +x "$ALPINE_SWAP_START"; then
            rollback_swap_change
            return 1
        fi
        if ! openrc_local_is_enabled; then
            if ! command -v rc-update >/dev/null 2>&1 || \
               ! rc-update add local default >/dev/null 2>&1 || ! openrc_local_is_enabled; then
                ui_error "无法启用 OpenRC local 服务，正在回滚 Swap 调整"
                rollback_swap_change
                return 1
            fi
        fi
    fi

    echo -e "${gl_lv}虚拟内存大小已调整为 ${new_swap}MB，卸载时将恢复原状态${gl_bai}"
    return 0
}

is_ookla_speedtest() {
    local candidate="$1"

    [ -x "$candidate" ] || return 1
    "$candidate" --version 2>&1 | grep -qi "Speedtest by Ookla"
}

run_speedtest() {
    [ -n "$SPEEDTEST_BIN" ] && [ -x "$SPEEDTEST_BIN" ] || return 127
    "$SPEEDTEST_BIN" --accept-license --accept-gdpr "$@"
}

ensure_speedtest() {
    local existing_speedtest=""
    existing_speedtest=$(command -v speedtest 2>/dev/null || true)
    if [ -n "$existing_speedtest" ]; then
        if is_ookla_speedtest "$existing_speedtest"; then
            SPEEDTEST_BIN="$existing_speedtest"
            return 0
        fi
        echo -e "${gl_huang}检测到 ${existing_speedtest}，但它不是 Ookla 官方 Speedtest CLI。${gl_bai}" >&2
        echo -e "${gl_zi}脚本不会覆盖或卸载现有命令，将使用独立临时目录。${gl_bai}" >&2
    else
        echo -e "${gl_huang}speedtest 未安装。${gl_bai}" >&2
    fi

    echo -e "${gl_zi}脚本可临时下载 Ookla Speedtest CLI，测速结束后会自动清理。${gl_bai}" >&2
    if ! confirm_yn "是否临时下载 speedtest？" "n" "n"; then
        echo -e "${gl_huang}已跳过 speedtest，将使用手动或默认带宽配置。${gl_bai}" >&2
        return 1
    fi

    local cpu_arch
    local download_url
    local tmp_dir
    cpu_arch=$(uname -m)

    case "$cpu_arch" in
        x86_64)
            download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
            ;;
        aarch64)
            download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
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
    printf '%s\n' "$tmp_dir" > "$SPEEDTEST_TMP_MARKER"

    if command -v wget >/dev/null 2>&1; then
        wget -q "$download_url" -O "$tmp_dir/speedtest.tgz"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$download_url" -o "$tmp_dir/speedtest.tgz"
    else
        echo -e "${gl_hong}未找到 wget 或 curl，无法下载 speedtest${gl_bai}" >&2
        rm -rf "$tmp_dir"
        rm -f "$SPEEDTEST_TMP_MARKER"
        return 1
    fi

    if ! tar -xzf "$tmp_dir/speedtest.tgz" -C "$tmp_dir" 2>/dev/null || [ ! -f "$tmp_dir/speedtest" ]; then
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
    echo -e "${gl_lv}Ookla Speedtest CLI 已在独立临时目录准备完成${gl_bai}" >&2
    return 0
}

detect_bandwidth() {
    local profile="${1:-optimize}"
    local requested_bandwidth="${BANDWIDTH_MBPS:-}"

    if [[ "$requested_bandwidth" =~ ^[0-9]+$ ]] && [ "$requested_bandwidth" -gt 0 ]; then
        echo "$requested_bandwidth"
        return 0
    fi
    if [ "$AUTO_MODE" = "1" ]; then
        echo "1000"
        return 0
    fi

    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    echo "" >&2
    ui_section "服务器带宽检测" >&2
    echo "" >&2
    echo "请选择瓶颈链路带宽的配置方式：" >&2
    if [ "$profile" = "optimize" ]; then
        echo -e "${gl_huang}优化机应填写到落地机方向的可用带宽；最近测速点结果仅供参考。${gl_bai}" >&2
    elif [ "$profile" = "landing" ]; then
        echo -e "${gl_huang}落地机应填写面向主要用户或优化机方向的可用带宽。${gl_bai}" >&2
    fi
    echo "1. 手动选择或输入目标带宽（推荐）" >&2
    echo "2. 自动检测（仅检测到最近测速点的本机出口）" >&2
    echo "3. 手动指定测速服务器（指定服务器ID）" >&2
    echo "" >&2
    
    read -e -p "请输入选择 [1]: " bw_choice
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        1) bw_choice="preset" ;;
        2) bw_choice="auto" ;;
        3) bw_choice="server" ;;
    esac

    case "$bw_choice" in
        auto)
            # 自动检测带宽 - 选择最近服务器
            echo "" >&2
            echo -e "${gl_huang}正在运行 speedtest 测速...${gl_bai}" >&2
            echo -e "${gl_zi}提示: 自动选择距离最近的服务器${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! ensure_speedtest; then
                echo "1000"
                return 1
            fi
            
            # 智能测速：获取附近服务器列表，按距离依次尝试
            echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}" >&2
            
            # 获取附近服务器列表（按延迟排序）
            local servers_list=$(run_speedtest --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            
            if [ -z "$servers_list" ]; then
                echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}" >&2
                servers_list="auto"
            else
                local server_count=$(echo "$servers_list" | wc -l)
                echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}" >&2
            fi
            echo "" >&2
            
            local speedtest_output=""
            local upload_speed=""
            local attempt=0
            local max_attempts=5  # 最多尝试5个服务器
            
            # 逐个尝试服务器
            for server_id in $servers_list; do
                attempt=$((attempt + 1))
                
                if [ $attempt -gt $max_attempts ]; then
                    echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}" >&2
                    break
                fi
                
                if [ "$server_id" = "auto" ]; then
                    echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}" >&2
                    speedtest_output=$(run_speedtest 2>&1)
                else
                    echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}" >&2
                    speedtest_output=$(run_speedtest --server-id="$server_id" 2>&1)
                fi
                
                echo "$speedtest_output" >&2
                echo "" >&2
                
                # 提取上传速度
                upload_speed=""
                if echo "$speedtest_output" | grep -q "Upload:"; then
                    upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
                fi
                if [ -z "$upload_speed" ]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi
                
                # 检查是否成功
                if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                    local success_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //')
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                    echo -e "${gl_zi}使用服务器: ${success_server}${gl_bai}" >&2
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo "" >&2
                    break
                else
                    local failed_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //' | sed 's/[[:space:]]*$//')
                    if [ -n "$failed_server" ]; then
                        echo -e "${gl_huang}⚠️  失败: ${failed_server}${gl_bai}" >&2
                    else
                        echo -e "${gl_huang}⚠️  此服务器失败${gl_bai}" >&2
                    fi
                    echo -e "${gl_zi}继续尝试下一个服务器...${gl_bai}" >&2
                    echo "" >&2
                fi
            done
            
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 所有尝试都失败了
            if [ -z "$upload_speed" ] || echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo -e "${gl_huang}⚠️  无法自动检测带宽${gl_bai}" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_zi}原因: 测速服务器可能暂时不可用${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_kjlan}默认配置方案：${gl_bai}" >&2
                echo -e "  带宽:       ${gl_huang}1000 Mbps (1 Gbps)${gl_bai}" >&2
                echo -e "  缓冲区:     ${gl_huang}根据地区自动计算${gl_bai}" >&2
                echo -e "  适用场景:   ${gl_zi}标准 1Gbps 服务器（覆盖大多数场景）${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                
                # 询问用户确认
                if confirm_yn "是否使用默认值 1000 Mbps？" "y" "y"; then
                    use_default=y
                else
                    use_default=n
                fi
                
                case "$use_default" in
                    [Yy])
                        echo "" >&2
                        echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                    [Nn])
                        echo "" >&2
                        echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                        local manual_bandwidth=""
                        while true; do
                            read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                            if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                                echo "" >&2
                                echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                                echo "$manual_bandwidth"
                                return 0
                            else
                                echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                            fi
                        done
                        ;;
                    *)
                        echo "" >&2
                        echo -e "${gl_huang}输入无效，使用默认值 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                esac
            fi
            
            # 转为整数并验证
            local upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                upload_mbps=1000
            fi

            echo -e "${gl_lv}✅ 检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
            echo "" >&2

            # 返回带宽值
            echo "$upload_mbps"
            return 0
            ;;
        server)
            # 手动指定测速服务器ID
            echo "" >&2
            ui_section "手动指定测速服务器" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! ensure_speedtest; then
                echo "1000"
                return 1
            fi
            
            # 显示如何查看服务器列表
            echo -e "${gl_zi}📋 如何查看可用的测速服务器：${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法1：查看所有服务器列表" >&2
            echo -e "  ${gl_huang}speedtest --servers${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法2：只显示附近服务器（推荐）" >&2
            echo -e "  ${gl_huang}speedtest --servers | head -n 20${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}💡 服务器列表格式说明：${gl_bai}" >&2
            echo -e "  每行开头的数字就是服务器ID" >&2
            echo -e "  例如: ${gl_huang}12345${gl_bai}) 服务商名称 (位置, 距离)" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 询问是否现在查看服务器列表
            if confirm_yn "是否现在查看附近的测速服务器列表？" "y" "y"; then
                show_list=y
            else
                show_list=n
            fi
            
            if [[ "$show_list" =~ ^[Yy]$ ]]; then
                echo "" >&2
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                run_speedtest --servers 2>/dev/null | head -n 20 >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
            fi
            
            # 输入服务器ID
            local server_id=""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入测速服务器ID（纯数字）: ${gl_bai}")" server_id
                
                if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}" >&2
                fi
            done
            
            # 使用指定服务器测速
            echo "" >&2
            echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            local speedtest_output=$(run_speedtest --server-id="$server_id" 2>&1)
            echo "$speedtest_output" >&2
            echo "" >&2
            
            # 提取上传速度
            local upload_speed=""
            if echo "$speedtest_output" | grep -q "Upload:"; then
                upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
            fi
            if [ -z "$upload_speed" ]; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
            fi
            
            # 检查测速是否成功
            if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                local upload_mbps=${upload_speed%.*}
                if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                    echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                    upload_mbps=1000
                fi
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                echo -e "${gl_lv}检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo "$upload_mbps"
                return 0
            else
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_hong}❌ 测速失败${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo -e "${gl_zi}可能原因：${gl_bai}" >&2
                echo "  - 服务器ID不存在或已下线" >&2
                echo "  - 网络连接问题" >&2
                echo "  - 该服务器暂时不可用" >&2
                echo "" >&2
                
                if confirm_yn "是否使用默认值 1000 Mbps？" "y" "y"; then
                    use_default=y
                else
                    use_default=n
                fi
                
                if [[ "$use_default" =~ ^[Yy]$ ]]; then
                    echo "" >&2
                    echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                else
                    echo "" >&2
                    echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                        fi
                    done
                fi
            fi
            ;;
        preset)
            # 手动选择预设档位
            echo "" >&2
            ui_section "手动选择带宽档位" >&2
            echo "" >&2
            echo "请选择带宽档位：" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            echo -e "${gl_huang}【小带宽 VPS】${gl_bai}" >&2
            echo "1. 100 Mbps   (NAT/极小带宽)" >&2
            echo "2. 200 Mbps   (小型VPS)" >&2
            echo "3. 300 Mbps   (入门服务器)" >&2
            echo "" >&2
            echo -e "${gl_huang}【中等带宽】${gl_bai}" >&2
            echo "4. 500 Mbps   (标准小带宽)" >&2
            echo "5. 700 Mbps   (准千兆)" >&2
            echo "6. 1 Gbps ⭐  (标准VPS/最常见)" >&2
            echo "" >&2
            echo -e "${gl_huang}【高带宽服务器】${gl_bai}" >&2
            echo "7. 1.5 Gbps   (中高端VPS)" >&2
            echo "8. 2 Gbps     (高性能VPS)" >&2
            echo "9. 2.5 Gbps   (准万兆)" >&2
            echo "" >&2
            echo -e "${gl_zi}提示: 缓冲区大小将根据后续选择的地区自动计算${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}【其他选项】${gl_bai}" >&2
            echo "10. 自定义输入（手动指定任意带宽值）" >&2
            echo "0. 返回上级菜单" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 读取用户选择
            local preset_choice=""
            read -e -p "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}  # 默认选择6 (1 Gbps)
            
            case "$preset_choice" in
                1)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 100 Mbps${gl_bai}" >&2
                    echo "100"
                    return 0
                    ;;
                2)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 200 Mbps${gl_bai}" >&2
                    echo "200"
                    return 0
                    ;;
                3)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 300 Mbps${gl_bai}" >&2
                    echo "300"
                    return 0
                    ;;
                4)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 500 Mbps${gl_bai}" >&2
                    echo "500"
                    return 0
                    ;;
                5)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 700 Mbps${gl_bai}" >&2
                    echo "700"
                    return 0
                    ;;
                6)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                    ;;
                7)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1500 Mbps${gl_bai}" >&2
                    echo "1500"
                    return 0
                    ;;
                8)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2000 Mbps${gl_bai}" >&2
                    echo "2000"
                    return 0
                    ;;
                9)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2500 Mbps${gl_bai}" >&2
                    echo "2500"
                    return 0
                    ;;
                10)
                    # 自定义输入
                    echo "" >&2
                    echo -e "${gl_zi}=== 自定义输入 ===${gl_bai}" >&2
                    echo "" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入带宽值（单位：Mbps，如 750、1200）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的正整数${gl_bai}" >&2
                        fi
                    done
                    ;;
                0)
                    # 返回上级菜单
                    echo "" >&2
                    echo -e "${gl_huang}已取消选择，返回上级菜单${gl_bai}" >&2
                    echo "1000"  # 返回默认值，避免空值
                    return 1
                    ;;
                *)
                    echo "" >&2
                    echo -e "${gl_hong}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${gl_huang}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
            echo "1000"
            return 1
            ;;
    esac
}

profile_label() {
    case "$1" in
        optimize) echo "优化机（代理节点 / Realm / Gost / nft 中转）" ;;
        landing) echo "落地机（高 RTT 直连 / 被优化机中转）" ;;
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

    echo "" >&2
    ui_section "选择服务器用途" >&2
    echo "1. 优化机：本机可建代理节点，也可用 Realm / Gost / nft 转发" >&2
    echo "2. 落地机：高延迟直连，或由前置优化机中转接入" >&2
    echo "3. 建站机：网站、API、反向代理，优先稳定和低内存" >&2
    echo "" >&2
    read -e -p "请输入选择 [1]: " profile_choice
    profile_choice=${profile_choice:-1}
    case "$profile_choice" in
        2) echo "landing" ;;
        3) echo "website" ;;
        *) echo "optimize" ;;
    esac
}

detect_active_tcp_rtt() {
    local samples sample_count percentile_index estimated_rtt

    command -v ss >/dev/null 2>&1 || return 1

    samples=$(
        LC_ALL=C ss -tinH state established 2>/dev/null |
            LC_ALL=C awk '
                {
                    for (field_index = 1; field_index <= NF; field_index++) {
                        if ($field_index ~ /^rtt:/) {
                            rtt_value = $field_index
                            sub(/^rtt:/, "", rtt_value)
                            sub(/\/.*/, "", rtt_value)
                            rtt_number = rtt_value + 0
                            if (rtt_value ~ /^[0-9]+([.][0-9]+)?$/ && rtt_number > 0 && rtt_number <= 2000) {
                                print rtt_number
                            }
                        }
                    }
                }
            '
    )
    [ -n "$samples" ] || return 1

    sample_count=$(printf '%s\n' "$samples" | awk 'NF {count++} END {print count + 0}')
    [ "$sample_count" -gt 0 ] || return 1
    percentile_index=$(( (sample_count * 3 + 3) / 4 ))
    estimated_rtt=$(
        printf '%s\n' "$samples" |
            LC_ALL=C sort -n |
            awk -v target="$percentile_index" 'NR == target {printf "%d\n", $1 + 0.5; exit}'
    )
    [[ "$estimated_rtt" =~ ^[0-9]+$ ]] || return 1
    [ "$estimated_rtt" -ge 1 ] || estimated_rtt=1

    printf '%s %s\n' "$estimated_rtt" "$sample_count"
}

select_target_rtt() {
    local profile="$1"
    local default_rtt=80
    local auto_max_rtt=500
    local rtt="${TARGET_RTT_MS:-}"
    local detected_rtt sample_count selected_rtt detection

    case "$profile" in
        landing) default_rtt=180 ;;
        website) default_rtt=50 ;;
    esac

    if [[ "$rtt" =~ ^[0-9]+$ ]] && [ "$rtt" -ge 1 ] && [ "$rtt" -le 2000 ]; then
        ui_info "使用 TARGET_RTT_MS 指定的目标 RTT: ${rtt}ms" >&2
        echo "$rtt"
        return 0
    fi
    if [ -n "$rtt" ]; then
        ui_warn "TARGET_RTT_MS 无效，已改用自动估算" >&2
    fi

    if detection=$(detect_active_tcp_rtt); then
        read -r detected_rtt sample_count <<< "$detection"
        selected_rtt=$detected_rtt

        # 活动连接可能主要来自本机或同机房；保留场景下限可避免明显低估窗口。
        if [ "$selected_rtt" -lt "$default_rtt" ]; then
            selected_rtt=$default_rtt
        elif [ "$selected_rtt" -gt "$auto_max_rtt" ]; then
            selected_rtt=$auto_max_rtt
        fi

        if [ "$selected_rtt" -eq "$detected_rtt" ]; then
            ui_success "已从 ${sample_count} 个活动 TCP 连接估算 RTT: ${selected_rtt}ms（75 分位）" >&2
        else
            ui_info "活动 TCP RTT 75 分位为 ${detected_rtt}ms，按场景安全范围采用 ${selected_rtt}ms" >&2
        fi
        echo "$selected_rtt"
        return 0
    fi

    ui_info "暂无有效活动 TCP RTT 样本，使用场景默认值: ${default_rtt}ms" >&2
    echo "$default_rtt"
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
    ui_info "Realm / Gost 等用户态代理通常不需要 FORWARD 链 MSS Clamp" >&2
    if confirm_yn "本机是否使用 iptables（含 iptables-nft）做内核转发，并需要自动 MSS Clamp？" "n" "n"; then
        echo "1"
    else
        echo "0"
    fi
}

detect_memory_mb() {
    local memory_mb limit_bytes limit_mb limit_file
    memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
    if ! [[ "$memory_mb" =~ ^[0-9]+$ ]] || [ "$memory_mb" -le 0 ]; then
        memory_mb=512
    fi

    for limit_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [ -r "$limit_file" ] || continue
        limit_bytes=$(cat "$limit_file" 2>/dev/null)
        [[ "$limit_bytes" =~ ^[0-9]+$ ]] || continue
        [ "$limit_bytes" -gt 0 ] || continue
        limit_mb=$((limit_bytes / 1024 / 1024))
        if [ "$limit_mb" -gt 0 ] && [ "$limit_mb" -lt "$memory_mb" ]; then
            memory_mb=$limit_mb
        fi
    done
    echo "$memory_mb"
}

calculate_initial_cwnd() {
    local bandwidth="$1"
    local rtt_ms="$2"
    local profile="$3"
    local requested="${INIT_CWND:-}"
    local initcwnd=16

    if [[ "$requested" =~ ^[0-9]+$ ]] && [ "$requested" -ge 10 ] && [ "$requested" -le 32 ]; then
        echo "$requested"
        return 0
    fi

    case "$profile" in
        optimize) initcwnd=20 ;;
        landing|website) initcwnd=16 ;;
    esac

    # 初始窗口只改善前几个 RTT；低带宽或高抖动链路不宜制造过大的首轮突发。
    if [ "$bandwidth" -lt 50 ]; then
        initcwnd=10
    elif [ "$bandwidth" -lt 100 ] && [ "$initcwnd" -gt 12 ]; then
        initcwnd=12
    elif [ "$bandwidth" -lt 300 ] && [ "$initcwnd" -gt 16 ]; then
        initcwnd=16
    fi
    if [ "$rtt_ms" -ge 250 ] && [ "$initcwnd" -gt 16 ]; then
        initcwnd=16
    fi
    echo "$initcwnd"
}

calculate_initial_rwnd() {
    local initcwnd="$1"
    local requested="${INIT_RWND:-}"

    if [[ "$requested" =~ ^[0-9]+$ ]] && [ "$requested" -ge 10 ] && [ "$requested" -le 32 ]; then
        echo "$requested"
    else
        echo "$initcwnd"
    fi
}

calculate_profile_buffer_size() {
    local bandwidth="$1"
    local rtt_ms="$2"
    local profile="$3"
    local memory_mb="$4"
    local bdp_mb required_mb memory_cap_mb profile_cap_mb buffer_mb minimum_mb multiplier_label

    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [ "$bandwidth" -le 0 ]; then
        bandwidth=1000
    fi
    if ! [[ "$rtt_ms" =~ ^[0-9]+$ ]] || [ "$rtt_ms" -le 0 ]; then
        rtt_ms=100
    fi
    if ! [[ "$memory_mb" =~ ^[0-9]+$ ]] || [ "$memory_mb" -le 0 ]; then
        memory_mb=512
    fi

    # BDP(MB) ≈ Mbps × RTT(ms) / 8000；向上取整避免低估目标链路窗口。
    bdp_mb=$(( (bandwidth * rtt_ms + 7999) / 8000 ))
    [ "$bdp_mb" -lt 1 ] && bdp_mb=1

    case "$profile" in
        website)
            required_mb=$(( (bdp_mb * 3 + 1) / 2 ))
            minimum_mb=4
            multiplier_label="1.5×BDP"
            ;;
        *)
            required_mb=$((bdp_mb * 2))
            minimum_mb=8
            multiplier_label="2×BDP"
            ;;
    esac
    [ "$required_mb" -lt "$minimum_mb" ] && required_mb=$minimum_mb

    # 这里只限制单 socket 自动调节上限，不会预先占用对应内存。
    if [ "$memory_mb" -le 256 ]; then
        memory_cap_mb=4
    elif [ "$memory_mb" -le 512 ]; then
        memory_cap_mb=8
    elif [ "$memory_mb" -le 1024 ]; then
        memory_cap_mb=16
    elif [ "$memory_mb" -le 2048 ]; then
        memory_cap_mb=32
    elif [ "$memory_mb" -le 4096 ]; then
        memory_cap_mb=48
    else
        memory_cap_mb=64
    fi

    profile_cap_mb=$memory_cap_mb
    if [ "$profile" = "website" ] && [ "$profile_cap_mb" -gt 16 ]; then
        profile_cap_mb=16
    fi

    buffer_mb=$required_mb
    [ "$buffer_mb" -gt "$profile_cap_mb" ] && buffer_mb=$profile_cap_mb

    echo "" >&2
    ui_section "BDP 与内存安全计算" >&2
    printf '  %-14s %s\n' "调优场景:" "$(profile_label "$profile")" >&2
    printf '  %-14s %s Mbps\n' "瓶颈带宽:" "$bandwidth" >&2
    printf '  %-14s %s ms\n' "目标 RTT:" "$rtt_ms" >&2
    printf '  %-14s %s MB\n' "链路 BDP:" "$bdp_mb" >&2
    printf '  %-14s %s MB（%s）\n' "吞吐需求值:" "$required_mb" "$multiplier_label" >&2
    printf '  %-14s %s MB\n' "可用内存上限:" "$memory_mb" >&2
    printf '  %-14s %s MB\n' "安全硬上限:" "$profile_cap_mb" >&2
    printf '  %-14s %s MB\n' "最终窗口上限:" "$buffer_mb" >&2
    if [ "$required_mb" -gt "$profile_cap_mb" ]; then
        ui_warn "内存安全上限低于理论需求；单连接可能无法跑满，建议使用多连接或增加内存" >&2
    fi
    ui_info "窗口值是自动调节上限，不是启动后立即占用的内存" >&2
    echo "$buffer_mb"
}

#=============================================================================
# SWAP智能检测和建议函数（集成到选项2/3）
#=============================================================================
check_and_suggest_swap() {
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local swap_total=$(free -m | awk 'NR==3{print $2}')
    local recommended_swap
    local need_swap=0
    
    # 判断是否需要SWAP
    if [ "$mem_total" -lt 2048 ]; then
        # 小于2GB内存，强烈建议配置SWAP
        need_swap=1
    elif [ "$mem_total" -lt 4096 ] && [ "$swap_total" -eq 0 ]; then
        # 2-4GB内存且没有SWAP，建议配置
        need_swap=1
    fi
    
    # 如果不需要SWAP，直接返回
    if [ "$need_swap" -eq 0 ]; then
        return 0
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
    
    # 显示建议信息
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_huang}检测到虚拟内存（SWAP）需要优化${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  物理内存:       ${gl_huang}${mem_total}MB${gl_bai}"
    echo -e "  当前 SWAP:      ${gl_huang}${swap_total}MB${gl_bai}"
    echo -e "  推荐 SWAP:      ${gl_lv}${recommended_swap}MB${gl_bai}"
    echo ""
    echo -e "${gl_huang}提示:${gl_bai} SWAP 调整会重建 /swapfile 并修改 /etc/fstab；卸载时按快照恢复原状态。"
    echo ""
    
    if [ "$mem_total" -lt 1024 ]; then
        echo -e "${gl_zi}原因: 小内存机器（<1GB）强烈建议配置SWAP，避免内存不足导致程序崩溃${gl_bai}"
    elif [ "$mem_total" -lt 2048 ]; then
        echo -e "${gl_zi}原因: 1-2GB内存建议配置SWAP，提供缓冲空间${gl_bai}"
    elif [ "$mem_total" -lt 4096 ]; then
        echo -e "${gl_zi}原因: 2-4GB内存建议配置少量SWAP作为保险${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 询问用户
    if confirm_yn "是否现在配置虚拟内存？" "n" "n"; then
        confirm=y
    else
        confirm=n
    fi

    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_lv}开始配置虚拟内存...${gl_bai}"
            echo ""
            if add_swap "$recommended_swap"; then
                echo ""
                echo -e "${gl_lv}✅ 虚拟内存配置完成！${gl_bai}"
            else
                echo ""
                echo -e "${gl_huang}⚠️ 虚拟内存配置未完成；系统未修改或已尝试自动回滚，请查看上方提示。${gl_bai}"
            fi
            echo ""
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            sleep 2
            return 0
            ;;
        [Nn])
            echo ""
            echo -e "${gl_huang}已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
        *)
            echo ""
            echo -e "${gl_huang}输入无效，已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
    esac
}

#=============================================================================
# 配置冲突检测与清理（避免被其他 sysctl 覆盖）
#=============================================================================
check_and_clean_conflicts() {
    ui_section "检查 sysctl 配置冲突"
    local conflicts=()
    # 搜索 /etc/sysctl.d/ 下可能覆盖 tcp_rmem/tcp_wmem 的高序号文件
    for conf in /etc/sysctl.d/[0-9]*-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        if grep -qE "^[[:space:]]*(net\.ipv4\.tcp_(rmem|wmem|congestion_control)|net\.core\.(rmem_max|wmem_max|default_qdisc))[[:space:]]*=" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            # 99 及以上优先生效，可能覆盖本脚本
            if [ -n "$num" ] && [ "$num" -ge 99 ]; then
                conflicts+=("$conf")
            fi
        fi
    done

    # 主配置文件直接设置也会覆盖
    local has_sysctl_conflict=0
    if [ -f /etc/sysctl.conf ] && grep -qE "^[[:space:]]*(net\.ipv4\.tcp_(rmem|wmem|congestion_control)|net\.core\.(rmem_max|wmem_max|default_qdisc))[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        echo -e "${gl_lv}✓ 未发现可能的覆盖配置${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}发现可能的覆盖配置：${gl_bai}"
    for f in "${conflicts[@]}"; do
        echo "  - $f"; grep -E "^[[:space:]]*(net\.ipv4\.tcp_(rmem|wmem|congestion_control)|net\.core\.(rmem_max|wmem_max|default_qdisc))[[:space:]]*=" "$f" | sed 's/^/      /'
    done
    [ $has_sysctl_conflict -eq 1 ] && echo "  - /etc/sysctl.conf (含 BBR/FQ 或 TCP 缓冲区设置)"

    if confirm_yn "是否自动禁用这些覆盖配置？" "n" "n"; then
        ans=y
    else
        ans=n
    fi
    case "$ans" in
        [Yy])
            # 注释 /etc/sysctl.conf 中相关行
            if [ $has_sysctl_conflict -eq 1 ]; then
                # 先创建一次备份，再用 sed -i 逐行注释（避免多次 .bak 覆盖）
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null
                clean_sysctl_conf
                echo -e "${gl_lv}✓ 已注释 /etc/sysctl.conf 中的相关配置（备份: .bak.conflict）${gl_bai}"
            fi
            # 将高优先级冲突文件重命名禁用
            for f in "${conflicts[@]}"; do
                if [ ! -f "$f" ]; then
                    echo -e "${gl_lv}✓ 已跳过: $(basename "$f")（已处理）${gl_bai}"
                    continue
                fi
                local disabled_file="${f}.disabled.$(date +%Y%m%d_%H%M%S)"
                if mv "$f" "$disabled_file" 2>/dev/null; then
                    printf '%s|%s\n' "$f" "$disabled_file" >> "$CONFLICT_STATE"
                    echo -e "${gl_lv}✓ 已禁用: $(basename "$f")${gl_bai}"
                else
                    echo -e "${gl_hong}✗ 无法禁用: $(basename "$f")，请手动处理${gl_bai}"
                fi
            done
            ;;
        *)
            echo -e "${gl_huang}已跳过自动清理，可能导致新配置未完全生效${gl_bai}"
            ;;
    esac
}

#=============================================================================
# 立即生效与防分片函数（无需重启）
#=============================================================================

ensure_bbr_available() {
    local available_cc original_qdisc

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
    if ! echo "$available_cc" | grep -qw bbr; then
        ui_error "当前内核未提供 tcp_bbr，已停止应用，避免生成无法生效的配置"
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
            ui_error "fq 预检成功，但未能恢复原默认队列 ${original_qdisc}"
            ui_info "当前默认队列可能已临时变为 fq，请检查 net.core.default_qdisc"
            return 1
        fi
    fi

    ui_success "内核已提供 BBR，且 fq 与 tc 均可用"
}

# 获取需应用 qdisc 的网卡（排除常见虚拟接口）
eligible_ifaces() {
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        echo "$dev"
    done
}

# tc fq 立即生效（无需重启）
apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        ui_error "未检测到 tc（iproute2），无法应用 fq"
        return 1
    fi
    local applied=0
    local preserved=0
    local failed=0
    local candidates=0
    local root_kind leaf_kinds
    for dev in $(eligible_ifaces); do
        candidates=$((candidates + 1))
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$root_kind" in
            mq)
                leaf_kinds=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2 != "mq" && $2 != "ingress" && $2 != "clsact" {print $2}' | sort -u | tr '\n' ' ')
                if [ -z "$leaf_kinds" ] || ! printf '%s\n' "$leaf_kinds" | tr ' ' '\n' | sed '/^$/d' | grep -Eqv '^(fq|fq_codel|pfifo_fast|pfifo|codel|sfq)$'; then
                    # 仅重建使用常见默认叶队列的 mq，避免覆盖 CAKE/HTB 等用户 QoS。
                    if tc qdisc replace dev "$dev" root mq 2>/dev/null; then
                        leaf_kinds=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2 != "mq" && $2 != "ingress" && $2 != "clsact" {print $2}' | sort -u | tr '\n' ' ')
                        if [ -n "$leaf_kinds" ] && ! printf '%s\n' "$leaf_kinds" | tr ' ' '\n' | sed '/^$/d' | grep -Eqv '^fq$'; then
                            applied=$((applied + 1))
                        else
                            failed=$((failed + 1))
                            ui_warn "网卡 $dev 已重建 mq，但未确认所有叶队列均为 fq"
                        fi
                    else
                        failed=$((failed + 1))
                        ui_warn "网卡 $dev 应用 mq + fq 叶队列失败"
                    fi
                else
                    preserved=$((preserved + 1))
                fi
                ;;
            ''|fq|fq_codel|pfifo_fast|pfifo|codel|sfq)
                if tc qdisc replace dev "$dev" root fq 2>/dev/null; then
                    applied=$((applied + 1))
                else
                    failed=$((failed + 1))
                    ui_warn "网卡 $dev 应用 fq 失败"
                fi
                ;;
            *)
                preserved=$((preserved + 1))
                ;;
        esac
    done
    if [ "$candidates" -eq 0 ]; then
        ui_error "未发现可管理的出口网卡，fq 未应用"
        return 1
    fi

    [ "$applied" -gt 0 ] && ui_success "已对 $applied 个网卡应用 fq，并保留 mq 多队列结构"
    [ "$preserved" -gt 0 ] && ui_warn "已保留 $preserved 个网卡的自定义队列，避免破坏现有 QoS"
    [ "$failed" -gt 0 ] && ui_error "$failed 个网卡未能确认 fq 生效"
    ui_info "qdisc 结果：成功 $applied，保留 $preserved，失败 $failed"
    [ "$failed" -eq 0 ]
}

apply_default_route_initial_window() {
    local initcwnd="$1"
    local initrwnd="$2"
    local current_route clean_route

    command -v ip >/dev/null 2>&1 || return 1
    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    [ -n "$current_route" ] || return 1
    clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $clean_route initcwnd "$initcwnd" initrwnd "$initrwnd" >/dev/null 2>&1
}

# MSS clamp（防分片）自动启用
apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 iptables，跳过 MSS clamp${gl_bai}"
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

#=============================================================================
# BBR 配置函数（智能检测版）
#=============================================================================

# 直连/落地优化配置
bbr_configure_direct() {
    ui_banner
    ui_section "应用 BBR + FQ 智能网络调优"
    if ! ensure_bbr_available; then
        return 1
    fi
    if ! snapshot_initial_state; then
        ui_error "未能创建恢复快照，已停止应用配置"
        return 1
    fi
    cleanup_legacy_runtime_before_apply
    
    ui_step 1 6 "选择用途并检查内存"
    local profile
    local profile_name
    local memory_mb
    profile=$(select_tuning_profile)
    profile_name=$(profile_label "$profile")
    memory_mb=$(detect_memory_mb)
    ui_success "已选择: $profile_name"
    ui_info "检测到可用内存上限: ${memory_mb}MB"
    check_and_suggest_swap

    echo ""
    ui_step 2 6 "测量瓶颈带宽、自动估算 RTT 与内存安全窗口"
    local detected_bandwidth
    local target_rtt_ms
    local buffer_mb
    local buffer_bytes
    local mss_clamp_enabled
    local initcwnd
    local initrwnd
    detected_bandwidth=$(detect_bandwidth "$profile")
    target_rtt_ms=$(select_target_rtt "$profile")
    buffer_mb=$(calculate_profile_buffer_size "$detected_bandwidth" "$target_rtt_ms" "$profile" "$memory_mb")
    buffer_bytes=$((buffer_mb * 1024 * 1024))
    initcwnd=$(calculate_initial_cwnd "$detected_bandwidth" "$target_rtt_ms" "$profile")
    initrwnd=$(calculate_initial_rwnd "$initcwnd")
    mss_clamp_enabled=$(select_mss_clamp "$profile")

    echo -e "${gl_lv}✅ 将使用 ${buffer_mb}MB TCP 自动窗口上限${gl_bai}"
    echo -e "${gl_lv}✅ 初始窗口: initcwnd=${initcwnd} / initrwnd=${initrwnd}${gl_bai}"
    sleep 2
    
    echo ""
    ui_step 3 6 "检查并处理配置冲突"
    echo "正在检查配置冲突..."
    
    # 备份主配置文件（如果还没备份）
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
        echo "已备份: /etc/sysctl.conf -> /etc/sysctl.conf.bak.original"
    fi
    
    # 注释掉 /etc/sysctl.conf 中的 TCP 缓冲区配置（避免覆盖）
    if [ -f /etc/sysctl.conf ]; then
        clean_sysctl_conf
        echo "已清理 /etc/sysctl.conf 中的冲突配置"
    fi
    
    # 检查并清理可能覆盖的新旧配置冲突
    check_and_clean_conflicts

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    ui_step 4 6 "生成独立 sysctl 配置"
    echo "正在创建新配置..."
    
    local somaxconn=8192
    local syn_backlog=8192
    local netdev_backlog=4096
    local tcp_slow_start_after_idle=0
    local tcp_notsent_lowat=262144
    local ip_local_port_range="10240 65535"

    case "$profile" in
        optimize)
            syn_backlog=16384
            netdev_backlog=5000
            ;;
        landing)
            somaxconn=4096
            ;;
        website)
            somaxconn=4096
            syn_backlog=8192
            netdev_backlog=2048
            tcp_slow_start_after_idle=1
            tcp_notsent_lowat=131072
            ip_local_port_range="32768 65535"
            ;;
    esac
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
    
    cat > "$SYSCTL_CONF" << EOF
# BBR multi-profile configuration (memory-aware BDP edition)
# Generated on $(date)
# Profile: ${profile} | Bandwidth: ${detected_bandwidth} Mbps | RTT: ${target_rtt_ms} ms
# Available memory cap: ${memory_mb} MB | TCP auto-tuning cap: ${buffer_mb} MB
# Route initial window: initcwnd ${initcwnd} | initrwnd ${initrwnd}

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲区与窗口自动调节（智能检测：${buffer_mb}MB）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 16384 ${buffer_bytes}

# ===== ${profile_name} =====

# 临时端口范围（避开常用服务端口）
net.ipv4.ip_local_port_range=${ip_local_port_range}

# 连接队列（按用途和内存收敛，避免突发流量放大内存）
net.core.somaxconn=${somaxconn}
net.ipv4.tcp_max_syn_backlog=${syn_backlog}
net.ipv4.tcp_abort_on_overflow=0

# 网络收包积压队列（不使用百万级或超大队列）
net.core.netdev_max_backlog=${netdev_backlog}

# 高级TCP优化
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_slow_start_after_idle=${tcp_slow_start_after_idle}
net.ipv4.tcp_mtu_probing=1

# 限制每个 socket 未发送队列，兼顾吞吐和内存占用
net.ipv4.tcp_notsent_lowat=${tcp_notsent_lowat}

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

    # 检查配置文件是否创建成功
    if [ ! -f "$SYSCTL_CONF" ] || [ ! -s "$SYSCTL_CONF" ]; then
        echo -e "${gl_hong}❌ 配置文件创建失败！请检查磁盘空间和权限${gl_bai}"
        return 1
    fi
    if ! printf 'profile=%s\nprofile_name=%s\nbandwidth_mbps=%s\nrtt_ms=%s\nmemory_mb=%s\nbuffer_mb=%s\ninitcwnd=%s\ninitrwnd=%s\nmss_clamp=%s\n' \
        "$profile" "$profile_name" "$detected_bandwidth" "$target_rtt_ms" \
        "$memory_mb" "$buffer_mb" "$initcwnd" "$initrwnd" "$mss_clamp_enabled" > "$PROFILE_STATE"; then
        ui_error "无法保存场景状态 $PROFILE_STATE"
        return 1
    fi
    chmod 600 "$PROFILE_STATE" 2>/dev/null || true

    # 步骤 4：应用配置
    echo ""
    ui_step 5 6 "应用参数并配置重启持久化"
    echo "正在应用配置..."
    local sysctl_output
    sysctl_output=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    local sysctl_rc=$?
    if [ $sysctl_rc -ne 0 ]; then
        echo -e "${gl_huang}⚠️ sysctl 部分参数应用失败（可能有不支持的参数）:${gl_bai}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -5
        echo -e "${gl_zi}将继续验证 BBR、FQ、窗口和路由初始窗口是否真正生效${gl_bai}"
    else
        echo -e "${gl_lv}✓ 所有 sysctl 参数已成功应用${gl_bai}"
    fi

    # 立即应用 fq 和路由初始窗口；MSS Clamp 仅用于明确启用的内核转发场景。
    echo "正在应用队列、初始窗口与防分片（无需重启）..."
    local qdisc_apply_failed=0
    if ! apply_tc_fq_now; then
        qdisc_apply_failed=1
        ui_error "部分网卡未能应用或验证 fq；配置流程继续完成，但最终将返回失败状态"
    fi
    if ! apply_default_route_initial_window "$initcwnd" "$initrwnd"; then
        ui_warn "默认 IPv4 路由未能写入 initcwnd/initrwnd；其余调优继续应用"
    fi
    if [ "$mss_clamp_enabled" = "1" ]; then
        apply_mss_clamp enable >/dev/null 2>&1
    else
        apply_mss_clamp disable >/dev/null 2>&1
    fi

    # 持久化所有运行时调优（重启后自动恢复）
    echo "正在配置重启持久化..."
    if mkdir -p /etc/modules-load.d 2>/dev/null && printf '%s\n' tcp_bbr > "$MODULES_CONF"; then
        echo -e "${gl_lv}✓ tcp_bbr 模块已配置为开机加载${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 无法写入 $MODULES_CONF，将由启动恢复脚本尝试加载${gl_bai}"
    fi

    cat > "$PERSIST_SCRIPT" << 'APPLYEOF'
#!/bin/bash
# BBR 多场景重启恢复脚本 - 自动生成，勿手动编辑
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
PROFILE_STATE="/var/lib/bbr-direct-tune/profile.state"
MSS_CLAMP_ENABLED=0
INITCWND=10
INITRWND=10
BUFFER_MB=0
if [ -s "$PROFILE_STATE" ]; then
    MSS_CLAMP_ENABLED=$(awk -F= '$1 == "mss_clamp" {print $2}' "$PROFILE_STATE")
    INITCWND=$(awk -F= '$1 == "initcwnd" {print $2}' "$PROFILE_STATE")
    INITRWND=$(awk -F= '$1 == "initrwnd" {print $2}' "$PROFILE_STATE")
    BUFFER_MB=$(awk -F= '$1 == "buffer_mb" {print $2}' "$PROFILE_STATE")
fi
# 显式加载 BBR 并重新应用 sysctl，避免仅依赖发行版默认启动顺序
if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
fi
CORE_FAILED=0
if command -v sysctl >/dev/null 2>&1 && [ -s "$SYSCTL_CONF" ]; then
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || CORE_FAILED=1
    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || CORE_FAILED=1
    if [[ "$BUFFER_MB" =~ ^[0-9]+$ ]] && [ "$BUFFER_MB" -gt 0 ]; then
        EXPECTED_BUFFER_BYTES=$((BUFFER_MB * 1024 * 1024))
        ACTUAL_WMEM=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
        ACTUAL_RMEM=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
        [ "$ACTUAL_WMEM" = "$EXPECTED_BUFFER_BYTES" ] || CORE_FAILED=1
        [ "$ACTUAL_RMEM" = "$EXPECTED_BUFFER_BYTES" ] || CORE_FAILED=1
    fi
else
    CORE_FAILED=1
fi
if command -v ip >/dev/null 2>&1; then
    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    if [ -n "$current_route" ]; then
        clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        ip route change $clean_route initcwnd "${INITCWND:-10}" initrwnd "${INITRWND:-10}" >/dev/null 2>&1 || true
    fi
fi
# 应用 tc fq 到所有物理网卡；失败时让启动服务返回非零，避免误报成功。
QDISC_FAILED=0
QDISC_CANDIDATES=0
if command -v tc >/dev/null 2>&1; then
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        QDISC_CANDIDATES=$((QDISC_CANDIDATES + 1))
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        case "$root_kind" in
            mq)
                leaf_kinds=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2 != "mq" && $2 != "ingress" && $2 != "clsact" {print $2}' | sort -u | tr '\n' ' ')
                if [ -z "$leaf_kinds" ] || ! printf '%s\n' "$leaf_kinds" | tr ' ' '\n' | sed '/^$/d' | grep -Eqv '^(fq|fq_codel|pfifo_fast|pfifo|codel|sfq)$'; then
                    if tc qdisc replace dev "$dev" root mq 2>/dev/null; then
                        leaf_kinds=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2 != "mq" && $2 != "ingress" && $2 != "clsact" {print $2}' | sort -u | tr '\n' ' ')
                        if [ -z "$leaf_kinds" ] || printf '%s\n' "$leaf_kinds" | tr ' ' '\n' | sed '/^$/d' | grep -Eqv '^fq$'; then
                            QDISC_FAILED=1
                        fi
                    else
                        QDISC_FAILED=1
                    fi
                fi
                ;;
            ''|fq|fq_codel|pfifo_fast|pfifo|codel|sfq)
                tc qdisc replace dev "$dev" root fq 2>/dev/null || QDISC_FAILED=1
                ;;
        esac
    done
    [ "$QDISC_CANDIDATES" -gt 0 ] || QDISC_FAILED=1
else
    QDISC_FAILED=1
fi
if [ "$MSS_CLAMP_ENABLED" = "1" ] && command -v iptables >/dev/null 2>&1; then
    if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
        --clamp-mss-to-pmtu -m comment --comment "bbr-direct-tune" >/dev/null 2>&1 && \
       ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
        --clamp-mss-to-pmtu >/dev/null 2>&1; then
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS \
            --clamp-mss-to-pmtu -m comment --comment "bbr-direct-tune"
    fi
fi
[ "$CORE_FAILED" -eq 0 ] && [ "$QDISC_FAILED" -eq 0 ] || exit 1
exit 0
APPLYEOF
    if [ ! -s "$PERSIST_SCRIPT" ] || ! chmod +x "$PERSIST_SCRIPT" || ! bash -n "$PERSIST_SCRIPT"; then
        echo -e "${gl_hong}❌ 启动恢复脚本创建失败，无法保证重启后继续生效${gl_bai}"
        return 1
    fi

    local persistence_ready=0
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat > "$SYSTEMD_SERVICE" << EOF
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
        if systemctl daemon-reload >/dev/null 2>&1 && \
           systemctl enable --now bbr-optimize-persist.service >/dev/null 2>&1 && \
           systemctl is-enabled --quiet bbr-optimize-persist.service && \
           systemctl is-active --quiet bbr-optimize-persist.service; then
            persistence_ready=1
            echo -e "${gl_lv}✓ systemd 重启持久化已启用${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ systemd 持久化服务启用失败，请检查 $SYSTEMD_SERVICE${gl_bai}"
        fi
    elif command -v rc-update >/dev/null 2>&1 && mkdir -p /etc/local.d 2>/dev/null; then
        cat > "$OPENRC_START" << EOF
#!/bin/sh
${PERSIST_SCRIPT}
EOF
        if chmod +x "$OPENRC_START" && rc-update add local default >/dev/null 2>&1 && \
           "$PERSIST_SCRIPT" >/dev/null 2>&1; then
            persistence_ready=1
            echo -e "${gl_lv}✓ OpenRC 重启持久化已启用${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ OpenRC 持久化启用失败，请检查 $OPENRC_START${gl_bai}"
        fi
    elif [ -d /etc/init.d ]; then
        cat > "$SYSV_SERVICE" << EOF
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
        chmod +x "$SYSV_SERVICE" 2>/dev/null || true
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d bbr-optimize-persist defaults >/dev/null 2>&1 && sysv_registered=1
        elif command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add bbr-optimize-persist >/dev/null 2>&1 && \
                chkconfig bbr-optimize-persist on >/dev/null 2>&1 && sysv_registered=1
        fi
        if [ "$sysv_registered" -eq 1 ] && "$SYSV_SERVICE" start >/dev/null 2>&1; then
            persistence_ready=1
            echo -e "${gl_lv}✓ SysV 重启持久化已启用${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ SysV 持久化启用失败，请检查 $SYSV_SERVICE${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠️ 未识别到 systemd、OpenRC 或 SysV，无法自动配置重启持久化${gl_bai}"
    fi

    if [ "$persistence_ready" -ne 1 ]; then
        echo -e "${gl_huang}当前参数已生效，但重启后需手动执行: $PERSIST_SCRIPT${gl_bai}"
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    ui_step 6 6 "验证运行状态"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    local actual_route=$(ip -4 route show default 2>/dev/null | head -1)
    local actual_initcwnd=$(echo "$actual_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
    local actual_initrwnd=$(echo "$actual_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
    
    echo ""
    ui_section "配置验证"
    
    # 验证队列算法
    if [ "$actual_qdisc" = "fq" ]; then
        echo -e "队列算法: ${gl_lv}$actual_qdisc ✓${gl_bai}"
    else
        echo -e "队列算法: ${gl_huang}$actual_qdisc (期望: fq) ⚠${gl_bai}"
    fi
    
    # 验证拥塞控制
    if [ "$actual_cc" = "bbr" ]; then
        echo -e "拥塞控制: ${gl_lv}$actual_cc ✓${gl_bai}"
    else
        echo -e "拥塞控制: ${gl_huang}$actual_cc (期望: bbr) ⚠${gl_bai}"
    fi
    
    # 验证缓冲区（动态）
    local actual_wmem_mb=$((actual_wmem / 1048576))
    local actual_rmem_mb=$((actual_rmem / 1048576))
    
    if [ "$actual_wmem" = "$buffer_bytes" ]; then
        echo -e "发送缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "发送缓冲区: ${gl_huang}${actual_wmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi
    
    if [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "接收缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "接收缓冲区: ${gl_huang}${actual_rmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi

    if [ "$actual_initcwnd" = "$initcwnd" ] && [ "$actual_initrwnd" = "$initrwnd" ]; then
        echo -e "初始窗口: ${gl_lv}cwnd ${initcwnd} / rwnd ${initrwnd} ✓${gl_bai}"
    else
        echo -e "初始窗口: ${gl_huang}cwnd ${actual_initcwnd:-未显式设置} / rwnd ${actual_initrwnd:-未显式设置} (期望: ${initcwnd}/${initrwnd}) ⚠${gl_bai}"
    fi

    echo ""

    # 最终判断：核心运行值或实际 qdisc 应用失败时，命令返回非零。
    local apply_result=0
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "bbr" ] && \
       [ "$actual_wmem" = "$buffer_bytes" ] && [ "$actual_rmem" = "$buffer_bytes" ] && \
       [ "$actual_initcwnd" = "$initcwnd" ] && [ "$actual_initrwnd" = "$initrwnd" ] && \
       [ "$qdisc_apply_failed" -eq 0 ]; then
        echo -e "${gl_lv}✅ BBR + FQ 多场景调优配置完成并已生效！${gl_bai}"
        echo -e "${gl_zi}配置说明: ${profile_name}，${detected_bandwidth} Mbps / ${target_rtt_ms} ms，窗口 ${buffer_mb}MB，初始窗口 ${initcwnd}/${initrwnd}${gl_bai}"
    else
        apply_result=1
        echo -e "${gl_huang}⚠️ 配置已保存但部分参数未生效${gl_bai}"
        echo -e "${gl_huang}建议执行以下操作：${gl_bai}"
        echo "1. 检查是否有其他配置文件冲突"
        echo "2. 重启服务器使配置完全生效: reboot"
    fi
    cleanup_speedtest_after_tuning
    return "$apply_result"
}

restore_disabled_sysctl_files() {
    local original_file disabled_file restored_count=0 failed_count=0

    [ -s "$CONFLICT_STATE" ] || return 0
    while IFS='|' read -r original_file disabled_file; do
        [ -n "$original_file" ] && [ -n "$disabled_file" ] || continue
        if [ -f "$disabled_file" ] && [ ! -e "$original_file" ]; then
            if mv "$disabled_file" "$original_file" 2>/dev/null; then
                restored_count=$((restored_count + 1))
            fi
        elif [ -f "$disabled_file" ] && [ -e "$original_file" ]; then
            ui_warn "未覆盖后来创建的 $original_file；旧文件保留在 $disabled_file"
            failed_count=$((failed_count + 1))
        fi
    done < "$CONFLICT_STATE"
    [ "$restored_count" -gt 0 ] && ui_success "已恢复 ${restored_count} 个被脚本禁用的 sysctl 文件"
    [ "$failed_count" -eq 0 ]
}

restore_runtime_snapshot() {
    local setting restored_count=0 failed_count=0

    [ -s "$SYSCTL_STATE" ] || return 0
    while IFS= read -r setting; do
        [ -n "$setting" ] || continue
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

restore_qdisc_snapshot() {
    local dev qdisc_kind restored_count=0 failed_count=0

    command -v tc >/dev/null 2>&1 || return 0
    [ -s "$QDISC_STATE" ] || return 0
    while IFS='|' read -r dev qdisc_kind; do
        [ -e "/sys/class/net/$dev" ] || continue
        case "$qdisc_kind" in
            none|noqueue|'')
                tc qdisc del dev "$dev" root >/dev/null 2>&1 || true
                ;;
            *)
                if tc qdisc replace dev "$dev" root "$qdisc_kind" >/dev/null 2>&1; then
                    restored_count=$((restored_count + 1))
                else
                    ui_warn "网卡 $dev 的原队列 $qdisc_kind 未能自动恢复"
                    failed_count=$((failed_count + 1))
                fi
                ;;
        esac
    done < "$QDISC_STATE"
    [ "$restored_count" -gt 0 ] && ui_success "已恢复 ${restored_count} 个网卡的原队列类型"
    [ "$failed_count" -eq 0 ]
}

restore_route_snapshot() {
    local initcwnd initrwnd current_route clean_route
    local route_metrics=()

    command -v ip >/dev/null 2>&1 || return 0
    [ -s "$ROUTE_STATE" ] || return 0
    initcwnd=$(awk -F= '$1 == "initcwnd" {print $2}' "$ROUTE_STATE")
    initrwnd=$(awk -F= '$1 == "initrwnd" {print $2}' "$ROUTE_STATE")
    current_route=$(ip -4 route show default 2>/dev/null | head -1)
    [ -n "$current_route" ] || return 0
    clean_route=$(echo "$current_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    [[ "$initcwnd" =~ ^[0-9]+$ ]] && route_metrics+=(initcwnd "$initcwnd")
    [[ "$initrwnd" =~ ^[0-9]+$ ]] && route_metrics+=(initrwnd "$initrwnd")
    if ip route replace $clean_route "${route_metrics[@]}" >/dev/null 2>&1; then
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
    rm -rf -- "$STATE_DIR"
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

show_actual_qdisc_status() {
    local dev root_kind leaf_kinds shown=0

    command -v tc >/dev/null 2>&1 || {
        printf '%-16s %s\n' "实际网卡队列" "无法检查（缺少 tc）"
        return 1
    }
    for dev in $(eligible_ifaces); do
        root_kind=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR == 1 {print $2}')
        [ -n "$root_kind" ] || root_kind="无/未知"
        if [ "$root_kind" = "mq" ]; then
            leaf_kinds=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2 != "mq" && $2 != "ingress" && $2 != "clsact" {print $2}' | sort -u | tr '\n' ',' | sed 's/,$//')
            printf '%-16s %s\n' "网卡 ${dev}" "root mq / leaf ${leaf_kinds:-未知}"
        else
            printf '%-16s %s\n' "网卡 ${dev}" "root ${root_kind}"
        fi
        shown=$((shown + 1))
    done
    if [ "$shown" -eq 0 ]; then
        printf '%-16s %s\n' "实际网卡队列" "未发现可管理网卡"
        return 1
    fi
}

check_bbr_status() {
    ui_banner
    ui_section "当前运行状态"
    printf '%-16s %s\n' "内核版本" "$(uname -r)"

    local congestion="未知"
    local qdisc="未知"
    local tcp_wmem="未知"
    local tcp_rmem="未知"
    local current_route=""
    local current_initcwnd="未显式设置（由内核决定）"
    local current_initrwnd="未显式设置（由内核决定）"

    if command -v sysctl >/dev/null 2>&1; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "未知")
        tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "未知")
    fi

    if command -v ip >/dev/null 2>&1; then
        current_route=$(ip -4 route show default 2>/dev/null | head -1)
        local route_initcwnd route_initrwnd
        route_initcwnd=$(echo "$current_route" | sed -n 's/.* initcwnd \([0-9][0-9]*\).*/\1/p')
        route_initrwnd=$(echo "$current_route" | sed -n 's/.* initrwnd \([0-9][0-9]*\).*/\1/p')
        [ -n "$route_initcwnd" ] && current_initcwnd=$route_initcwnd
        [ -n "$route_initrwnd" ] && current_initrwnd=$route_initrwnd
    fi

    printf '%-16s %s\n' "拥塞控制" "$congestion"
    printf '%-16s %s\n' "默认队列" "$qdisc"
    printf '%-16s %s\n' "发送缓冲区" "$tcp_wmem"
    printf '%-16s %s\n' "接收缓冲区" "$tcp_rmem"
    printf '%-16s %s / %s\n' "初始 cwnd/rwnd" "$current_initcwnd" "$current_initrwnd"
    show_actual_qdisc_status || true

    if [ -s "$PROFILE_STATE" ]; then
        local profile_name bandwidth_mbps rtt_ms memory_mb buffer_mb
        profile_name=$(awk -F= '$1 == "profile_name" {sub(/^[^=]*=/, ""); print}' "$PROFILE_STATE")
        bandwidth_mbps=$(awk -F= '$1 == "bandwidth_mbps" {print $2}' "$PROFILE_STATE")
        rtt_ms=$(awk -F= '$1 == "rtt_ms" {print $2}' "$PROFILE_STATE")
        memory_mb=$(awk -F= '$1 == "memory_mb" {print $2}' "$PROFILE_STATE")
        buffer_mb=$(awk -F= '$1 == "buffer_mb" {print $2}' "$PROFILE_STATE")
        [ -n "$profile_name" ] && printf '%-16s %s\n' "调优场景" "$profile_name"
        printf '%-16s %s Mbps / %s ms\n' "目标链路" "${bandwidth_mbps:-未知}" "${rtt_ms:-未知}"
        printf '%-16s %s MB / %s MB\n' "内存/窗口上限" "${memory_mb:-未知}" "${buffer_mb:-未知}"
    fi

    if [ -f "$SYSCTL_CONF" ]; then
        printf '%-16s %b%s%b\n' "配置文件" "$gl_lv" "$SYSCTL_CONF" "$gl_bai"
    else
        printf '%-16s %b%s%b\n' "配置文件" "$gl_huang" "未找到 $SYSCTL_CONF" "$gl_bai"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && \
       systemctl is-enabled bbr-optimize-persist.service >/dev/null 2>&1; then
        if systemctl is-active --quiet bbr-optimize-persist.service >/dev/null 2>&1; then
            printf '%-16s %b%s%b\n' "重启持久化" "$gl_lv" "systemd 已启用并运行" "$gl_bai"
        else
            printf '%-16s %b%s%b\n' "重启持久化" "$gl_huang" "systemd 已启用但未运行" "$gl_bai"
        fi
    elif command -v rc-update >/dev/null 2>&1 && [ -x "$OPENRC_START" ] && \
         rc-update show default 2>/dev/null | grep -qE '(^|[[:space:]])local([[:space:]]|$)'; then
        printf '%-16s %b%s%b\n' "重启持久化" "$gl_lv" "OpenRC 已启用" "$gl_bai"
    elif [ -x "$SYSV_SERVICE" ] && { compgen -G '/etc/rc*.d/S*bbr-optimize-persist' >/dev/null || \
         compgen -G '/etc/rc.d/rc*.d/S*bbr-optimize-persist' >/dev/null; }; then
        printf '%-16s %b%s%b\n' "重启持久化" "$gl_lv" "SysV 已启用" "$gl_bai"
    else
        printf '%-16s %b%s%b\n' "重启持久化" "$gl_huang" "未启用" "$gl_bai"
    fi

    if [ -f "$MODULES_CONF" ]; then
        printf '%-16s %b%s%b\n' "BBR 模块自启" "$gl_lv" "已配置" "$gl_bai"
    else
        printf '%-16s %b%s%b\n' "BBR 模块自启" "$gl_huang" "未配置" "$gl_bai"
    fi

    if [ -f "$SNAPSHOT_READY" ]; then
        local snapshot_mode
        snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || echo "legacy")
        if [ "$snapshot_mode" = "fresh" ]; then
            printf '%-16s %b%s%b\n' "恢复快照" "$gl_lv" "可精确恢复" "$gl_bai"
        else
            printf '%-16s %b%s%b\n' "恢复快照" "$gl_huang" "旧版兼容模式" "$gl_bai"
        fi
    else
        printf '%-16s %b%s%b\n' "恢复快照" "$gl_huang" "尚未创建" "$gl_bai"
    fi
}

restore_bbr_direct() {
    local snapshot_mode="none"
    local restore_failed=0
    local script_path=""
    [ -f "$SNAPSHOT_MODE" ] && snapshot_mode=$(cat "$SNAPSHOT_MODE" 2>/dev/null || echo "legacy")
    script_path=$(current_script_path 2>/dev/null || true)

    ui_banner
    ui_section "恢复脚本执行前状态"
    echo "将处理："
    echo "  - $SYSCTL_CONF"
    echo "  - $MODULES_CONF"
    echo "  - $SYSTEMD_SERVICE"
    echo "  - $OPENRC_START"
    echo "  - $SYSV_SERVICE"
    echo "  - $PERSIST_SCRIPT"
    echo "  - /etc/security/limits.conf 中的 BBR 文件描述符块"
    echo "  - 本脚本标记的 TCPMSS 规则"
    echo "  - 调优前 sysctl / qdisc / RPS / 初始窗口 / 透明大页状态（有快照时）"
    echo "  - 本脚本调整前的 /swapfile、/etc/fstab 与 Alpine Swap 启动文件（有快照时）"
    [ -n "$script_path" ] && echo "  - $script_path（完整恢复成功后删除）"
    echo ""
    ui_info "脚本创建的 Swap 会删除；原有 /swapfile 会按快照恢复"
    ui_warn "若 /swapfile 已被用户替换，卸载会停止并保留快照，避免误删"
    ui_info "为避免数据丢失，系统配置的 .bak 备份文件会保留"
    ui_warn "部分恢复失败时会保留快照和当前脚本，便于排查后重试"
    if ! confirm_yn "确认恢复、清理残留并删除当前脚本？" "n" "n"; then
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

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
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
        cp /etc/security/limits.conf "/etc/security/limits.conf.bak.bbr-restore.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        sed -i '/^# BBR - 文件描述符优化$/,+2d' /etc/security/limits.conf 2>/dev/null || true
    fi

    if [ -f /etc/sysctl.conf ]; then
        sed -i 's/^# bbr-direct-tune disabled: //' /etc/sysctl.conf 2>/dev/null || true
    fi
    restore_disabled_sysctl_files || restore_failed=1

    if [ "$snapshot_mode" != "fresh" ] && [ -f /etc/sysctl.conf.bak.original ]; then
        echo ""
        ui_warn "旧版备份恢复会覆盖调优后对 /etc/sysctl.conf 的手动修改"
        if confirm_yn "是否使用旧版完整备份覆盖 /etc/sysctl.conf？" "n" "n"; then
            cp /etc/sysctl.conf "/etc/sysctl.conf.bak.before-restore.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            cp /etc/sysctl.conf.bak.original /etc/sysctl.conf
            ui_success "已从旧版备份恢复 /etc/sysctl.conf"
        fi
    fi

    ui_step 3 6 "恢复脚本调整前的 Swap"
    restore_swap_state || restore_failed=1

    ui_step 4 6 "重新加载系统配置"
    if command -v sysctl >/dev/null 2>&1; then
        sysctl --system >/dev/null 2>&1 || true
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
        ui_warn "旧版没有运行态快照；配置已移除，重启后将按系统现有默认配置加载"
    fi

    ui_step 6 6 "验证恢复结果"
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

    ui_success "恢复完成；为避免中断现有连接，当前已加载的 tcp_bbr 模块不会强制卸载"
    ui_info "建议执行 status 检查状态，必要时安排一次维护重启"
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
    cat << EOF
BBR 多场景低内存调优独立版 v${SCRIPT_VERSION}

用法:
  sudo bash $0              打开交互式主菜单
  sudo bash $0 menu         打开交互式主菜单
  sudo bash $0 apply        交互式应用优化
  sudo bash $0 restore      恢复执行前状态，清理残留并删除当前脚本
  bash $0 status            查看当前 BBR / qdisc 状态
  bash $0 -h|--help         显示帮助

非交互示例:
  sudo env AUTO_MODE=1 TUNE_PROFILE=optimize BANDWIDTH_MBPS=1000 bash $0 apply

说明:
  - 首次应用会在 ${STATE_DIR} 保存恢复快照
  - 会写入 ${SYSCTL_CONF}
  - 会写入 ${MODULES_CONF}，确保 tcp_bbr 开机加载
  - 可能备份并注释 /etc/sysctl.conf 中冲突的 TCP 参数
  - 会创建 ${PERSIST_SCRIPT}
  - 支持 systemd、OpenRC 和 SysV 重启持久化
  - 支持优化机、落地机、建站机三种场景
  - RTT 优先取活动 TCP 连接的 75 分位；无样本时按场景使用 80/180/50 ms
  - 初始窗口按带宽、RTT 和场景自动收敛，并写入默认 IPv4 路由
  - 非交互可设置 TUNE_PROFILE、BANDWIDTH_MBPS；高级用户可用 TARGET_RTT_MS 覆盖自动值
  - 高级覆盖可设置 INIT_CWND、INIT_RWND（范围 10-32）
  - Realm/Gost 等用户态 TCP 代理可使用本机 BBR
  - 纯 nftables/iptables NAT 转发没有本机 TCP socket，BBR 不直接控制转发流
  - QUIC/Hysteria/TUIC 等 UDP 流量不由 TCP BBR 控制
  - 应用前会预检 BBR、fq 与 tc；实际网卡 qdisc 失败时 apply 返回非零
  - 仅使用 Ookla 官方 Speedtest CLI，不覆盖同名的其他客户端
  - 脚本临时下载的 Speedtest 会在测速结束后自动清理
  - 若你确认配置 SWAP，会先保存原大小、签名、启用状态、fstab 与 Alpine 启动文件
  - 恢复网络调优时会删除脚本创建的 Swap，或重建并恢复原有 /swapfile
  - 若检测到 /swapfile 已被用户替换，会停止卸载并保留快照，避免误删
  - 恢复完全成功后会清理脚本专属状态目录并删除当前脚本
  - 部分恢复失败时会保留快照和脚本，便于修复后重试
  - 为避免数据丢失，恢复时不会自动删除系统配置的 .bak 备份
EOF
}

show_main_menu() {
    local menu_choice=""
    local current_cc current_qdisc snapshot_label

    while true; do
        if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
            clear
        fi
        ui_banner
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        if [ -f "$SNAPSHOT_READY" ]; then
            snapshot_label="已保存"
        else
            snapshot_label="未创建"
        fi

        echo ""
        ui_box_rule "╭" "╮"
        ui_box_line "  当前摘要" "  ${gl_kjlan}当前摘要${gl_bai}"
        ui_box_rule "├" "┤"
        ui_box_line "  拥塞控制    ${current_cc}" \
            "  拥塞控制    ${gl_kjlan}${current_cc}${gl_bai}"
        ui_box_line "  默认队列    ${current_qdisc}" \
            "  默认队列    ${gl_zi}${current_qdisc}${gl_bai}"
        ui_box_line "  恢复快照    ${snapshot_label}" \
            "  恢复快照    ${gl_huang}${snapshot_label}${gl_bai}"
        ui_box_rule "╰" "╯"
        echo ""
        ui_box_rule "╭" "╮"
        ui_box_line "  操作菜单" "  ${gl_kjlan}操作菜单${gl_bai}"
        ui_box_rule "├" "┤"
        ui_box_line "  [1]  应用 / 更新 BBR + FQ 智能调优" \
            "  ${gl_kjlan}[1]${gl_bai}  应用 / 更新 BBR + FQ 智能调优"
        ui_box_line "  [2]  查看当前运行与持久化状态" \
            "  ${gl_zi}[2]${gl_bai}  查看当前运行与持久化状态"
        ui_box_line "  [3]  恢复执行前配置并清理本脚本" \
            "  ${gl_huang}[3]${gl_bai}  恢复执行前配置并清理本脚本"
        ui_box_line "  [4]  查看帮助与影响范围" \
            "  ${gl_hui}[4]${gl_bai}  查看帮助与影响范围"
        ui_box_line "  [0]  退出" \
            "  ${gl_hui}[0]${gl_bai}  退出"
        ui_box_rule "╰" "╯"
        echo ""
        if ! read -r -p "$(printf '%b请选择操作 [1]:%b ' "$gl_huang" "$gl_bai")" menu_choice; then
            ui_info "输入流已关闭，退出菜单"
            return 0
        fi
        menu_choice=${menu_choice//$'\r'/}
        menu_choice=${menu_choice:-1}

        case "$menu_choice" in
            1)
                check_root
                bbr_configure_direct
                cleanup_speedtest_after_tuning
                break_end
                ;;
            2)
                check_bbr_status
                break_end
                ;;
            3)
                check_root
                if restore_bbr_direct; then
                    return 0
                fi
                break_end
                ;;
            4)
                ui_section "帮助"
                show_help
                break_end
                ;;
            0|q|Q)
                ui_info "已退出"
                return 0
                ;;
            *)
                ui_warn "无效选项，请输入 0-4"
                sleep 1
                ;;
        esac
    done
}

main() {
    local command="${1:-}"
    local apply_rc=0

    [ ! -t 0 ] && AUTO_MODE=1
    if [ -z "$command" ]; then
        if [ "$AUTO_MODE" = "1" ] || [ ! -t 0 ]; then
            command="apply"
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
            bbr_configure_direct
            apply_rc=$?
            cleanup_speedtest_after_tuning
            return "$apply_rc"
            ;;
        restore)
            check_root
            restore_bbr_direct
            ;;
        status)
            check_bbr_status
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
