#!/usr/bin/env bash
# BBR 直连/落地优化脚本
# Base: Eric86777/vps-tcp-tune standalone 5.3.1
# Design: 保留原六步交互，按区域 RTT、实测带宽和机器资源自适应调优。

set -o pipefail

SCRIPT_VERSION="standalone-6.0.0"
SYSCTL_CONF="/etc/sysctl.d/99-z-bbr-direct-tune.conf"
LEGACY_SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
MODULES_CONF="/etc/modules-load.d/99-bbr-direct-tune.conf"
PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"
SYSTEMD_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
OPENRC_START="/etc/local.d/bbr-optimize.start"
CRON_FILE="/etc/cron.d/bbr-direct-tune"
STATE_DIR="/var/lib/bbr-direct-tune"
ORIGINAL_FILES_DIR="${STATE_DIR}/original-files"
FILE_MANIFEST="${STATE_DIR}/files.manifest"
SYSCTL_SNAPSHOT="${STATE_DIR}/sysctl.original"
PROC_SNAPSHOT="${STATE_DIR}/proc.original"
RPS_SNAPSHOT="${STATE_DIR}/rps.original"
QDISC_SNAPSHOT="${STATE_DIR}/qdisc.original"
QDISC_LEAF_SNAPSHOT="${STATE_DIR}/qdisc-leaves.original"
STATE_FILE="${STATE_DIR}/state.env"
AUTO_MODE="${AUTO_MODE:-0}"

gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'
gl_zi='\033[35m'
gl_hui='\033[90m'

TEMP_DIR=""
SPEEDTEST_BIN=""
SPEEDTEST_SERVER_ID=""
SPEEDTEST_DOWNLOAD_MBPS=0
SPEEDTEST_UPLOAD_MBPS=0
SPEEDTEST_IDLE_RTT=0
SPEEDTEST_SERVER_NAME=""
SPEEDTEST_RESULT_SERVER_ID=""
DETECTED_DOWNLOAD_MBPS=0
DETECTED_UPLOAD_MBPS=0
DETECTED_BANDWIDTH=0
REGION="asia"
REGION_LABEL="亚洲"
REPRESENTATIVE_RTT=60
DEFAULT_IFACE=""
BUFFER_MB=8
BUFFER_BYTES=8388608
IPV4_FORWARD=0
IPV6_FORWARD=0
MANAGE_IPV4_FORWARD=0
MANAGE_IPV6_FORWARD=0
IPV6_AVAILABLE=0
RA_REQUIRED=0
TPROXY_MODE=0
QDISC_MODE="none"
QDISC_MODIFIED=0
ORIGINAL_QDISC_ROOT_KIND=""
SHAPING_RATE_MBPS=0
RPS_ENABLED=0
RPS_MASK=""
RPS_FLOW_ENTRIES=0
RPS_PER_QUEUE=0
CONNTRACK_TARGET=0

cleanup_temp() {
    if [ -n "$TEMP_DIR" ]; then
        case "$TEMP_DIR" in
            /tmp/bbr-direct-tune.*)
                rm -rf -- "$TEMP_DIR" 2>/dev/null || true
                ;;
        esac
        TEMP_DIR=""
    fi
}

trap cleanup_temp EXIT
trap 'exit 130' INT TERM HUP

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: ${gl_bai}此脚本需要 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

break_end() {
    [ "$AUTO_MODE" = "1" ] && return
    echo -e "${gl_lv}操作完成${gl_bai}"
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

max_int() {
    if [ "$1" -ge "$2" ]; then
        echo "$1"
    else
        echo "$2"
    fi
}

min_int() {
    if [ "$1" -le "$2" ]; then
        echo "$1"
    else
        echo "$2"
    fi
}

get_cpu_count() {
    local count
    count=$(nproc 2>/dev/null)
    if ! is_positive_integer "$count"; then
        count=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    fi
    is_positive_integer "$count" || count=1
    echo "$count"
}

get_mem_total_mb() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    is_positive_integer "$mem_kb" || mem_kb=524288
    echo $((mem_kb / 1024))
}

get_default_iface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -z "$iface" ]; then
        iface=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    fi
    case "$iface" in
        ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    esac
    echo "$iface"
}

get_rx_queue_count() {
    local iface=$1
    local count=0
    local queue
    for queue in "/sys/class/net/${iface}/queues"/rx-*; do
        [ -d "$queue" ] || continue
        count=$((count + 1))
    done
    echo "$count"
}

sysctl_value() {
    sysctl -n "$1" 2>/dev/null
}

sysctl_exists() {
    sysctl -n "$1" >/dev/null 2>&1
}

sysctl_int() {
    local value
    value=$(sysctl_value "$1" | awk '{print $1}')
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    echo "$value"
}

ensure_state_dir() {
    mkdir -p "$ORIGINAL_FILES_DIR" || return 1
    chmod 700 "$STATE_DIR" "$ORIGINAL_FILES_DIR" 2>/dev/null || true
    touch "$FILE_MANIFEST" "$STATE_FILE" || return 1
    chmod 600 "$FILE_MANIFEST" "$STATE_FILE" 2>/dev/null || true
}

state_set() {
    local key=$1
    local value=$2
    local tmp="${STATE_FILE}.tmp"
    grep -v "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state() {
    [ -s "$STATE_FILE" ] && . "$STATE_FILE"
}

safe_backup_name() {
    printf '%s' "$1" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g'
}

snapshot_file() {
    local path=$1
    local backup_name
    backup_name=$(safe_backup_name "$path")
    grep -Fq "${path}|" "$FILE_MANIFEST" 2>/dev/null && return 0
    if [ -e "$path" ] || [ -L "$path" ]; then
        cp -a "$path" "${ORIGINAL_FILES_DIR}/${backup_name}" || return 1
        printf '%s|1|%s\n' "$path" "$backup_name" >> "$FILE_MANIFEST"
    else
        printf '%s|0|%s\n' "$path" "$backup_name" >> "$FILE_MANIFEST"
    fi
}

snapshot_sysctl_key() {
    local key=$1
    local value
    if sysctl_exists "$key"; then
        value=$(sysctl_value "$key")
        printf '%s\t1\t%s\n' "$key" "$value" >> "$SYSCTL_SNAPSHOT"
    else
        printf '%s\t0\t\n' "$key" >> "$SYSCTL_SNAPSHOT"
    fi
}

snapshot_proc_path() {
    local path=$1
    [ -f "$path" ] || return 0
    printf '%s\t%s\n' "$path" "$(cat "$path" 2>/dev/null)" >> "$PROC_SNAPSHOT"
}

snapshot_runtime_values() {
    [ -s "$SYSCTL_SNAPSHOT" ] && return 0
    : > "$SYSCTL_SNAPSHOT"
    : > "$PROC_SNAPSHOT"
    local key
    for key in \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max net.core.wmem_max \
        net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min \
        net.ipv4.tcp_window_scaling net.ipv4.tcp_sack \
        net.ipv4.tcp_dsack net.ipv4.tcp_timestamps \
        net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_syncookies net.ipv4.tcp_slow_start_after_idle \
        net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
        net.core.netdev_max_backlog net.ipv4.ip_local_port_range \
        fs.file-max net.ipv4.ip_forward \
        net.ipv4.conf.all.forwarding net.ipv4.conf.default.forwarding \
        net.ipv6.conf.all.forwarding net.ipv6.conf.default.forwarding \
        net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra \
        net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
        net.ipv4.conf.all.src_valid_mark net.ipv4.conf.default.src_valid_mark \
        net.ipv4.conf.all.route_localnet \
        net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects \
        net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects \
        net.ipv4.conf.all.secure_redirects net.ipv4.conf.default.secure_redirects \
        net.ipv6.conf.all.accept_redirects net.ipv6.conf.default.accept_redirects \
        net.netfilter.nf_conntrack_max net.core.rps_sock_flow_entries
    do
        snapshot_sysctl_key "$key"
    done

    if [ -n "$DEFAULT_IFACE" ]; then
        snapshot_proc_path "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/rp_filter"
        snapshot_proc_path "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/accept_redirects"
        snapshot_proc_path "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/send_redirects"
        snapshot_proc_path "/proc/sys/net/ipv6/conf/${DEFAULT_IFACE}/accept_ra"
        snapshot_proc_path "/proc/sys/net/ipv6/conf/${DEFAULT_IFACE}/accept_redirects"
    fi
}

snapshot_qdisc() {
    [ -s "$QDISC_SNAPSHOT" ] && return 0
    : > "$QDISC_SNAPSHOT"
    : > "$QDISC_LEAF_SNAPSHOT"
    command -v tc >/dev/null 2>&1 || return 0
    [ -n "$DEFAULT_IFACE" ] || return 0

    tc -d qdisc show dev "$DEFAULT_IFACE" > "$QDISC_SNAPSHOT" 2>/dev/null || true
    ORIGINAL_QDISC_ROOT_KIND=$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | awk '$0 ~ / root / {print $2; exit}')
    state_set ORIGINAL_QDISC_ROOT_KIND "$ORIGINAL_QDISC_ROOT_KIND"

    tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | awk '
        $0 ~ / parent / {
            kind=$2
            parent=""
            for(i=1;i<=NF;i++) if($i=="parent") parent=$(i+1)
            if(parent!="") print parent "|" kind
        }
    ' > "$QDISC_LEAF_SNAPSHOT"
}

snapshot_rps() {
    [ -s "$RPS_SNAPSHOT" ] && return 0
    : > "$RPS_SNAPSHOT"
    [ -n "$DEFAULT_IFACE" ] || return 0
    local path
    for path in "/sys/class/net/${DEFAULT_IFACE}/queues"/rx-*/rps_cpus \
                "/sys/class/net/${DEFAULT_IFACE}/queues"/rx-*/rps_flow_cnt; do
        [ -f "$path" ] || continue
        printf '%s\t%s\n' "$path" "$(cat "$path" 2>/dev/null)" >> "$RPS_SNAPSHOT"
    done
}

restore_proc_snapshot() {
    [ -s "$PROC_SNAPSHOT" ] || return 0
    local path value
    while IFS=$'\t' read -r path value; do
        case "$path" in
            /proc/sys/net/*)
                [ -f "$path" ] && printf '%s' "$value" > "$path" 2>/dev/null || true
                ;;
        esac
    done < "$PROC_SNAPSHOT"
}

restore_rps_snapshot() {
    [ -s "$RPS_SNAPSHOT" ] || return 0
    local path value
    while IFS=$'\t' read -r path value; do
        case "$path" in
            /sys/class/net/*/queues/rx-*/rps_cpus|/sys/class/net/*/queues/rx-*/rps_flow_cnt)
                [ -f "$path" ] && printf '%s' "$value" > "$path" 2>/dev/null || true
                ;;
        esac
    done < "$RPS_SNAPSHOT"
}

restore_sysctl_snapshot() {
    [ -s "$SYSCTL_SNAPSHOT" ] || return 0
    local key existed value
    while IFS=$'\t' read -r key existed value; do
        [ "$existed" = "1" ] || continue
        sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
    done < "$SYSCTL_SNAPSHOT"
}

restore_qdisc_snapshot() {
    command -v tc >/dev/null 2>&1 || return 0
    [ -n "${DEFAULT_IFACE:-}" ] || return 0
    [ -d "/sys/class/net/${DEFAULT_IFACE}" ] || return 0

    case "${ORIGINAL_QDISC_ROOT_KIND:-}" in
        mq)
            tc qdisc replace dev "$DEFAULT_IFACE" root mq >/dev/null 2>&1 || return 0
            if [ -s "$QDISC_LEAF_SNAPSHOT" ]; then
                local parent kind
                while IFS='|' read -r parent kind; do
                    case "$kind" in
                        fq|fq_codel|pfifo_fast|pfifo|bfifo|sfq)
                            tc qdisc replace dev "$DEFAULT_IFACE" parent "$parent" "$kind" >/dev/null 2>&1 || true
                            ;;
                    esac
                done < "$QDISC_LEAF_SNAPSHOT"
            fi
            ;;
        fq|fq_codel|pfifo_fast|pfifo|bfifo|sfq)
            tc qdisc replace dev "$DEFAULT_IFACE" root "$ORIGINAL_QDISC_ROOT_KIND" >/dev/null 2>&1 || \
                tc qdisc del dev "$DEFAULT_IFACE" root >/dev/null 2>&1 || true
            ;;
    esac
}

create_initial_snapshot() {
    ensure_state_dir || return 1
    local saved_iface saved_created original_enabled=0 original_active=0
    if [ -s "$STATE_FILE" ]; then
        saved_iface=$(bash -c '. "$1"; printf "%s" "${SNAPSHOT_IFACE:-}"' _ "$STATE_FILE" 2>/dev/null)
        saved_created=$(bash -c '. "$1"; printf "%s" "${SNAPSHOT_CREATED:-}"' _ "$STATE_FILE" 2>/dev/null)
    fi
    if [ -n "$saved_iface" ] && [ "$saved_iface" != "$DEFAULT_IFACE" ]; then
        echo -e "${gl_hong}已有快照对应网卡 ${saved_iface}，当前默认网卡为 ${DEFAULT_IFACE}。${gl_bai}"
        echo "请先执行 restore，再重新应用。"
        return 1
    fi

    if [ -z "$saved_created" ]; then
        case "$STATE_DIR" in
            /var/lib/bbr-direct-tune)
                rm -rf -- "$ORIGINAL_FILES_DIR"
                rm -f -- "$FILE_MANIFEST" "$SYSCTL_SNAPSHOT" "$PROC_SNAPSHOT" "$RPS_SNAPSHOT" "$QDISC_SNAPSHOT" "$QDISC_LEAF_SNAPSHOT" "$STATE_FILE"
                ;;
        esac
        ensure_state_dir || return 1
        snapshot_file "$SYSCTL_CONF" || return 1
        snapshot_file "$LEGACY_SYSCTL_CONF" || return 1
        snapshot_file "$MODULES_CONF" || return 1
        snapshot_file "$PERSIST_SCRIPT" || return 1
        snapshot_file "$SYSTEMD_SERVICE" || return 1
        snapshot_file "$OPENRC_START" || return 1
        snapshot_file "$CRON_FILE" || return 1
        snapshot_runtime_values || return 1
        snapshot_qdisc
        snapshot_rps
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet bbr-optimize-persist.service 2>/dev/null; then
            original_enabled=1
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet bbr-optimize-persist.service 2>/dev/null; then
            original_active=1
        fi
        state_set SNAPSHOT_IFACE "$DEFAULT_IFACE"
        state_set DEFAULT_IFACE "$DEFAULT_IFACE"
        state_set ORIGINAL_QDISC_ROOT_KIND "$ORIGINAL_QDISC_ROOT_KIND"
        state_set ORIGINAL_SYSTEMD_ENABLED "$original_enabled"
        state_set ORIGINAL_SYSTEMD_ACTIVE "$original_active"
        state_set SNAPSHOT_CREATED "$(date +%Y%m%d_%H%M%S)"
    fi
}

ensure_temp_dir() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        return 0
    fi
    TEMP_DIR=$(mktemp -d /tmp/bbr-direct-tune.XXXXXX) || return 1
    mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/config" "$TEMP_DIR/cache" "$TEMP_DIR/tmp" || return 1
    chmod 700 "$TEMP_DIR" "$TEMP_DIR/home" "$TEMP_DIR/config" "$TEMP_DIR/cache" "$TEMP_DIR/tmp" 2>/dev/null || true
}

speedtest_env() {
    HOME="$TEMP_DIR/home" \
    XDG_CONFIG_HOME="$TEMP_DIR/config" \
    XDG_CACHE_HOME="$TEMP_DIR/cache" \
    TMPDIR="$TEMP_DIR/tmp" \
    "$@"
}

verify_speedtest_archive() {
    local archive=$1
    local expected=$2
    if command -v sha512sum >/dev/null 2>&1; then
        local actual
        actual=$(sha512sum "$archive" | awk '{print $1}')
        [ "$actual" = "$expected" ] || {
            echo -e "${gl_hong}Speedtest 压缩包校验失败，拒绝执行。${gl_bai}" >&2
            return 1
        }
    else
        echo -e "${gl_huang}未找到 sha512sum，仅执行压缩包与二进制格式校验。${gl_bai}" >&2
    fi
}

ensure_speedtest() {
    ensure_temp_dir || {
        echo -e "${gl_hong}无法创建 Speedtest 临时目录。${gl_bai}" >&2
        return 1
    }

    if command -v speedtest >/dev/null 2>&1; then
        SPEEDTEST_BIN=$(command -v speedtest)
        return 0
    fi

    if [ -x "$TEMP_DIR/speedtest" ]; then
        SPEEDTEST_BIN="$TEMP_DIR/speedtest"
        return 0
    fi

    local arch url expected archive
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
            expected="f7ea30df2ff9b00b3a6cfe73149341661b6378fb702361d43aaec15b17eed792f527e6e24f3f47168925fab53c98f1c1a1ebbe59cbbf80c1afde11e0ac6708e1"
            ;;
        aarch64|arm64)
            url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
            expected="d7b73c54f20af66a2564b0b1fc301ca201761c35fb48a55ef921571656c3fba7d225256d0b97b79c5daeb3085d0eb1ed57a90174317315723ccf4b734566e569"
            ;;
        armv7l|armv7)
            url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-armhf.tgz"
            expected="6d54858f9f96e8eaed7cdf224a73a38674de720d0ba47a9c6e7f1a23338cb3e044c761bc196d1e4a2138219b3216b987c44a8995ccf284277cc581dd25d23365"
            ;;
        *)
            echo -e "${gl_hong}当前架构 ${arch} 没有内置 Speedtest 下载规则。${gl_bai}" >&2
            return 1
            ;;
    esac

    archive="$TEMP_DIR/speedtest.tgz"
    echo -e "${gl_huang}临时下载 Ookla Speedtest 1.2.0，退出时自动清理...${gl_bai}" >&2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --retry 2 "$url" -o "$archive" >&2 || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$archive" "$url" >&2 || return 1
    else
        echo -e "${gl_hong}未找到 curl 或 wget。${gl_bai}" >&2
        return 1
    fi

    verify_speedtest_archive "$archive" "$expected" || return 1
    tar -xzf "$archive" -C "$TEMP_DIR" >/dev/null 2>&1 || return 1
    [ -f "$TEMP_DIR/speedtest" ] || return 1
    chmod 700 "$TEMP_DIR/speedtest" || return 1
    "$TEMP_DIR/speedtest" --version >/dev/null 2>&1 || return 1
    SPEEDTEST_BIN="$TEMP_DIR/speedtest"
}

json_number() {
    local json=$1
    local object=$2
    local key=$3
    printf '%s' "$json" | sed -n "s/.*\"${object}\":{[^}]*\"${key}\":\([0-9.][0-9.]*\).*/\1/p" | head -n1
}

perform_speedtest() {
    local server_id=${1:-}
    ensure_speedtest || return 1
    local output rc download_bytes upload_bytes ping_latency
    local args=(--accept-license --accept-gdpr --progress=no --format=json)
    [ -n "$server_id" ] && args+=(--server-id="$server_id")

    output=$(speedtest_env "$SPEEDTEST_BIN" "${args[@]}" 2>&1)
    rc=$?
    if [ $rc -ne 0 ] || ! printf '%s' "$output" | grep -q '"download"'; then
        echo "$output" >&2
        return 1
    fi

    download_bytes=$(json_number "$output" download bandwidth)
    upload_bytes=$(json_number "$output" upload bandwidth)
    ping_latency=$(json_number "$output" ping latency)
    [[ "$download_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$upload_bytes" =~ ^[0-9]+$ ]] || return 1

    SPEEDTEST_DOWNLOAD_MBPS=$(awk -v value="$download_bytes" 'BEGIN {printf "%.0f", value*8/1000000}')
    SPEEDTEST_UPLOAD_MBPS=$(awk -v value="$upload_bytes" 'BEGIN {printf "%.0f", value*8/1000000}')
    SPEEDTEST_IDLE_RTT=$(awk -v value="${ping_latency:-0}" 'BEGIN {printf "%.0f", value}')
    SPEEDTEST_SERVER_NAME=$(printf '%s' "$output" | sed -n 's/.*"server":{[^}]*"name":"\([^"]*\)".*/\1/p' | head -n1)
    SPEEDTEST_RESULT_SERVER_ID=$(json_number "$output" server id)
    return 0
}

manual_bandwidth_menu() {
    if [ "$AUTO_MODE" = "1" ]; then
        DETECTED_DOWNLOAD_MBPS=1000
        DETECTED_UPLOAD_MBPS=1000
        DETECTED_BANDWIDTH=1000
        echo -e "${gl_huang}AUTO_MODE 未执行外部测速，采用 1000 Mbps 预设。${gl_bai}" >&2
        return 0
    fi
    echo "" >&2
    echo -e "${gl_kjlan}请选择服务器带宽档位：${gl_bai}" >&2
    echo "1. 100 Mbps" >&2
    echo "2. 200 Mbps" >&2
    echo "3. 300 Mbps" >&2
    echo "4. 500 Mbps" >&2
    echo "5. 700 Mbps" >&2
    echo "6. 1000 Mbps" >&2
    echo "7. 1500 Mbps" >&2
    echo "8. 2000 Mbps" >&2
    echo "9. 2500 Mbps" >&2
    echo "10. 自定义输入" >&2
    echo "" >&2
    local choice value
    read -e -p "请输入选择 [6]: " choice
    choice=${choice:-6}
    case "$choice" in
        1) value=100 ;;
        2) value=200 ;;
        3) value=300 ;;
        4) value=500 ;;
        5) value=700 ;;
        6) value=1000 ;;
        7) value=1500 ;;
        8) value=2000 ;;
        9) value=2500 ;;
        10)
            while true; do
                read -e -p "请输入带宽值（Mbps）: " value
                is_positive_integer "$value" && break
                echo -e "${gl_hong}请输入正整数。${gl_bai}" >&2
            done
            ;;
        *)
            echo -e "${gl_huang}无效选择，请重新选择。${gl_bai}" >&2
            manual_bandwidth_menu
            return
            ;;
    esac
    DETECTED_DOWNLOAD_MBPS=$value
    DETECTED_UPLOAD_MBPS=$value
    DETECTED_BANDWIDTH=$value
    echo -e "${gl_lv}采用手工带宽：${value} Mbps${gl_bai}" >&2
}

show_speedtest_servers() {
    ensure_speedtest || return 1
    echo -e "${gl_zi}附近 Speedtest 服务器：${gl_bai}" >&2
    speedtest_env "$SPEEDTEST_BIN" --accept-license --accept-gdpr --servers 2>/dev/null | head -n 12 >&2
}

detect_bandwidth() {
    echo "" >&2
    echo -e "${gl_kjlan}=== 服务器带宽检测 ===${gl_bai}" >&2
    echo "" >&2
    echo "请选择带宽配置方式：" >&2
    echo "1. 自动检测（默认）" >&2
    echo "2. 手动指定 Speedtest 服务器 ID" >&2
    echo "3. 手动选择带宽档位" >&2
    echo "" >&2

    local choice server_id
    if [ "$AUTO_MODE" = "1" ]; then
        choice=3
    else
        read -e -p "请输入选择 [1]: " choice
        choice=${choice:-1}
    fi

    case "$choice" in
        1)
            echo -e "${gl_huang}正在运行 Speedtest...${gl_bai}" >&2
            if perform_speedtest; then
                SPEEDTEST_SERVER_ID=$SPEEDTEST_RESULT_SERVER_ID
            else
                echo -e "${gl_huang}自动测速失败，转入手工带宽选择，不猜测端口速度。${gl_bai}" >&2
                manual_bandwidth_menu
                return 1
            fi
            ;;
        2)
            show_speedtest_servers || {
                echo -e "${gl_huang}无法运行 Speedtest，转入手工带宽选择。${gl_bai}" >&2
                manual_bandwidth_menu
                return 1
            }
            while true; do
                read -e -p "请输入 Speedtest 服务器 ID: " server_id
                [[ "$server_id" =~ ^[0-9]+$ ]] && break
                echo -e "${gl_hong}服务器 ID 必须为数字。${gl_bai}" >&2
            done
            if perform_speedtest "$server_id"; then
                SPEEDTEST_SERVER_ID=$server_id
            else
                echo -e "${gl_huang}指定服务器测速失败，转入手工带宽选择。${gl_bai}" >&2
                manual_bandwidth_menu
                return 1
            fi
            ;;
        3)
            manual_bandwidth_menu
            return 0
            ;;
        *)
            echo -e "${gl_huang}无效选择，转入手工带宽选择。${gl_bai}" >&2
            manual_bandwidth_menu
            return 1
            ;;
    esac

    DETECTED_DOWNLOAD_MBPS=$SPEEDTEST_DOWNLOAD_MBPS
    DETECTED_UPLOAD_MBPS=$SPEEDTEST_UPLOAD_MBPS
    DETECTED_BANDWIDTH=$(max_int "$DETECTED_DOWNLOAD_MBPS" "$DETECTED_UPLOAD_MBPS")
    [ "$DETECTED_BANDWIDTH" -gt 0 ] || DETECTED_BANDWIDTH=1

    echo "" >&2
    echo -e "${gl_lv}下载：${DETECTED_DOWNLOAD_MBPS} Mbps，上传：${DETECTED_UPLOAD_MBPS} Mbps，空闲延迟：${SPEEDTEST_IDLE_RTT} ms${gl_bai}" >&2
    [ -n "$SPEEDTEST_SERVER_NAME" ] && echo "测速服务器：$SPEEDTEST_SERVER_NAME" >&2
}

median_ping_rtt() {
    local target=$1
    case "$target" in
        ''|-*|*[!A-Za-z0-9_.:-]*) return 1 ;;
    esac
    command -v ping >/dev/null 2>&1 || return 1
    local values count position
    values=$(ping -n -c 7 -W 2 "$target" 2>/dev/null | sed -n 's/.*time[=<]\([0-9.][0-9.]*\).*/\1/p' | sort -n)
    count=$(printf '%s\n' "$values" | awk 'NF {count++} END {print count+0}')
    [ "$count" -ge 3 ] || return 1
    position=$(((count + 1) / 2))
    printf '%s\n' "$values" | awk -v position="$position" 'NF {row++; if(row==position) {printf "%.0f\n", $1; exit}}'
}

select_region_and_rtt() {
    local choice default_rtt peer measured input
    if [ "$AUTO_MODE" = "1" ]; then
        REGION="asia"
        REGION_LABEL="亚洲"
        REPRESENTATIVE_RTT=60
        return 0
    fi
    echo ""
    echo -e "${gl_kjlan}请选择主要用户/中转到本机的链路区域：${gl_bai}"
    echo "1. 亚洲链路（默认 RTT 60ms）"
    echo "2. 欧洲链路（默认 RTT 200ms）"
    echo "3. 美洲链路（默认 RTT 180ms）"
    echo "4. 自定义 RTT"
    echo ""
    read -e -p "请输入选择 [1]: " choice
    choice=${choice:-1}
    case "$choice" in
        2) REGION="europe"; REGION_LABEL="欧洲"; default_rtt=200 ;;
        3) REGION="america"; REGION_LABEL="美洲"; default_rtt=180 ;;
        4) REGION="custom"; REGION_LABEL="自定义"; default_rtt=100 ;;
        *) REGION="asia"; REGION_LABEL="亚洲"; default_rtt=60 ;;
    esac

    echo ""
    echo -e "${gl_zi}对端是关键链路另一端，例如落地机对应的中转机；直连用户可留空。${gl_bai}"
    read -e -p "代表性对端 IP/域名（回车自动估算）: " peer
    if [ -n "$peer" ]; then
        measured=$(median_ping_rtt "$peer")
        if is_positive_integer "$measured"; then
            default_rtt=$measured
            echo -e "${gl_lv}对端中位 RTT：${measured} ms${gl_bai}"
        else
            echo -e "${gl_huang}无法取得可靠 Ping，回退到 ${REGION_LABEL} 区域基线。${gl_bai}"
        fi
    fi

    echo -e "${gl_zi}Speedtest 本地延迟 ${SPEEDTEST_IDLE_RTT}ms 仅展示，不直接替代业务 RTT。${gl_bai}"
    read -e -p "代表性 RTT（回车采用 ${default_rtt} ms）: " input
    if is_positive_integer "$input" && [ "$input" -le 2000 ]; then
        REPRESENTATIVE_RTT=$input
    else
        REPRESENTATIVE_RTT=$default_rtt
    fi
}

calculate_buffer_size() {
    local bandwidth=$1
    local rtt=$2
    local mem_total cap_mb target_bytes target_mb
    mem_total=$(get_mem_total_mb)

    if [ "$mem_total" -le 512 ]; then
        cap_mb=16
    elif [ "$mem_total" -le 1024 ]; then
        cap_mb=32
    elif [ "$mem_total" -le 2048 ]; then
        cap_mb=64
    elif [ "$mem_total" -le 4096 ]; then
        cap_mb=128
    else
        cap_mb=256
    fi

    target_bytes=$((bandwidth * rtt * 250))
    target_mb=$(((target_bytes + 1048575) / 1048576))
    [ "$target_mb" -lt 8 ] && target_mb=8
    if [ "$target_mb" -gt "$cap_mb" ]; then
        echo -e "${gl_huang}理论 2×BDP 需要约 ${target_mb}MiB，受 ${mem_total}MiB 内存限制，封顶 ${cap_mb}MiB。${gl_bai}" >&2
        target_mb=$cap_mb
    fi

    BUFFER_MB=$target_mb
    BUFFER_BYTES=$((BUFFER_MB * 1024 * 1024))
    echo ""
    echo -e "${gl_kjlan}链路画像与缓冲计算：${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  主要链路: ${gl_huang}${REGION_LABEL}${gl_bai}"
    echo -e "  代表 RTT: ${gl_huang}${REPRESENTATIVE_RTT} ms${gl_bai}"
    echo -e "  计算带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}"
    echo -e "  物理内存: ${gl_huang}${mem_total} MiB${gl_bai}"
    echo -e "  TCP 上限: ${gl_lv}${BUFFER_MB} MiB${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

check_and_suggest_swap() {
    local mem_total swap_total
    mem_total=$(get_mem_total_mb)
    swap_total=$(awk '/^SwapTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    [[ "$swap_total" =~ ^[0-9]+$ ]] || swap_total=0
    echo -e "${gl_kjlan}=== 虚拟内存状态 ===${gl_bai}"
    echo "物理内存：${mem_total} MiB"
    echo "SWAP：${swap_total} MiB"
    if [ "$swap_total" -eq 0 ] && [ "$mem_total" -lt 1024 ]; then
        echo -e "${gl_huang}低内存机器建议单独配置 SWAP；本网络脚本不会删除或重建现有 /swapfile。${gl_bai}"
    else
        echo -e "${gl_lv}本步骤只检查，不修改 SWAP。${gl_bai}"
    fi
}

detect_tproxy_mode() {
    if command -v iptables-save >/dev/null 2>&1 && iptables-save -t mangle 2>/dev/null | grep -qw TPROXY; then
        TPROXY_MODE=1
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qiw tproxy; then
        TPROXY_MODE=1
    elif ip rule show 2>/dev/null | grep -q 'fwmark'; then
        TPROXY_MODE=1
    else
        TPROXY_MODE=0
    fi
}

select_forwarding() {
    local current4 current6 default4 default6 answer
    current4=$(sysctl_int net.ipv4.ip_forward)
    if sysctl_exists net.ipv6.conf.all.forwarding; then
        IPV6_AVAILABLE=1
        current6=$(sysctl_int net.ipv6.conf.all.forwarding)
    else
        IPV6_AVAILABLE=0
        current6=0
    fi
    [ "$current4" -eq 1 ] && default4=Y || default4=N
    [ "$current6" -eq 1 ] && default6=Y || default6=N

    if [ "$AUTO_MODE" = "1" ]; then
        IPV4_FORWARD=$current4
        IPV6_FORWARD=$current6
        MANAGE_IPV4_FORWARD=0
        MANAGE_IPV6_FORWARD=0
        return 0
    fi

    read -e -p "启用/保持 IPv4 内核转发？(Y/N) [${default4}]: " answer
    answer=${answer:-$default4}
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        IPV4_FORWARD=1
        MANAGE_IPV4_FORWARD=1
    else
        IPV4_FORWARD=$current4
        MANAGE_IPV4_FORWARD=0
    fi

    if [ "$IPV6_AVAILABLE" -eq 1 ]; then
        read -e -p "启用/保持 IPv6 内核转发？(Y/N) [${default6}]: " answer
        answer=${answer:-$default6}
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            IPV6_FORWARD=1
            MANAGE_IPV6_FORWARD=1
        else
            IPV6_FORWARD=$current6
            MANAGE_IPV6_FORWARD=0
        fi
    else
        IPV6_FORWARD=0
        MANAGE_IPV6_FORWARD=0
        echo -e "${gl_zi}当前内核未提供 IPv6 sysctl，已跳过 IPv6 转发。${gl_bai}"
    fi

    detect_tproxy_mode
    if [ "$TPROXY_MODE" -eq 1 ] && [ "$MANAGE_IPV4_FORWARD" -eq 1 ]; then
        echo -e "${gl_zi}检测到 TPROXY/fwmark，转发参数将使用策略路由兼容设置。${gl_bai}"
    fi

    if [ "$MANAGE_IPV6_FORWARD" -eq 1 ] && ip -6 route show default 2>/dev/null | grep -q 'proto ra'; then
        RA_REQUIRED=1
        echo -e "${gl_zi}IPv6 默认路由来自 RA，将设置 accept_ra=2，避免重启后丢失默认路由。${gl_bai}"
    else
        RA_REQUIRED=0
    fi
}

preflight_check() {
    local missing=0 command
    for command in sysctl ip awk sed grep; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo -e "${gl_hong}缺少必要命令：${command}${gl_bai}"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
        modprobe sch_htb >/dev/null 2>&1 || true
    fi
    if ! sysctl_value net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo -e "${gl_hong}当前内核未提供 BBR，停止写入配置。${gl_bai}"
        return 1
    fi
}

check_and_clean_conflicts() {
    echo -e "${gl_kjlan}=== 检查 sysctl 配置冲突（只读） ===${gl_bai}"
    local output
    output=$(grep -HnE '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.ipv4\.tcp_[rw]mem|net\.core\.[rw]mem_max)[[:space:]]*=' \
        /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf 2>/dev/null | \
        grep -Fv "$SYSCTL_CONF" | head -n 12)
    if [ -n "$output" ]; then
        echo -e "${gl_huang}发现已有相关配置，本脚本不会修改它们；开机一次性服务会在最后重载本脚本配置：${gl_bai}"
        echo "$output" | sed 's/^/  /'
    else
        echo -e "${gl_lv}✓ 未发现明显覆盖配置${gl_bai}"
    fi
}

prepare_tuning_values() {
    local current_rmem current_wmem current_core_rmem current_core_wmem
    local current_udp_rmem current_udp_wmem current_somax current_syn current_backlog
    local current_file_max current_ports port_start port_end port_width min_backlog mem_total

    current_rmem=$(sysctl_value net.ipv4.tcp_rmem)
    current_wmem=$(sysctl_value net.ipv4.tcp_wmem)
    TCP_RMEM_MIN=$(printf '%s' "$current_rmem" | awk '{print $1}')
    TCP_RMEM_DEFAULT=$(printf '%s' "$current_rmem" | awk '{print $2}')
    TCP_WMEM_MIN=$(printf '%s' "$current_wmem" | awk '{print $1}')
    TCP_WMEM_DEFAULT=$(printf '%s' "$current_wmem" | awk '{print $2}')
    is_positive_integer "$TCP_RMEM_MIN" || TCP_RMEM_MIN=4096
    is_positive_integer "$TCP_RMEM_DEFAULT" || TCP_RMEM_DEFAULT=87380
    is_positive_integer "$TCP_WMEM_MIN" || TCP_WMEM_MIN=4096
    is_positive_integer "$TCP_WMEM_DEFAULT" || TCP_WMEM_DEFAULT=16384

    current_core_rmem=$(sysctl_int net.core.rmem_max)
    current_core_wmem=$(sysctl_int net.core.wmem_max)
    CORE_RMEM_MAX=$(max_int "$current_core_rmem" "$BUFFER_BYTES")
    CORE_WMEM_MAX=$(max_int "$current_core_wmem" "$BUFFER_BYTES")

    current_udp_rmem=$(sysctl_int net.ipv4.udp_rmem_min)
    current_udp_wmem=$(sysctl_int net.ipv4.udp_wmem_min)
    UDP_RMEM_MIN=$(max_int "$current_udp_rmem" 8192)
    UDP_WMEM_MIN=$(max_int "$current_udp_wmem" 8192)

    current_somax=$(sysctl_int net.core.somaxconn)
    current_syn=$(sysctl_int net.ipv4.tcp_max_syn_backlog)
    current_backlog=$(sysctl_int net.core.netdev_max_backlog)
    SOMAXCONN=$(max_int "$current_somax" 8192)
    SYN_BACKLOG=$(max_int "$current_syn" 8192)
    if [ "$DETECTED_BANDWIDTH" -ge 1000 ]; then
        min_backlog=8192
    else
        min_backlog=4096
    fi
    NETDEV_BACKLOG=$(max_int "$current_backlog" "$min_backlog")

    current_ports=$(sysctl_value net.ipv4.ip_local_port_range)
    port_start=$(printf '%s' "$current_ports" | awk '{print $1}')
    port_end=$(printf '%s' "$current_ports" | awk '{print $2}')
    [[ "$port_start" =~ ^[0-9]+$ ]] || port_start=32768
    [[ "$port_end" =~ ^[0-9]+$ ]] || port_end=60999
    port_width=$((port_end - port_start + 1))
    if [ "$port_width" -lt 40000 ]; then
        LOCAL_PORT_RANGE="10240 65535"
    else
        LOCAL_PORT_RANGE="${port_start} ${port_end}"
    fi

    current_file_max=$(sysctl_int fs.file-max)
    if [ "$current_file_max" -gt 0 ] && [ "$current_file_max" -lt 1048576 ]; then
        FILE_MAX_TARGET=1048576
    else
        FILE_MAX_TARGET=0
    fi

    CONNTRACK_TARGET=0
    if { [ "$MANAGE_IPV4_FORWARD" -eq 1 ] || [ "$MANAGE_IPV6_FORWARD" -eq 1 ]; } && sysctl_exists net.netfilter.nf_conntrack_max; then
        local current_conntrack desired
        current_conntrack=$(sysctl_int net.netfilter.nf_conntrack_max)
        mem_total=$(get_mem_total_mb)
        desired=$((mem_total * 64))
        [ "$desired" -lt 65536 ] && desired=65536
        [ "$desired" -gt 262144 ] && desired=262144
        if [ "$desired" -gt "$current_conntrack" ]; then
            CONNTRACK_TARGET=$desired
        fi
    fi
}

write_sysctl_config() {
    local new_file="${STATE_DIR}/sysctl.new"
    {
        echo "# BBR Direct/Endpoint Configuration"
        echo "# Generated by bbr-direct-tune.sh v${SCRIPT_VERSION} on $(date -Is 2>/dev/null || date)"
        echo "# Region=${REGION_LABEL} RTT=${REPRESENTATIVE_RTT}ms Download=${DETECTED_DOWNLOAD_MBPS}Mbps Upload=${DETECTED_UPLOAD_MBPS}Mbps Buffer=${BUFFER_MB}MiB"
        echo ""
        echo "# 转发参数只在用户选择由本脚本管理时写入。"
        if [ "$MANAGE_IPV4_FORWARD" -eq 1 ]; then
            echo "net.ipv4.ip_forward=1"
            echo "net.ipv4.conf.all.forwarding=1"
            echo "net.ipv4.conf.default.forwarding=1"
        fi
        if [ "$MANAGE_IPV6_FORWARD" -eq 1 ]; then
            echo "net.ipv6.conf.all.forwarding=1"
            echo "net.ipv6.conf.default.forwarding=1"
        fi
        if [ "$MANAGE_IPV6_FORWARD" -eq 1 ] && [ "$RA_REQUIRED" -eq 1 ]; then
            echo "net.ipv6.conf.all.accept_ra=2"
            echo "net.ipv6.conf.default.accept_ra=2"
        fi
        if [ "$MANAGE_IPV4_FORWARD" -eq 1 ]; then
            if [ "$TPROXY_MODE" -eq 1 ]; then
                echo "net.ipv4.conf.all.rp_filter=0"
                echo "net.ipv4.conf.default.rp_filter=0"
                echo "net.ipv4.conf.all.src_valid_mark=1"
                echo "net.ipv4.conf.default.src_valid_mark=1"
                echo "net.ipv4.conf.all.route_localnet=1"
            else
                echo "net.ipv4.conf.all.rp_filter=2"
                echo "net.ipv4.conf.default.rp_filter=2"
            fi
            echo "net.ipv4.conf.all.accept_redirects=0"
            echo "net.ipv4.conf.default.accept_redirects=0"
            echo "net.ipv4.conf.all.send_redirects=0"
            echo "net.ipv4.conf.default.send_redirects=0"
            echo "net.ipv4.conf.all.secure_redirects=0"
            echo "net.ipv4.conf.default.secure_redirects=0"
        fi
        if [ "$MANAGE_IPV6_FORWARD" -eq 1 ]; then
            echo "net.ipv6.conf.all.accept_redirects=0"
            echo "net.ipv6.conf.default.accept_redirects=0"
        fi
        echo ""
        echo "# BBR 与队列调度"
        if [ "$QDISC_MODE" = "custom" ]; then
            echo "# 检测到自定义 qdisc，保留现有默认 qdisc 设置。"
        else
            echo "net.core.default_qdisc=fq"
        fi
        echo "net.ipv4.tcp_congestion_control=bbr"
        echo ""
        echo "# 按 2×BDP 与内存上限计算；只放大 autotuning 最大值。"
        echo "net.core.rmem_max=${CORE_RMEM_MAX}"
        echo "net.core.wmem_max=${CORE_WMEM_MAX}"
        echo "net.ipv4.tcp_rmem=${TCP_RMEM_MIN} ${TCP_RMEM_DEFAULT} ${BUFFER_BYTES}"
        echo "net.ipv4.tcp_wmem=${TCP_WMEM_MIN} ${TCP_WMEM_DEFAULT} ${BUFFER_BYTES}"
        echo "net.ipv4.udp_rmem_min=${UDP_RMEM_MIN}"
        echo "net.ipv4.udp_wmem_min=${UDP_WMEM_MIN}"
        echo ""
        echo "# 通用 TCP 能力"
        echo "net.ipv4.tcp_window_scaling=1"
        echo "net.ipv4.tcp_sack=1"
        sysctl_exists net.ipv4.tcp_dsack && echo "net.ipv4.tcp_dsack=1"
        echo "net.ipv4.tcp_timestamps=1"
        echo "net.ipv4.tcp_moderate_rcvbuf=1"
        echo "net.ipv4.tcp_mtu_probing=1"
        echo "net.ipv4.tcp_syncookies=1"
        echo "net.ipv4.tcp_slow_start_after_idle=0"
        echo ""
        echo "# 代理与 Web 服务队列；只升不降。"
        echo "net.core.somaxconn=${SOMAXCONN}"
        echo "net.ipv4.tcp_max_syn_backlog=${SYN_BACKLOG}"
        echo "net.core.netdev_max_backlog=${NETDEV_BACKLOG}"
        echo "net.ipv4.ip_local_port_range=${LOCAL_PORT_RANGE}"
        if [ "$FILE_MAX_TARGET" -gt 0 ]; then
            echo "fs.file-max=${FILE_MAX_TARGET}"
        fi
        if [ "$CONNTRACK_TARGET" -gt 0 ]; then
            echo "net.netfilter.nf_conntrack_max=${CONNTRACK_TARGET}"
        fi
    } > "$new_file" || return 1

    mkdir -p "$(dirname "$SYSCTL_CONF")" || return 1
    mv "$new_file" "$SYSCTL_CONF" || return 1
    chmod 644 "$SYSCTL_CONF" 2>/dev/null || true

    if [ -f "$LEGACY_SYSCTL_CONF" ] && [ "$LEGACY_SYSCTL_CONF" != "$SYSCTL_CONF" ]; then
        rm -f "$LEGACY_SYSCTL_CONF"
    fi
}

apply_runtime_forwarding() {
    [ -n "$DEFAULT_IFACE" ] || return 0
    if [ "$MANAGE_IPV4_FORWARD" -eq 1 ]; then
        if [ "$TPROXY_MODE" -eq 1 ]; then
            [ -f "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/rp_filter" ] && echo 0 > "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/rp_filter" 2>/dev/null || true
        else
            [ -f "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/rp_filter" 2>/dev/null || true
        fi
        [ -f "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/accept_redirects" ] && echo 0 > "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/accept_redirects" 2>/dev/null || true
        [ -f "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/send_redirects" ] && echo 0 > "/proc/sys/net/ipv4/conf/${DEFAULT_IFACE}/send_redirects" 2>/dev/null || true
    fi
    if [ "$MANAGE_IPV6_FORWARD" -eq 1 ]; then
        [ -f "/proc/sys/net/ipv6/conf/${DEFAULT_IFACE}/accept_redirects" ] && echo 0 > "/proc/sys/net/ipv6/conf/${DEFAULT_IFACE}/accept_redirects" 2>/dev/null || true
        if [ "$RA_REQUIRED" -eq 1 ] && [ -f "/proc/sys/net/ipv6/conf/${DEFAULT_IFACE}/accept_ra" ]; then
            echo 2 > "/proc/sys/net/ipv6/conf/${DEFAULT_IFACE}/accept_ra" 2>/dev/null || true
        fi
    fi
}

detect_qdisc_mode() {
    QDISC_MODE="none"
    ORIGINAL_QDISC_ROOT_KIND=""
    command -v tc >/dev/null 2>&1 || return 0
    ORIGINAL_QDISC_ROOT_KIND=$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | awk '$0 ~ / root / {print $2; exit}')
    case "$ORIGINAL_QDISC_ROOT_KIND" in
        fq|fq_codel|pfifo_fast|pfifo|bfifo|sfq)
            QDISC_MODE="simple"
            ;;
        mq)
            local unsafe
            unsafe=$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | awk '
                $0 ~ / parent / {
                    kind=$2
                    if(kind!="fq" && kind!="fq_codel" && kind!="pfifo_fast" && kind!="pfifo" && kind!="bfifo" && kind!="sfq") print kind
                }
            ' | head -n1)
            [ -z "$unsafe" ] && QDISC_MODE="mq" || QDISC_MODE="custom"
            ;;
        ''|noqueue)
            QDISC_MODE="none"
            ;;
        *)
            QDISC_MODE="custom"
            ;;
    esac
}

apply_fq_layout() {
    command -v tc >/dev/null 2>&1 || return 0
    case "$QDISC_MODE" in
        simple)
            if tc qdisc replace dev "$DEFAULT_IFACE" root fq >/dev/null 2>&1; then
                QDISC_MODIFIED=1
                return 0
            fi
            return 1
            ;;
        mq)
            local parent applied=0
            if ! tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | grep -q ' mq .* root '; then
                tc qdisc replace dev "$DEFAULT_IFACE" root mq >/dev/null 2>&1 || return 1
            fi
            for parent in $(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | awk '$0 ~ / parent / {for(i=1;i<=NF;i++) if($i=="parent") print $(i+1)}'); do
                tc qdisc replace dev "$DEFAULT_IFACE" parent "$parent" fq >/dev/null 2>&1 && applied=$((applied + 1))
            done
            [ "$applied" -gt 0 ] && QDISC_MODIFIED=1
            ;;
        custom)
            echo -e "${gl_huang}检测到自定义 qdisc（${ORIGINAL_QDISC_ROOT_KIND}），保持不变并跳过自动限速校准。${gl_bai}"
            ;;
        *)
            echo -e "${gl_huang}默认接口不支持安全替换 qdisc，已跳过。${gl_bai}"
            ;;
    esac
}

apply_shaping() {
    local rate=$1
    command -v tc >/dev/null 2>&1 || return 1
    [ "$QDISC_MODE" = "simple" ] || [ "$QDISC_MODE" = "mq" ] || return 1
    tc qdisc replace dev "$DEFAULT_IFACE" root handle 1: htb default 10 >/dev/null 2>&1 || return 1
    tc class replace dev "$DEFAULT_IFACE" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" >/dev/null 2>&1 || return 1
    tc qdisc replace dev "$DEFAULT_IFACE" parent 1:10 handle 10: fq >/dev/null 2>&1 || return 1
    QDISC_MODIFIED=1
}

build_cpu_mask() {
    local cpu_count=$1
    local remaining=$cpu_count
    local mask="" chunk value
    while [ "$remaining" -gt 0 ]; do
        if [ "$remaining" -ge 32 ]; then
            chunk=32
            value="ffffffff"
        else
            chunk=$remaining
            value=$(printf '%08x' $(((1 << chunk) - 1)))
        fi
        if [ -z "$mask" ]; then
            mask=$value
        else
            mask="${value},${mask}"
        fi
        remaining=$((remaining - chunk))
    done
    printf '%s\n' "$mask"
}

configure_rps() {
    local cpu_count rx_queues existing_nonzero path
    cpu_count=$(get_cpu_count)
    rx_queues=$(get_rx_queue_count "$DEFAULT_IFACE")
    RPS_ENABLED=0

    [ "$cpu_count" -gt 1 ] || return 0
    [ "$rx_queues" -gt 0 ] || return 0
    [ "$rx_queues" -lt "$cpu_count" ] || {
        echo -e "${gl_zi}网卡 RX 队列已覆盖 CPU，跳过 RPS。${gl_bai}"
        return 0
    }
    [ "$DETECTED_BANDWIDTH" -ge 500 ] || return 0

    existing_nonzero=0
    for path in "/sys/class/net/${DEFAULT_IFACE}/queues"/rx-*/rps_cpus; do
        [ -f "$path" ] || continue
        if cat "$path" 2>/dev/null | tr -d ',0\n' | grep -q .; then
            existing_nonzero=1
        fi
    done
    if [ "$existing_nonzero" -eq 1 ]; then
        echo -e "${gl_huang}检测到已有自定义 RPS mask，保持不变。${gl_bai}"
        return 0
    fi

    RPS_MASK=$(build_cpu_mask "$cpu_count")
    RPS_FLOW_ENTRIES=$((4096 * cpu_count))
    [ "$RPS_FLOW_ENTRIES" -gt 32768 ] && RPS_FLOW_ENTRIES=32768
    RPS_FLOW_ENTRIES=$(max_int "$RPS_FLOW_ENTRIES" "$(sysctl_int net.core.rps_sock_flow_entries)")
    RPS_PER_QUEUE=$((RPS_FLOW_ENTRIES / rx_queues))
    echo "$RPS_FLOW_ENTRIES" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || return 0

    local applied=0 queue_dir
    for path in "/sys/class/net/${DEFAULT_IFACE}/queues"/rx-*/rps_cpus; do
        [ -f "$path" ] || continue
        echo "$RPS_MASK" > "$path" 2>/dev/null && applied=$((applied + 1))
    done
    for queue_dir in "/sys/class/net/${DEFAULT_IFACE}/queues"/rx-*/; do
        [ -f "${queue_dir}rps_flow_cnt" ] || continue
        echo "$RPS_PER_QUEUE" > "${queue_dir}rps_flow_cnt" 2>/dev/null || true
    done
    if [ "$applied" -gt 0 ]; then
        RPS_ENABLED=1
        echo -e "${gl_lv}✓ 默认网卡 RPS/RFS 已启用（${cpu_count} 核，${rx_queues} RX 队列）${gl_bai}"
    fi
}

read_tcp_counters() {
    awk '
        $1=="Tcp:" && $2=="RtoAlgorithm" {
            for(i=2;i<=NF;i++) field_index[$i]=i
            next
        }
        $1=="Tcp:" && $2!="RtoAlgorithm" && field_index["OutSegs"] && field_index["RetransSegs"] {
            print $(field_index["OutSegs"]), $(field_index["RetransSegs"])
            exit
        }
    ' /proc/net/snmp 2>/dev/null
}

run_retrans_test() {
    local before_out before_retrans after_out after_retrans counters
    counters=$(read_tcp_counters)
    before_out=$(printf '%s' "$counters" | awk '{print $1}')
    before_retrans=$(printf '%s' "$counters" | awk '{print $2}')
    [[ "$before_out" =~ ^[0-9]+$ ]] || return 1
    [[ "$before_retrans" =~ ^[0-9]+$ ]] || return 1

    if ! perform_speedtest "$SPEEDTEST_SERVER_ID"; then
        return 1
    fi

    counters=$(read_tcp_counters)
    after_out=$(printf '%s' "$counters" | awk '{print $1}')
    after_retrans=$(printf '%s' "$counters" | awk '{print $2}')
    [[ "$after_out" =~ ^[0-9]+$ ]] || return 1
    [[ "$after_retrans" =~ ^[0-9]+$ ]] || return 1

    TEST_OUT=$((after_out - before_out))
    TEST_RETRANS=$((after_retrans - before_retrans))
    [ "$TEST_OUT" -lt 0 ] && TEST_OUT=0
    [ "$TEST_RETRANS" -lt 0 ] && TEST_RETRANS=0
    TEST_RATIO=$(awk -v retrans="$TEST_RETRANS" -v out="$TEST_OUT" 'BEGIN {if(out<=0) print "0.000"; else printf "%.3f", retrans*100/out}')
    TEST_UPLOAD=$SPEEDTEST_UPLOAD_MBPS
    return 0
}

retrans_is_low() {
    [ "$TEST_RETRANS" -eq 0 ] && return 0
    awk -v ratio="$TEST_RATIO" 'BEGIN {exit !(ratio <= 0.100)}'
}

calibrate_low_retransmission() {
    SHAPING_RATE_MBPS=0
    [ "$QDISC_MODE" = "simple" ] || [ "$QDISC_MODE" = "mq" ] || return 0
    command -v tc >/dev/null 2>&1 || return 0

    local answer
    if [ "$AUTO_MODE" = "1" ]; then
        answer=N
    else
        echo ""
        echo -e "${gl_kjlan}=== 一次性低重传校准 ===${gl_bai}"
        echo -e "${gl_zi}最多额外运行 6 次 Speedtest；只在重传确实改善时保留整形，不安装常驻程序。${gl_bai}"
        read -e -p "执行校准？(Y/N) [Y]: " answer
        answer=${answer:-Y}
    fi
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    echo -e "${gl_huang}正在测试不限速基线...${gl_bai}"
    if ! run_retrans_test; then
        echo -e "${gl_huang}无法取得可靠基线，跳过限速校准并保持 fq。${gl_bai}"
        apply_fq_layout >/dev/null 2>&1 || true
        return 0
    fi
    echo "基线上传：${TEST_UPLOAD} Mbps，重传：${TEST_RETRANS}/${TEST_OUT}（${TEST_RATIO}%）"
    if retrans_is_low; then
        echo -e "${gl_lv}✓ 不限速已达到低重传要求，保持全速。${gl_bai}"
        return 0
    fi

    local baseline_upload=$TEST_UPLOAD
    if ! is_positive_integer "$baseline_upload" || [ "$baseline_upload" -lt 10 ]; then
        echo -e "${gl_huang}基线上传值不足以安全计算整形速率，保持不限速。${gl_bai}"
        return 0
    fi

    local percent rate passed=0
    for percent in 98 95 92 90 85; do
        rate=$((baseline_upload * percent / 100))
        [ "$rate" -lt 1 ] && rate=1
        echo -e "${gl_zi}测试 ${percent}%：${rate} Mbps...${gl_bai}"
        if ! apply_shaping "$rate"; then
            echo -e "${gl_huang}无法应用 HTB+fq，恢复不限速。${gl_bai}"
            break
        fi
        sleep 1
        if ! run_retrans_test; then
            echo -e "${gl_huang}本档测速失败，继续下一档。${gl_bai}"
            continue
        fi
        echo "  实测上传：${TEST_UPLOAD} Mbps，重传：${TEST_RETRANS}/${TEST_OUT}（${TEST_RATIO}%）"
        if retrans_is_low; then
            SHAPING_RATE_MBPS=$rate
            passed=1
            echo -e "${gl_lv}✓ 保留最高达标速率：${rate} Mbps${gl_bai}"
            break
        fi
    done

    if [ "$passed" -ne 1 ]; then
        SHAPING_RATE_MBPS=0
        apply_fq_layout >/dev/null 2>&1 || true
        echo -e "${gl_huang}降低速率未达到低重传要求，已恢复不限速，避免无效牺牲带宽。${gl_bai}"
    fi
}

write_persist_script() {
    mkdir -p "$(dirname "$PERSIST_SCRIPT")" || return 1
    {
        echo '#!/usr/bin/env bash'
        echo 'set -o pipefail'
        printf 'SYSCTL_CONF=%q\n' "$SYSCTL_CONF"
        printf 'IFACE=%q\n' "$DEFAULT_IFACE"
        printf 'QDISC_MODE=%q\n' "$QDISC_MODE"
        printf 'SHAPING_RATE_MBPS=%q\n' "$SHAPING_RATE_MBPS"
        printf 'IPV4_FORWARD=%q\n' "$IPV4_FORWARD"
        printf 'IPV6_FORWARD=%q\n' "$IPV6_FORWARD"
        printf 'MANAGE_IPV4_FORWARD=%q\n' "$MANAGE_IPV4_FORWARD"
        printf 'MANAGE_IPV6_FORWARD=%q\n' "$MANAGE_IPV6_FORWARD"
        printf 'RA_REQUIRED=%q\n' "$RA_REQUIRED"
        printf 'TPROXY_MODE=%q\n' "$TPROXY_MODE"
        printf 'RPS_ENABLED=%q\n' "$RPS_ENABLED"
        printf 'RPS_MASK=%q\n' "$RPS_MASK"
        printf 'RPS_FLOW_ENTRIES=%q\n' "$RPS_FLOW_ENTRIES"
        printf 'RPS_PER_QUEUE=%q\n' "$RPS_PER_QUEUE"
        cat <<'APPLYEOF'

write_proc() {
    local path=$1
    local value=$2
    [ -f "$path" ] || return 1
    printf '%s' "$value" > "$path" 2>/dev/null
}

PERSIST_RC=0

if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
    modprobe sch_htb >/dev/null 2>&1 || true
fi

if command -v sysctl >/dev/null 2>&1 && [ -s "$SYSCTL_CONF" ]; then
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || PERSIST_RC=1
else
    PERSIST_RC=1
fi

attempt=0
while [ ! -d "/sys/class/net/$IFACE" ] && [ "$attempt" -lt 30 ]; do
    sleep 1
    attempt=$((attempt + 1))
done
if [ ! -d "/sys/class/net/$IFACE" ] && command -v ip >/dev/null 2>&1; then
    detected_iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -n "$detected_iface" ] && IFACE=$detected_iface
fi

if [ -d "/sys/class/net/$IFACE" ]; then
    if [ "$MANAGE_IPV4_FORWARD" = "1" ]; then
        if [ "$TPROXY_MODE" = "1" ]; then
            write_proc "/proc/sys/net/ipv4/conf/$IFACE/rp_filter" 0 || PERSIST_RC=1
        else
            write_proc "/proc/sys/net/ipv4/conf/$IFACE/rp_filter" 2 || PERSIST_RC=1
        fi
        write_proc "/proc/sys/net/ipv4/conf/$IFACE/accept_redirects" 0 || PERSIST_RC=1
        write_proc "/proc/sys/net/ipv4/conf/$IFACE/send_redirects" 0 || PERSIST_RC=1
    fi
    if [ "$MANAGE_IPV6_FORWARD" = "1" ]; then
        write_proc "/proc/sys/net/ipv6/conf/$IFACE/accept_redirects" 0 || PERSIST_RC=1
        if [ "$RA_REQUIRED" = "1" ]; then
            write_proc "/proc/sys/net/ipv6/conf/$IFACE/accept_ra" 2 || PERSIST_RC=1
        fi
    fi
else
    PERSIST_RC=1
fi

if { [ "$QDISC_MODE" = "simple" ] || [ "$QDISC_MODE" = "mq" ] || [ "$SHAPING_RATE_MBPS" -gt 0 ] 2>/dev/null; }; then
    command -v tc >/dev/null 2>&1 || PERSIST_RC=1
fi
if command -v tc >/dev/null 2>&1 && [ -d "/sys/class/net/$IFACE" ]; then
    if [ "$SHAPING_RATE_MBPS" -gt 0 ] 2>/dev/null; then
        tc qdisc replace dev "$IFACE" root handle 1: htb default 10 >/dev/null 2>&1 || PERSIST_RC=1
        tc class replace dev "$IFACE" parent 1: classid 1:10 htb rate "${SHAPING_RATE_MBPS}mbit" ceil "${SHAPING_RATE_MBPS}mbit" >/dev/null 2>&1 || PERSIST_RC=1
        tc qdisc replace dev "$IFACE" parent 1:10 handle 10: fq >/dev/null 2>&1 || PERSIST_RC=1
    elif [ "$QDISC_MODE" = "simple" ]; then
        tc qdisc replace dev "$IFACE" root fq >/dev/null 2>&1 || PERSIST_RC=1
    elif [ "$QDISC_MODE" = "mq" ]; then
        if ! tc qdisc show dev "$IFACE" 2>/dev/null | grep -q ' mq .* root '; then
            tc qdisc replace dev "$IFACE" root mq >/dev/null 2>&1 || PERSIST_RC=1
        fi
        leaf_count=0
        for parent in $(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$0 ~ / parent / {for(i=1;i<=NF;i++) if($i=="parent") print $(i+1)}'); do
            tc qdisc replace dev "$IFACE" parent "$parent" fq >/dev/null 2>&1 || PERSIST_RC=1
            leaf_count=$((leaf_count + 1))
        done
        [ "$leaf_count" -gt 0 ] || PERSIST_RC=1
    fi
fi

if [ "$RPS_ENABLED" = "1" ]; then
    [ -d "/sys/class/net/$IFACE/queues" ] || PERSIST_RC=1
    write_proc /proc/sys/net/core/rps_sock_flow_entries "$RPS_FLOW_ENTRIES" || PERSIST_RC=1
    for path in "/sys/class/net/$IFACE/queues"/rx-*/rps_cpus; do
        write_proc "$path" "$RPS_MASK" || PERSIST_RC=1
    done
    for queue_dir in "/sys/class/net/$IFACE/queues"/rx-*/; do
        write_proc "${queue_dir}rps_flow_cnt" "$RPS_PER_QUEUE" || PERSIST_RC=1
    done
fi

if command -v sysctl >/dev/null 2>&1; then
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || PERSIST_RC=1
fi

exit "$PERSIST_RC"
APPLYEOF
    } > "$PERSIST_SCRIPT" || return 1
    chmod 755 "$PERSIST_SCRIPT" || return 1
    bash -n "$PERSIST_SCRIPT" || return 1
}

setup_persistence() {
    mkdir -p /etc/modules-load.d || return 1
    printf '%s\n' tcp_bbr > "$MODULES_CONF" || return 1
    chmod 644 "$MODULES_CONF" 2>/dev/null || true
    write_persist_script || return 1

    local ready=0 result
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl stop bbr-optimize-persist.service >/dev/null 2>&1 || true
        cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Apply BBR direct tuning after network startup
After=network-online.target systemd-sysctl.service
Wants=network-online.target
ConditionPathIsExecutable=${PERSIST_SCRIPT}

[Service]
Type=oneshot
ExecStart=${PERSIST_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$SYSTEMD_SERVICE" 2>/dev/null || true
        if systemctl daemon-reload >/dev/null 2>&1 && \
           systemctl enable bbr-optimize-persist.service >/dev/null 2>&1 && \
           systemctl start bbr-optimize-persist.service >/dev/null 2>&1; then
            result=$(systemctl show -p Result --value bbr-optimize-persist.service 2>/dev/null)
            if systemctl is-enabled --quiet bbr-optimize-persist.service && [ "$result" = "success" ]; then
                ready=1
                echo -e "${gl_lv}✓ systemd 开机一次性持久化已启用并验证成功${gl_bai}"
            fi
        fi
    elif command -v rc-update >/dev/null 2>&1; then
        mkdir -p /etc/local.d || return 1
        cat > "$OPENRC_START" <<EOF
#!/bin/sh
${PERSIST_SCRIPT}
EOF
        chmod 755 "$OPENRC_START" || return 1
        if rc-update add local default >/dev/null 2>&1 && "$PERSIST_SCRIPT" >/dev/null 2>&1; then
            ready=1
            echo -e "${gl_lv}✓ OpenRC 开机一次性持久化已启用并验证成功${gl_bai}"
        fi
    elif [ -d /etc/cron.d ]; then
        printf '@reboot root %s >/dev/null 2>&1\n' "$PERSIST_SCRIPT" > "$CRON_FILE" || return 1
        chmod 644 "$CRON_FILE" 2>/dev/null || true
        if "$PERSIST_SCRIPT" >/dev/null 2>&1; then
            ready=1
            echo -e "${gl_huang}使用 cron @reboot 持久化；建议重启后执行 status 再确认。${gl_bai}"
        fi
    fi

    state_set QDISC_MODE "$QDISC_MODE"
    state_set QDISC_MODIFIED "$QDISC_MODIFIED"
    state_set SHAPING_RATE_MBPS "$SHAPING_RATE_MBPS"
    state_set RPS_ENABLED "$RPS_ENABLED"
    state_set RPS_MASK "$RPS_MASK"
    state_set RPS_FLOW_ENTRIES "$RPS_FLOW_ENTRIES"
    state_set RPS_PER_QUEUE "$RPS_PER_QUEUE"
    state_set IPV4_FORWARD "$IPV4_FORWARD"
    state_set IPV6_FORWARD "$IPV6_FORWARD"
    state_set MANAGE_IPV4_FORWARD "$MANAGE_IPV4_FORWARD"
    state_set MANAGE_IPV6_FORWARD "$MANAGE_IPV6_FORWARD"
    state_set RA_REQUIRED "$RA_REQUIRED"
    state_set TPROXY_MODE "$TPROXY_MODE"
    state_set REGION "$REGION"
    state_set REPRESENTATIVE_RTT "$REPRESENTATIVE_RTT"
    state_set BUFFER_MB "$BUFFER_MB"

    [ "$ready" -eq 1 ] || {
        echo -e "${gl_hong}未能建立可验证的开机持久化入口。当前参数已应用，但不保证重启后运行时 qdisc/RPS 恢复。${gl_bai}"
        return 1
    }
}

show_change_summary() {
    echo ""
    echo -e "${gl_kjlan}=== 写入前变更摘要 ===${gl_bai}"
    echo "默认出口网卡：${DEFAULT_IFACE}"
    echo "区域/RTT：${REGION_LABEL} / ${REPRESENTATIVE_RTT} ms"
    echo "下载/上传：${DETECTED_DOWNLOAD_MBPS} / ${DETECTED_UPLOAD_MBPS} Mbps"
    echo "TCP autotuning 上限：${BUFFER_MB} MiB"
    echo "IPv4/IPv6 转发：${IPV4_FORWARD}/${IPV6_FORWARD}"
    echo "qdisc 处理：${QDISC_MODE}（自定义配置将保持不变）"
    [ "$CONNTRACK_TARGET" -gt 0 ] && echo "conntrack 上限只升至：${CONNTRACK_TARGET}"
    echo ""
    echo "将生成或更新："
    echo "  - $SYSCTL_CONF"
    echo "  - $MODULES_CONF"
    echo "  - $PERSIST_SCRIPT"
    echo "  - systemd/OpenRC/cron 中一个开机一次性入口"
    echo "  - $STATE_DIR（首次应用前原值快照）"
    echo ""
    echo -e "${gl_zi}不会修改 /etc/sysctl.conf、其他 sysctl 文件、现有防火墙规则或部署常驻监控。${gl_bai}"
}

verify_configuration() {
    local cc qdisc tcp_rmem tcp_wmem persistence_ok=0
    cc=$(sysctl_value net.ipv4.tcp_congestion_control)
    qdisc=$(sysctl_value net.core.default_qdisc)
    tcp_rmem=$(sysctl_value net.ipv4.tcp_rmem)
    tcp_wmem=$(sysctl_value net.ipv4.tcp_wmem)

    echo ""
    echo -e "${gl_kjlan}=== 配置验证 ===${gl_bai}"
    [ "$cc" = "bbr" ] && echo -e "拥塞控制：${gl_lv}${cc} ✓${gl_bai}" || echo -e "拥塞控制：${gl_hong}${cc:-未知} ✗${gl_bai}"
    if [ "$QDISC_MODE" = "custom" ]; then
        echo -e "默认 qdisc：${gl_huang}${qdisc:-未知}（自定义 qdisc 已保留）${gl_bai}"
    elif [ "$qdisc" = "fq" ]; then
        echo -e "默认 qdisc：${gl_lv}${qdisc} ✓${gl_bai}"
    else
        echo -e "默认 qdisc：${gl_huang}${qdisc:-未知}${gl_bai}"
    fi
    echo "TCP rmem：$tcp_rmem"
    echo "TCP wmem：$tcp_wmem"
    echo "IPv4/IPv6 转发：$(sysctl_int net.ipv4.ip_forward)/$(sysctl_int net.ipv6.conf.all.forwarding)"
    if command -v tc >/dev/null 2>&1; then
        echo "出口 qdisc："
        tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | sed 's/^/  /'
    fi
    if [ "$SHAPING_RATE_MBPS" -gt 0 ]; then
        echo -e "低重传整形：${gl_lv}${SHAPING_RATE_MBPS} Mbps${gl_bai}"
    else
        echo -e "低重传整形：${gl_lv}不限速${gl_bai}"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl is-enabled --quiet bbr-optimize-persist.service && \
           [ "$(systemctl show -p Result --value bbr-optimize-persist.service 2>/dev/null)" = "success" ]; then
            persistence_ok=1
            echo -e "重启持久化：${gl_lv}systemd 已启用，最近一次执行成功 ✓${gl_bai}"
        fi
    elif [ -x "$OPENRC_START" ]; then
        persistence_ok=1
        echo -e "重启持久化：${gl_lv}OpenRC local 已配置 ✓${gl_bai}"
    elif [ -f "$CRON_FILE" ]; then
        persistence_ok=1
        echo -e "重启持久化：${gl_huang}cron @reboot 已配置，请重启后复核${gl_bai}"
    fi
    [ "$persistence_ok" -eq 1 ] || echo -e "重启持久化：${gl_hong}未通过验证 ✗${gl_bai}"

    if [ "$cc" = "bbr" ] && [ -s "$SYSCTL_CONF" ] && [ -x "$PERSIST_SCRIPT" ] && [ "$persistence_ok" -eq 1 ]; then
        echo -e "${gl_lv}✅ 调优配置已生效，并已建立重启持久化。${gl_bai}"
        return 0
    fi
    echo -e "${gl_hong}配置存在未通过项目，请根据上方状态处理后再重启。${gl_bai}"
    return 1
}

show_generated_files() {
    echo -e "${gl_kjlan}=== 本脚本文件与快照 ===${gl_bai}"
    local path
    for path in "$SYSCTL_CONF" "$MODULES_CONF" "$PERSIST_SCRIPT" "$SYSTEMD_SERVICE" "$OPENRC_START" "$CRON_FILE" "$STATE_DIR"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            echo -e "  ${gl_lv}存在${gl_bai}  $path"
        else
            echo -e "  ${gl_hui}不存在${gl_bai} $path"
        fi
    done
    echo "Speedtest 临时目录：脚本退出时自动删除，不作为持久化文件。"
    echo "常驻进程：无；持久化入口仅在开机时执行一次。"
}

bbr_configure_direct() {
    echo -e "${gl_kjlan}=== 配置 BBR + FQ 直连/落地优化（区域与机器自适应） ===${gl_bai}"
    echo ""
    preflight_check || return 1
    DEFAULT_IFACE=$(get_default_iface) || {
        echo -e "${gl_hong}未检测到默认出口网卡。${gl_bai}"
        return 1
    }
    echo "默认出口网卡：$DEFAULT_IFACE"
    detect_qdisc_mode

    echo ""
    echo -e "${gl_zi}[步骤 1/6] 检测内存与 SWAP...${gl_bai}"
    check_and_suggest_swap

    echo ""
    echo -e "${gl_zi}[步骤 2/6] 检测带宽、区域和代表性 RTT...${gl_bai}"
    detect_bandwidth || true
    select_region_and_rtt
    calculate_buffer_size "$DETECTED_BANDWIDTH" "$REPRESENTATIVE_RTT"
    select_forwarding
    prepare_tuning_values

    echo ""
    echo -e "${gl_zi}[步骤 3/6] 检查冲突并创建首次快照...${gl_bai}"
    check_and_clean_conflicts
    show_change_summary
    local confirm
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=YES
    else
        read -e -p "确认写入？输入 YES 继续: " confirm
    fi
    if [ "$confirm" != "YES" ]; then
        echo "已取消，未写入调优配置。"
        return 1
    fi
    create_initial_snapshot || return 1

    echo ""
    echo -e "${gl_zi}[步骤 4/6] 创建独立 sysctl 配置...${gl_bai}"
    write_sysctl_config || {
        echo -e "${gl_hong}创建 $SYSCTL_CONF 失败。${gl_bai}"
        return 1
    }
    echo -e "${gl_lv}✓ 调优配置已写入 $SYSCTL_CONF${gl_bai}"

    echo ""
    echo -e "${gl_zi}[步骤 5/6] 应用参数、校准重传并配置开机持久化...${gl_bai}"
    local output
    output=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}sysctl 配置未完整应用：${gl_bai}"
        echo "$output"
        return 1
    fi
    apply_runtime_forwarding
    apply_fq_layout || echo -e "${gl_huang}qdisc 即时应用未完全成功，将继续验证。${gl_bai}"
    configure_rps
    calibrate_low_retransmission
    setup_persistence || return 1

    echo ""
    echo -e "${gl_zi}[步骤 6/6] 验证配置与持久化...${gl_bai}"
    verify_configuration
    local rc=$?
    echo ""
    show_generated_files
    echo ""
    echo "回滚命令：重新运行本脚本并添加 restore 参数。"
    return $rc
}

check_bbr_status() {
    DEFAULT_IFACE=$(get_default_iface 2>/dev/null || true)
    [ -s "$STATE_FILE" ] && load_state
    echo -e "${gl_kjlan}=== 当前 BBR 直连/落地优化状态 ===${gl_bai}"
    echo "内核版本：$(uname -r)"
    echo "拥塞控制：$(sysctl_value net.ipv4.tcp_congestion_control)"
    echo "可用算法：$(sysctl_value net.ipv4.tcp_available_congestion_control)"
    echo "默认 qdisc：$(sysctl_value net.core.default_qdisc)"
    echo "默认出口网卡：${DEFAULT_IFACE:-未知}"
    echo "TCP rmem：$(sysctl_value net.ipv4.tcp_rmem)"
    echo "TCP wmem：$(sysctl_value net.ipv4.tcp_wmem)"
    echo "IPv4/IPv6 转发：$(sysctl_int net.ipv4.ip_forward)/$(sysctl_int net.ipv6.conf.all.forwarding)"
    if sysctl_exists net.netfilter.nf_conntrack_max; then
        echo "conntrack：$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?') / $(sysctl_int net.netfilter.nf_conntrack_max)"
    fi
    if [ -n "$DEFAULT_IFACE" ] && command -v tc >/dev/null 2>&1; then
        echo "出口 qdisc："
        tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | sed 's/^/  /'
    fi
    if [ -n "${SHAPING_RATE_MBPS:-}" ] && [ "${SHAPING_RATE_MBPS:-0}" -gt 0 ] 2>/dev/null; then
        echo "持久化整形：${SHAPING_RATE_MBPS} Mbps"
    else
        echo "持久化整形：不限速"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        echo "systemd 持久化：$(systemctl is-enabled bbr-optimize-persist.service 2>/dev/null || echo 未启用)"
        echo "最近执行结果：$(systemctl show -p Result --value bbr-optimize-persist.service 2>/dev/null || echo 未知)"
    elif [ -x "$OPENRC_START" ]; then
        echo "OpenRC 持久化：已配置"
    elif [ -f "$CRON_FILE" ]; then
        echo "cron @reboot：已配置"
    else
        echo "重启持久化：未配置"
    fi
    echo "说明：通用 sysctl 只能确认 BBR 已启用，不能可靠判断 BBR 代际。"
    echo ""
    show_generated_files
}

restore_files_from_manifest() {
    [ -s "$FILE_MANIFEST" ] || return 0
    local path existed backup
    while IFS='|' read -r path existed backup; do
        case "$path" in
            "$SYSCTL_CONF"|"$LEGACY_SYSCTL_CONF"|"$MODULES_CONF"|"$PERSIST_SCRIPT"|"$SYSTEMD_SERVICE"|"$OPENRC_START"|"$CRON_FILE")
                ;;
            *)
                echo -e "${gl_huang}跳过快照中未知路径：$path${gl_bai}"
                continue
                ;;
        esac
        if [ "$existed" = "1" ] && [ -e "${ORIGINAL_FILES_DIR}/${backup}" ]; then
            mkdir -p "$(dirname "$path")" 2>/dev/null || true
            rm -f "$path"
            cp -a "${ORIGINAL_FILES_DIR}/${backup}" "$path" || return 1
        else
            rm -f "$path"
        fi
    done < "$FILE_MANIFEST"
}

legacy_cleanup_without_snapshot() {
    echo -e "${gl_huang}没有找到首次应用快照，只能删除已知脚本文件，无法猜测并恢复原运行参数。${gl_bai}"
    command -v systemctl >/dev/null 2>&1 && systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    rm -f "$SYSCTL_CONF" "$MODULES_CONF" "$PERSIST_SCRIPT" "$SYSTEMD_SERVICE" "$OPENRC_START" "$CRON_FILE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    command -v sysctl >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 || true
}

restore_bbr_direct() {
    echo -e "${gl_huang}即将恢复本脚本首次应用前保存的系统参数和文件。${gl_bai}"
    if [ ! -s "$STATE_FILE" ]; then
        read -e -p "未找到快照。输入 CLEAN 仅清理已知脚本文件: " confirm
        [ "$confirm" = "CLEAN" ] || { echo "已取消。"; return 1; }
        legacy_cleanup_without_snapshot
        echo -e "${gl_lv}已完成有限清理。${gl_bai}"
        return 0
    fi

    load_state
    echo "快照目录：$STATE_DIR"
    echo "快照网卡：${SNAPSHOT_IFACE:-未知}"
    read -e -p "输入 RESTORE 继续: " confirm
    [ "$confirm" = "RESTORE" ] || { echo "已取消。"; return 1; }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    fi

    restore_files_from_manifest || {
        echo -e "${gl_hong}恢复原文件失败，保留快照目录以便人工处理。${gl_bai}"
        return 1
    }
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    command -v sysctl >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 || true
    restore_sysctl_snapshot
    restore_proc_snapshot
    restore_rps_snapshot
    DEFAULT_IFACE=${SNAPSHOT_IFACE:-$DEFAULT_IFACE}
    restore_qdisc_snapshot

    if [ "${ORIGINAL_SYSTEMD_ENABLED:-0}" = "1" ] && command -v systemctl >/dev/null 2>&1 && [ -f "$SYSTEMD_SERVICE" ]; then
        systemctl enable bbr-optimize-persist.service >/dev/null 2>&1 || true
    fi
    if [ "${ORIGINAL_SYSTEMD_ACTIVE:-0}" = "1" ] && command -v systemctl >/dev/null 2>&1 && [ -f "$SYSTEMD_SERVICE" ]; then
        systemctl start bbr-optimize-persist.service >/dev/null 2>&1 || true
    fi

    case "$STATE_DIR" in
        /var/lib/bbr-direct-tune) rm -rf -- "$STATE_DIR" ;;
    esac
    echo -e "${gl_lv}✅ 已恢复首次应用前的 sysctl、qdisc、RPS 和同名文件。${gl_bai}"
}

show_help() {
    cat <<EOF
BBR 直连/落地优化（区域与机器自适应）v${SCRIPT_VERSION}

用法:
  sudo bash $0              交互式应用优化
  sudo bash $0 apply        交互式应用优化
  sudo bash $0 restore      恢复首次应用前参数和文件
  bash $0 status            查看当前状态与持久化结果
  bash $0 files             查看脚本生成文件和快照
  bash $0 -h|--help         显示帮助

持久化:
  - sysctl: ${SYSCTL_CONF}
  - 开机一次性脚本: ${PERSIST_SCRIPT}
  - systemd/OpenRC/cron 仅使用其中一个，不运行常驻监控
  - 首次快照: ${STATE_DIR}

说明:
  - Speedtest 只在临时目录运行，正常退出或中断后自动清理
  - 不修改 /etc/sysctl.conf 和其他人的 sysctl/firewall 配置
  - 0 重传无法由单机保证，校准只保留测试证明有效的最高低重传速率
EOF
}

main() {
    local command="${1:-apply}"
    case "$command" in
        apply)
            check_root
            bbr_configure_direct
            ;;
        restore)
            check_root
            restore_bbr_direct
            ;;
        status)
            check_bbr_status
            ;;
        files)
            show_generated_files
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
