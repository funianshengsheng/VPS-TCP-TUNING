#!/usr/bin/env bash
# VPS BBR / TCP 调优：高吞吐优先，以低重传为约束。
# 适用于用户态代理、Web 服务及 IPv4/IPv6 内核转发场景。

set -o pipefail

SCRIPT_VERSION="standalone-6.0.0"
STATE_VERSION="1"

SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
MODULES_CONF="/etc/modules-load.d/99-bbr-direct-tune.conf"
PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"
SYSTEMD_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
OPENRC_START="/etc/local.d/bbr-optimize.start"

STATE_DIR="/var/lib/bbr-direct-tune"
STATE_MARKER="$STATE_DIR/snapshot.version"
META_STATE="$STATE_DIR/meta.tsv"
SYSCTL_STATE="$STATE_DIR/sysctl.tsv"
QDISC_STATE="$STATE_DIR/qdisc.tsv"
QDISC_MODIFIED_STATE="$STATE_DIR/qdisc-modified.list"
RPS_STATE="$STATE_DIR/rps.tsv"
FILES_STATE="$STATE_DIR/files.tsv"
FILES_BACKUP_DIR="$STATE_DIR/file-backups"
RUNTIME_CONFIG="$STATE_DIR/runtime.conf"

AUTO_MODE="${AUTO_MODE:-0}"
RETRANS_TARGET_PPM="${RETRANS_TARGET_PPM:-2000}"
SKIP_CALIBRATION="${SKIP_CALIBRATION:-0}"

RUNTIME_TMP_DIR=""
SYSCTL_PLAN=""
SPEEDTEST_BIN=""
SPEEDTEST_SERVER_ID="${SPEEDTEST_SERVER_ID:-}"
SPEEDTEST_SERVER_LABEL=""

PRIMARY_IFACE=""
DETECTED_DOWNLOAD_MBIT=0
DETECTED_UPLOAD_MBIT=0
DETECTED_BANDWIDTH_MBIT=0
DETECTED_RTT_MS=0
BUFFER_BYTES=0

FORWARD_IPV4=0
FORWARD_IPV6=0
IPV6_RA_REQUIRED=0
NF_CONNTRACK_MAX=0

QDISC_ORIGINAL_ROOT=""
QDISC_MODE="skip"
QDISC_PARENTS=""
SHAPE_RATE_MBIT=0

RPS_ENABLED=0
RPS_MASK=""
RPS_FLOW_ENTRIES=0

CALIBRATION_ACTIVE=0
CALIBRATION_IFACE=""

MEASURE_DOWNLOAD_MBIT=0
MEASURE_UPLOAD_MBIT=0
MEASURE_RTT_MS=0
MEASURE_RETRANS_PPM=-1
MEASURE_OUT_SEGS=0
MEASURE_RETRANS_SEGS=0
MEASURE_SOFTNET_DROPS=0
MEASURE_QDISC_DROPS=0

gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'
gl_zi='\033[35m'

cleanup_runtime() {
    if [ "$CALIBRATION_ACTIVE" = "1" ] && [ -n "$CALIBRATION_IFACE" ]; then
        restore_qdisc_from_snapshot "$CALIBRATION_IFACE" >/dev/null 2>&1 || true
        CALIBRATION_ACTIVE=0
    fi

    if [ -n "$RUNTIME_TMP_DIR" ]; then
        case "$RUNTIME_TMP_DIR" in
            /tmp/bbr-direct-tune.*)
                rm -rf -- "$RUNTIME_TMP_DIR"
                ;;
        esac
        RUNTIME_TMP_DIR=""
    fi
}

trap cleanup_runtime EXIT
trap 'exit 130' INT HUP TERM

log_info() {
    echo -e "${gl_kjlan}$*${gl_bai}"
}

log_ok() {
    echo -e "${gl_lv}$*${gl_bai}"
}

log_warn() {
    echo -e "${gl_huang}$*${gl_bai}" >&2
}

log_error() {
    echo -e "${gl_hong}$*${gl_bai}" >&2
}

check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "错误：此操作需要 root 权限。"
        echo "请使用：sudo bash $0 $*" >&2
        exit 1
    fi
}

ensure_runtime_tmp() {
    [ -n "$RUNTIME_TMP_DIR" ] && return 0

    umask 077
    RUNTIME_TMP_DIR=$(mktemp -d /tmp/bbr-direct-tune.XXXXXX) || {
        log_error "无法创建临时目录。"
        return 1
    }
    SYSCTL_PLAN="$RUNTIME_TMP_DIR/sysctl-plan.tsv"
    : > "$SYSCTL_PLAN"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_positive_number() {
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'
}

round_positive_number() {
    awk -v value="$1" 'BEGIN { rounded=int(value + 0.5); print rounded < 1 ? 1 : rounded }'
}

max_int() {
    if [ "$1" -ge "$2" ]; then
        echo "$1"
    else
        echo "$2"
    fi
}

prompt_yes_no() {
    local prompt_text="$1"
    local default_answer="$2"
    local answer

    if [ "$AUTO_MODE" = "1" ]; then
        [ "$default_answer" = "Y" ]
        return
    fi

    read -r -e -p "$prompt_text" answer
    answer=${answer:-$default_answer}
    case "$answer" in
        [Yy]) return 0 ;;
        *) return 1 ;;
    esac
}

download_to() {
    local url="$1"
    local destination="$2"

    if command_exists curl; then
        curl -fsSL --retry 2 --connect-timeout 10 "$url" -o "$destination"
    elif command_exists wget; then
        wget -q -T 15 -t 2 "$url" -O "$destination"
    else
        log_error "未找到 curl 或 wget，无法临时下载 Speedtest。"
        return 1
    fi
}

verify_sha256() {
    local file_path="$1"
    local expected_hash="$2"
    local actual_hash=""

    if command_exists sha256sum; then
        actual_hash=$(sha256sum "$file_path" | awk '{print $1}')
    elif command_exists shasum; then
        actual_hash=$(shasum -a 256 "$file_path" | awk '{print $1}')
    elif command_exists openssl; then
        actual_hash=$(openssl dgst -sha256 "$file_path" | awk '{print $NF}')
    else
        log_error "系统缺少 SHA-256 校验工具，拒绝运行未校验的下载文件。"
        return 1
    fi

    if [ "$actual_hash" != "$expected_hash" ]; then
        log_error "Speedtest 安装包 SHA-256 校验失败。"
        return 1
    fi
}

is_ookla_speedtest() {
    local binary_path="$1"
    "$binary_path" --version 2>&1 | grep -qi 'Ookla'
}

ensure_speedtest() {
    local cpu_arch
    local package_arch
    local expected_hash
    local download_url
    local archive_path

    if [ -n "$SPEEDTEST_BIN" ] && [ -x "$SPEEDTEST_BIN" ]; then
        return 0
    fi

    if command_exists speedtest && is_ookla_speedtest "$(command -v speedtest)"; then
        SPEEDTEST_BIN=$(command -v speedtest)
        return 0
    fi

    ensure_runtime_tmp || return 1
    cpu_arch=$(uname -m)

    case "$cpu_arch" in
        x86_64|amd64)
            package_arch="x86_64"
            expected_hash="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
            ;;
        aarch64|arm64)
            package_arch="aarch64"
            expected_hash="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
            ;;
        armv7l|armv7|armhf)
            package_arch="armhf"
            expected_hash="e45fcdebbd8a185553535533dd032d6b10bc8c64eee4139b1147b9c09835d08d"
            ;;
        i386|i486|i586|i686)
            package_arch="i386"
            expected_hash="9ff7e18dbae7ee0e03c66108445a2fb6ceea6c86f66482e1392f55881b772fe8"
            ;;
        *)
            log_error "暂不支持架构：$cpu_arch"
            return 1
            ;;
    esac

    archive_path="$RUNTIME_TMP_DIR/ookla-speedtest.tgz"
    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${package_arch}.tgz"
    log_info "临时下载 Ookla Speedtest 1.2.0（退出时自动清理）..."

    download_to "$download_url" "$archive_path" || return 1
    verify_sha256 "$archive_path" "$expected_hash" || return 1
    tar -xzf "$archive_path" -C "$RUNTIME_TMP_DIR" >/dev/null 2>&1 || {
        log_error "Speedtest 安装包解压失败。"
        return 1
    }

    if [ ! -f "$RUNTIME_TMP_DIR/speedtest" ]; then
        log_error "Speedtest 安装包内容异常。"
        return 1
    fi

    chmod 700 "$RUNTIME_TMP_DIR/speedtest"
    SPEEDTEST_BIN="$RUNTIME_TMP_DIR/speedtest"
}

extract_json_number() {
    local json_text="$1"
    local object_name="$2"
    local field_name="$3"

    printf '%s\n' "$json_text" | sed -n "s/.*\"${object_name}\"[[:space:]]*:[[:space:]]*{[^}]*\"${field_name}\"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p" | head -n 1
}

extract_json_string() {
    local json_text="$1"
    local object_name="$2"
    local field_name="$3"

    printf '%s\n' "$json_text" | sed -n "s/.*\"${object_name}\"[[:space:]]*:[[:space:]]*{[^}]*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

invoke_speedtest() {
    local timeout_seconds="$1"
    shift

    mkdir -p "$RUNTIME_TMP_DIR/home" "$RUNTIME_TMP_DIR/config" "$RUNTIME_TMP_DIR/cache"
    if command_exists timeout; then
        HOME="$RUNTIME_TMP_DIR/home" \
        XDG_CONFIG_HOME="$RUNTIME_TMP_DIR/config" \
        XDG_CACHE_HOME="$RUNTIME_TMP_DIR/cache" \
        TMPDIR="$RUNTIME_TMP_DIR" \
            timeout "$timeout_seconds" "$SPEEDTEST_BIN" "$@"
    else
        HOME="$RUNTIME_TMP_DIR/home" \
        XDG_CONFIG_HOME="$RUNTIME_TMP_DIR/config" \
        XDG_CACHE_HOME="$RUNTIME_TMP_DIR/cache" \
        TMPDIR="$RUNTIME_TMP_DIR" \
            "$SPEEDTEST_BIN" "$@"
    fi
}

run_speedtest_json() {
    local speedtest_error="$RUNTIME_TMP_DIR/speedtest.err"
    local speedtest_args=(--accept-license --accept-gdpr --format=json)

    [ -n "$SPEEDTEST_SERVER_ID" ] && speedtest_args+=("--server-id=$SPEEDTEST_SERVER_ID")
    invoke_speedtest 180 "${speedtest_args[@]}" 2>"$speedtest_error"
}

show_speedtest_servers() {
    invoke_speedtest 60 --accept-license --accept-gdpr --servers 2>/dev/null
}

parse_speedtest_json() {
    local json_text="$1"
    local download_bytes
    local upload_bytes
    local latency

    download_bytes=$(extract_json_number "$json_text" download bandwidth)
    upload_bytes=$(extract_json_number "$json_text" upload bandwidth)
    latency=$(extract_json_number "$json_text" ping latency)

    if ! is_positive_number "$download_bytes" || ! is_positive_number "$upload_bytes" || ! is_positive_number "$latency"; then
        return 1
    fi

    MEASURE_DOWNLOAD_MBIT=$(awk -v value="$download_bytes" 'BEGIN { result=int(value * 8 / 1000000 + 0.5); print result < 1 ? 1 : result }')
    MEASURE_UPLOAD_MBIT=$(awk -v value="$upload_bytes" 'BEGIN { result=int(value * 8 / 1000000 + 0.5); print result < 1 ? 1 : result }')
    MEASURE_RTT_MS=$(round_positive_number "$latency")
    SPEEDTEST_SERVER_LABEL=$(extract_json_string "$json_text" server name)
    return 0
}

run_profile_speedtest() {
    local output

    ensure_speedtest || return 1
    output=$(run_speedtest_json) || {
        [ -s "$RUNTIME_TMP_DIR/speedtest.err" ] && sed -n '1,3p' "$RUNTIME_TMP_DIR/speedtest.err" >&2
        return 1
    }
    parse_speedtest_json "$output"
}

read_manual_profile() {
    local bandwidth_input="${BANDWIDTH_MBIT:-}"
    local rtt_input="${RTT_MS:-}"

    if [ "$AUTO_MODE" = "1" ]; then
        if ! is_positive_number "$bandwidth_input" || ! is_positive_number "$rtt_input"; then
            log_warn "自动模式未提供有效的 BANDWIDTH_MBIT 和 RTT_MS，将跳过依赖链路画像的缓冲与整形校准。"
            return 1
        fi
    else
        while ! is_positive_number "$bandwidth_input"; do
            read -r -e -p "请输入代表性可用带宽（Mbps）: " bandwidth_input
        done
        while ! is_positive_number "$rtt_input"; do
            read -r -e -p "请输入代表性往返 RTT（ms）: " rtt_input
        done
    fi

    DETECTED_BANDWIDTH_MBIT=$(round_positive_number "$bandwidth_input")
    DETECTED_DOWNLOAD_MBIT=$DETECTED_BANDWIDTH_MBIT
    DETECTED_UPLOAD_MBIT=$DETECTED_BANDWIDTH_MBIT
    DETECTED_RTT_MS=$(round_positive_number "$rtt_input")
}

configure_link_profile() {
    local choice=""
    local representative_rtt="${RTT_MS:-}"

    if is_positive_number "${BANDWIDTH_MBIT:-}" && is_positive_number "${RTT_MS:-}"; then
        read_manual_profile
        return
    fi

    echo ""
    log_info "=== 链路带宽与 RTT ==="

    if [ "$AUTO_MODE" = "1" ]; then
        choice=1
    else
        echo "1. 自动 Speedtest（默认）"
        echo "2. 指定 Speedtest 服务器 ID"
        echo "3. 手工输入代表性带宽与 RTT"
        echo "4. 跳过链路画像（不计算缓冲、不做限速校准）"
        read -r -e -p "请选择 [1]: " choice
        choice=${choice:-1}
    fi

    case "$choice" in
        1)
            ;;
        2)
            if [ -z "$SPEEDTEST_SERVER_ID" ]; then
                ensure_speedtest || {
                    read_manual_profile
                    return
                }
                show_speedtest_servers | sed -n '1,20p'
                read -r -e -p "请输入服务器 ID: " SPEEDTEST_SERVER_ID
            fi
            if ! printf '%s' "$SPEEDTEST_SERVER_ID" | grep -Eq '^[0-9]+$'; then
                log_warn "服务器 ID 无效，改用自动选择。"
                SPEEDTEST_SERVER_ID=""
            fi
            ;;
        3)
            read_manual_profile
            return
            ;;
        4)
            log_warn "已跳过链路画像。脚本不会猜测 1Gbps，也不会据此放大 TCP 缓冲。"
            SKIP_CALIBRATION=1
            return
            ;;
        *)
            log_warn "无效选择，改用自动 Speedtest。"
            ;;
    esac

    log_info "正在执行 Speedtest..."
    if ! run_profile_speedtest; then
        log_warn "Speedtest 失败。"
        read_manual_profile || true
        return
    fi

    DETECTED_DOWNLOAD_MBIT=$MEASURE_DOWNLOAD_MBIT
    DETECTED_UPLOAD_MBIT=$MEASURE_UPLOAD_MBIT
    DETECTED_BANDWIDTH_MBIT=$(max_int "$MEASURE_DOWNLOAD_MBIT" "$MEASURE_UPLOAD_MBIT")
    DETECTED_RTT_MS=$MEASURE_RTT_MS

    echo "下载：${DETECTED_DOWNLOAD_MBIT} Mbps，上传：${DETECTED_UPLOAD_MBIT} Mbps，空闲延迟：${DETECTED_RTT_MS} ms"
    [ -n "$SPEEDTEST_SERVER_LABEL" ] && echo "测速服务器：$SPEEDTEST_SERVER_LABEL"

    if is_positive_number "${RTT_MS:-}"; then
        DETECTED_RTT_MS=$(round_positive_number "$RTT_MS")
        echo "采用环境变量指定的代表性 RTT：${DETECTED_RTT_MS} ms"
    elif [ "$AUTO_MODE" != "1" ]; then
        read -r -e -p "代表性 RTT（回车采用 ${DETECTED_RTT_MS} ms）: " representative_rtt
        if [ -n "$representative_rtt" ]; then
            if is_positive_number "$representative_rtt"; then
                DETECTED_RTT_MS=$(round_positive_number "$representative_rtt")
            else
                log_warn "RTT 输入无效，继续使用测速延迟。"
            fi
        fi
    fi
}

TCP_BBR_WAS_LOADED=0
FQ_AVAILABLE=0

detect_primary_iface() {
    if ! command_exists ip; then
        log_error "缺少 iproute2 的 ip 命令。"
        return 1
    fi

    PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for (field_no=1; field_no<=NF; field_no++) if ($field_no == "dev") {print $(field_no+1); exit}}')
    if [ -z "$PRIMARY_IFACE" ]; then
        PRIMARY_IFACE=$(ip -6 route show default 2>/dev/null | awk '{for (field_no=1; field_no<=NF; field_no++) if ($field_no == "dev") {print $(field_no+1); exit}}')
    fi
    if [ -z "$PRIMARY_IFACE" ]; then
        PRIMARY_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (field_no=1; field_no<=NF; field_no++) if ($field_no == "dev") {print $(field_no+1); exit}}')
    fi

    if [ -z "$PRIMARY_IFACE" ] || [ ! -d "/sys/class/net/$PRIMARY_IFACE" ]; then
        log_error "无法识别默认出口网卡。"
        return 1
    fi

    echo "默认出口网卡：$PRIMARY_IFACE"
}

sysctl_path() {
    local key="$1"
    printf '/proc/sys/%s\n' "${key//./\/}"
}

sysctl_exists() {
    [ -e "$(sysctl_path "$1")" ]
}

sysctl_get() {
    sysctl -n "$1" 2>/dev/null
}

env_is_true() {
    case "$1" in
        1|Y|y|yes|YES|true|TRUE|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

configure_forwarding() {
    local current_ipv4=0
    local current_ipv6=0
    local default_answer

    sysctl_exists net.ipv4.ip_forward && current_ipv4=$(sysctl_get net.ipv4.ip_forward)
    sysctl_exists net.ipv6.conf.all.forwarding && current_ipv6=$(sysctl_get net.ipv6.conf.all.forwarding)

    if [ -n "${ENABLE_IPV4_FORWARD:-}" ]; then
        env_is_true "$ENABLE_IPV4_FORWARD" && FORWARD_IPV4=1
    elif [ "$AUTO_MODE" = "1" ]; then
        [ "$current_ipv4" = "1" ] && FORWARD_IPV4=1
    else
        default_answer=N
        [ "$current_ipv4" = "1" ] && default_answer=Y
        if prompt_yes_no "启用/保持 IPv4 内核转发并应用配套优化？(Y/N) [$default_answer]: " "$default_answer"; then
            FORWARD_IPV4=1
        fi
    fi

    if sysctl_exists net.ipv6.conf.all.forwarding; then
        if [ -n "${ENABLE_IPV6_FORWARD:-}" ]; then
            env_is_true "$ENABLE_IPV6_FORWARD" && FORWARD_IPV6=1
        elif [ "$AUTO_MODE" = "1" ]; then
            [ "$current_ipv6" = "1" ] && FORWARD_IPV6=1
        else
            default_answer=N
            [ "$current_ipv6" = "1" ] && default_answer=Y
            if prompt_yes_no "启用/保持 IPv6 内核转发并应用配套优化？(Y/N) [$default_answer]: " "$default_answer"; then
                FORWARD_IPV6=1
            fi
        fi
    fi

    if [ "$FORWARD_IPV6" = "1" ] && command_exists ip && \
       ip -6 route show default 2>/dev/null | grep -q 'proto ra'; then
        IPV6_RA_REQUIRED=1
        log_warn "IPv6 默认路由来自 RA，将保留转发模式下的 RA 接收能力，避免重启后丢失默认路由。"
    fi
}

get_memory_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

calculate_buffer_size() {
    local memory_kb
    local memory_cap
    local target_bytes
    local current_value
    local tcp_rmem
    local tcp_wmem
    local current_max=0
    local min_bytes=$((4 * 1024 * 1024))
    local min_cap=$((16 * 1024 * 1024))
    local max_cap=$((256 * 1024 * 1024))

    if [ "$DETECTED_BANDWIDTH_MBIT" -le 0 ] || [ "$DETECTED_RTT_MS" -le 0 ]; then
        BUFFER_BYTES=0
        return
    fi

    memory_kb=$(get_memory_kb)
    [ -n "$memory_kb" ] || memory_kb=524288
    memory_cap=$((memory_kb * 1024 / 16))
    [ "$memory_cap" -lt "$min_cap" ] && memory_cap=$min_cap
    [ "$memory_cap" -gt "$max_cap" ] && memory_cap=$max_cap

    # 1 Mbps × 1 ms 的单程 BDP 为 125 字节，此处使用约 2 × BDP。
    target_bytes=$((DETECTED_BANDWIDTH_MBIT * DETECTED_RTT_MS * 250))
    target_bytes=$((((target_bytes + 1048575) / 1048576) * 1048576))
    [ "$target_bytes" -lt "$min_bytes" ] && target_bytes=$min_bytes
    [ "$target_bytes" -gt "$memory_cap" ] && target_bytes=$memory_cap

    for current_value in \
        "$(sysctl_get net.core.rmem_max)" \
        "$(sysctl_get net.core.wmem_max)"; do
        case "$current_value" in
            ''|*[!0-9]*) ;;
            *) [ "$current_value" -gt "$current_max" ] && current_max=$current_value ;;
        esac
    done

    tcp_rmem=$(sysctl_get net.ipv4.tcp_rmem)
    tcp_wmem=$(sysctl_get net.ipv4.tcp_wmem)
    current_value=$(printf '%s\n' "$tcp_rmem" | awk '{print $3}')
    case "$current_value" in
        ''|*[!0-9]*) ;;
        *) [ "$current_value" -gt "$current_max" ] && current_max=$current_value ;;
    esac
    current_value=$(printf '%s\n' "$tcp_wmem" | awk '{print $3}')
    case "$current_value" in
        ''|*[!0-9]*) ;;
        *) [ "$current_value" -gt "$current_max" ] && current_max=$current_value ;;
    esac

    # 不降低用户原有上限，即使它高于本脚本的内存安全上限。
    [ "$current_max" -gt "$target_bytes" ] && target_bytes=$current_max
    BUFFER_BYTES=$target_bytes
    echo "TCP autotuning 最大缓冲：$((BUFFER_BYTES / 1024 / 1024)) MiB（约 2 × BDP，保留原有更高值）"
}

build_cpu_mask() {
    local cpu_count="$1"
    local group_count
    local remaining_bits
    local group_index
    local group_mask
    local result=""

    [ "$cpu_count" -gt 64 ] && cpu_count=64
    group_count=$(((cpu_count + 31) / 32))
    remaining_bits=$((cpu_count % 32))

    for ((group_index=group_count; group_index>=1; group_index--)); do
        if [ "$group_index" -eq "$group_count" ] && [ "$remaining_bits" -ne 0 ]; then
            group_mask=$(printf '%08x' "$(((1 << remaining_bits) - 1))")
        else
            group_mask="ffffffff"
        fi
        if [ -n "$result" ]; then
            result="$result,$group_mask"
        else
            result="$group_mask"
        fi
    done

    printf '%s\n' "$result"
}

plan_rps() {
    local queue_count=0
    local queue_path
    local cpu_count
    local current_mask
    local memory_kb

    RPS_ENABLED=0
    RPS_MASK=""
    RPS_FLOW_ENTRIES=0

    for queue_path in "/sys/class/net/$PRIMARY_IFACE/queues"/rx-*; do
        [ -d "$queue_path" ] && queue_count=$((queue_count + 1))
    done

    command_exists getconf && cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    if [ -z "$cpu_count" ] && command_exists nproc; then
        cpu_count=$(nproc 2>/dev/null)
    fi
    cpu_count=${cpu_count:-1}

    if [ "$queue_count" -ne 1 ] || [ "$cpu_count" -le 1 ] || [ "$DETECTED_BANDWIDTH_MBIT" -lt 1000 ]; then
        return
    fi

    queue_path="/sys/class/net/$PRIMARY_IFACE/queues/rx-0/rps_cpus"
    [ -r "$queue_path" ] || return
    current_mask=$(tr -d ',0[:space:]' < "$queue_path")
    if [ -n "$current_mask" ]; then
        log_warn "检测到已有自定义 RPS CPU mask，保持不变。"
        return
    fi

    RPS_MASK=$(build_cpu_mask "$cpu_count")
    memory_kb=$(get_memory_kb)
    if [ "${memory_kb:-0}" -ge 1048576 ]; then
        RPS_FLOW_ENTRIES=32768
    else
        RPS_FLOW_ENTRIES=8192
    fi
    RPS_ENABLED=1
    echo "单 RX 队列且带宽 ≥ 1Gbps：启用一次性 RPS/RFS 配置，CPU mask=$RPS_MASK"
}

calculate_conntrack_limit() {
    local memory_kb
    local desired
    local current

    NF_CONNTRACK_MAX=0
    if [ "$FORWARD_IPV4" != "1" ] && [ "$FORWARD_IPV6" != "1" ]; then
        return
    fi
    if ! sysctl_exists net.netfilter.nf_conntrack_max; then
        log_warn "未发现 nf_conntrack_max；不主动加载 conntrack，仅跳过容量调整。"
        return
    fi

    memory_kb=$(get_memory_kb)
    desired=$((${memory_kb:-524288} / 8))
    [ "$desired" -lt 65536 ] && desired=65536
    [ "$desired" -gt 1048576 ] && desired=1048576
    current=$(sysctl_get net.netfilter.nf_conntrack_max)
    case "$current" in
        ''|*[!0-9]*) current=0 ;;
    esac
    [ "$current" -gt "$desired" ] && desired=$current
    NF_CONNTRACK_MAX=$desired
}

check_bbr_support() {
    local available

    [ -d /sys/module/tcp_bbr ] && TCP_BBR_WAS_LOADED=1
    if command_exists modprobe; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
    fi

    available=$(sysctl_get net.ipv4.tcp_available_congestion_control)
    if ! printf ' %s ' "$available" | grep -q ' bbr '; then
        log_error "当前内核未提供 BBR。请先安装/切换支持 BBR 的内核。"
        return 1
    fi

    if command_exists tc && tc qdisc help 2>&1 | grep -q .; then
        FQ_AVAILABLE=1
    elif command_exists tc; then
        FQ_AVAILABLE=1
    fi
}

plan_sysctl() {
    local key="$1"
    local value="$2"

    sysctl_exists "$key" || return 0
    printf '%s\t%s\n' "$key" "$value" >> "$SYSCTL_PLAN"
}

plan_max_sysctl() {
    local key="$1"
    local desired="$2"
    local current

    sysctl_exists "$key" || return 0
    current=$(sysctl_get "$key")
    case "$current" in
        ''|*[!0-9]*) current=0 ;;
    esac
    [ "$current" -gt "$desired" ] && desired=$current
    plan_sysctl "$key" "$desired"
}

build_sysctl_plan() {
    local tcp_rmem
    local tcp_wmem
    local rmem_min
    local rmem_default
    local wmem_min
    local wmem_default
    local port_range
    local port_low
    local port_high
    local backlog_target=16384

    ensure_runtime_tmp || return 1
    : > "$SYSCTL_PLAN"

    plan_sysctl net.ipv4.tcp_congestion_control bbr
    [ "$FQ_AVAILABLE" = "1" ] && plan_sysctl net.core.default_qdisc fq

    plan_sysctl net.ipv4.tcp_window_scaling 1
    plan_sysctl net.ipv4.tcp_sack 1
    plan_sysctl net.ipv4.tcp_dsack 1
    plan_max_sysctl net.ipv4.tcp_syncookies 1
    plan_max_sysctl net.ipv4.tcp_mtu_probing 1

    plan_max_sysctl net.core.somaxconn 32768
    plan_max_sysctl net.ipv4.tcp_max_syn_backlog 32768
    [ "$DETECTED_BANDWIDTH_MBIT" -ge 1000 ] && backlog_target=32768
    [ "$DETECTED_BANDWIDTH_MBIT" -ge 10000 ] && backlog_target=65536
    plan_max_sysctl net.core.netdev_max_backlog "$backlog_target"

    port_range=$(sysctl_get net.ipv4.ip_local_port_range)
    port_low=$(printf '%s\n' "$port_range" | awk '{print $1}')
    port_high=$(printf '%s\n' "$port_range" | awk '{print $2}')
    case "$port_low" in ''|*[!0-9]*) port_low=10240 ;; esac
    case "$port_high" in ''|*[!0-9]*) port_high=65535 ;; esac
    [ "$port_low" -gt 10240 ] && port_low=10240
    [ "$port_high" -lt 65535 ] && port_high=65535
    plan_sysctl net.ipv4.ip_local_port_range "$port_low $port_high"

    if [ "$BUFFER_BYTES" -gt 0 ]; then
        plan_max_sysctl net.core.rmem_max "$BUFFER_BYTES"
        plan_max_sysctl net.core.wmem_max "$BUFFER_BYTES"

        tcp_rmem=$(sysctl_get net.ipv4.tcp_rmem)
        tcp_wmem=$(sysctl_get net.ipv4.tcp_wmem)
        rmem_min=$(printf '%s\n' "$tcp_rmem" | awk '{print $1}')
        rmem_default=$(printf '%s\n' "$tcp_rmem" | awk '{print $2}')
        wmem_min=$(printf '%s\n' "$tcp_wmem" | awk '{print $1}')
        wmem_default=$(printf '%s\n' "$tcp_wmem" | awk '{print $2}')
        rmem_min=${rmem_min:-4096}
        rmem_default=${rmem_default:-131072}
        wmem_min=${wmem_min:-4096}
        wmem_default=${wmem_default:-16384}
        plan_sysctl net.ipv4.tcp_rmem "$rmem_min $rmem_default $BUFFER_BYTES"
        plan_sysctl net.ipv4.tcp_wmem "$wmem_min $wmem_default $BUFFER_BYTES"
    fi

    if [ "$FORWARD_IPV4" = "1" ]; then
        plan_sysctl net.ipv4.ip_forward 1
        plan_sysctl net.ipv4.conf.all.rp_filter 2
        plan_sysctl net.ipv4.conf.default.rp_filter 2
        plan_sysctl net.ipv4.conf.all.send_redirects 0
        plan_sysctl net.ipv4.conf.default.send_redirects 0
        plan_sysctl net.ipv4.conf.all.accept_redirects 0
        plan_sysctl net.ipv4.conf.default.accept_redirects 0
    fi

    if [ "$FORWARD_IPV6" = "1" ]; then
        plan_sysctl net.ipv6.conf.all.forwarding 1
        plan_sysctl net.ipv6.conf.all.accept_redirects 0
        plan_sysctl net.ipv6.conf.default.accept_redirects 0
        if [ "$IPV6_RA_REQUIRED" = "1" ]; then
            plan_sysctl net.ipv6.conf.all.accept_ra 2
            plan_sysctl net.ipv6.conf.default.accept_ra 2
        fi
    fi

    [ "$NF_CONNTRACK_MAX" -gt 0 ] && plan_max_sysctl net.netfilter.nf_conntrack_max "$NF_CONNTRACK_MAX"
    [ "$RPS_ENABLED" = "1" ] && plan_max_sysctl net.core.rps_sock_flow_entries "$RPS_FLOW_ENTRIES"
}

write_sysctl_conf() {
    local temp_conf="$RUNTIME_TMP_DIR/99-bbr-ultimate.conf"
    local key
    local value

    {
        echo "# Managed by bbr-direct-tune.sh v$SCRIPT_VERSION"
        echo "# 高吞吐优先，以低重传为约束；默认 socket 缓冲保持系统原值。"
        while IFS=$'\t' read -r key value; do
            [ -n "$key" ] && printf '%s = %s\n' "$key" "$value"
        done < "$SYSCTL_PLAN"
    } > "$temp_conf"

    (umask 022; mkdir -p "$(dirname "$SYSCTL_CONF")")
    cp "$temp_conf" "$SYSCTL_CONF"
    chmod 644 "$SYSCTL_CONF"
}

write_modules_conf() {
    local temp_conf="$RUNTIME_TMP_DIR/99-bbr-direct-tune.conf"

    printf '%s\n' '# Managed by bbr-direct-tune.sh' 'tcp_bbr' > "$temp_conf"
    (umask 022; mkdir -p "$(dirname "$MODULES_CONF")")
    cp "$temp_conf" "$MODULES_CONF"
    chmod 644 "$MODULES_CONF"
}

apply_sysctl_plan() {
    if ! sysctl -p "$SYSCTL_CONF" >/dev/null; then
        log_error "部分 sysctl 参数应用失败；可立即执行 restore 回滚。"
        return 1
    fi
}

QDISC_RAW_DIR="$STATE_DIR/qdisc-raw"

meta_get() {
    local key="$1"
    [ -r "$META_STATE" ] || return 1
    awk -F '\t' -v target="$key" '$1 == target {print $2; exit}' "$META_STATE"
}

snapshot_managed_file() {
    local file_path="$1"
    local backup_name="$2"

    if [ -d "$file_path" ] && [ ! -L "$file_path" ]; then
        log_error "预期文件路径实际为目录，拒绝覆盖：$file_path"
        return 1
    fi

    if [ -e "$file_path" ] || [ -L "$file_path" ]; then
        cp -a -- "$file_path" "$FILES_BACKUP_DIR/$backup_name" || return 1
        printf '%s\t1\t%s\n' "$file_path" "$backup_name" >> "$FILES_STATE"
    else
        printf '%s\t0\t-\n' "$file_path" >> "$FILES_STATE"
    fi
}

snapshot_managed_files() {
    : > "$FILES_STATE"
    snapshot_managed_file "$SYSCTL_CONF" sysctl-conf || return 1
    snapshot_managed_file "$MODULES_CONF" modules-conf || return 1
    snapshot_managed_file "$PERSIST_SCRIPT" persist-script || return 1
    snapshot_managed_file "$SYSTEMD_SERVICE" systemd-service || return 1
    snapshot_managed_file "$OPENRC_START" openrc-start || return 1
}

sysctl_state_has_key() {
    local key="$1"
    [ -r "$SYSCTL_STATE" ] && awk -F '\t' -v target="$key" '$1 == target {found=1} END {exit !found}' "$SYSCTL_STATE"
}

extend_sysctl_snapshot() {
    local key
    local value

    touch "$SYSCTL_STATE"
    while IFS=$'\t' read -r key value; do
        [ -n "$key" ] || continue
        sysctl_state_has_key "$key" && continue
        value=$(sysctl_get "$key") || continue
        printf '%s\t%s\n' "$key" "$value" >> "$SYSCTL_STATE"
    done < "$SYSCTL_PLAN"
}

qdisc_state_has_iface() {
    local iface="$1"
    [ -r "$QDISC_STATE" ] && awk -F '\t' -v target="$iface" '$1 == target && $2 == "root" {found=1} END {exit !found}' "$QDISC_STATE"
}

snapshot_qdisc_for_iface() {
    local iface="$1"
    local qdisc_output
    local root_kind
    local root_handle
    local safe_name

    qdisc_state_has_iface "$iface" && return 0
    if ! command_exists tc; then
        printf '%s\troot\tunavailable\n' "$iface" >> "$QDISC_STATE"
        return 0
    fi

    qdisc_output=$(tc qdisc show dev "$iface" 2>/dev/null) || {
        printf '%s\troot\tunavailable\n' "$iface" >> "$QDISC_STATE"
        return 0
    }
    root_kind=$(printf '%s\n' "$qdisc_output" | awk '$1 == "qdisc" {for (field_no=1; field_no<=NF; field_no++) if ($field_no == "root") {print $2; exit}}')
    root_handle=$(printf '%s\n' "$qdisc_output" | awk '$1 == "qdisc" {for (field_no=1; field_no<=NF; field_no++) if ($field_no == "root") {print $3; exit}}')
    root_kind=${root_kind:-unknown}
    root_handle=${root_handle:-unknown}
    printf '%s\troot\t%s\t%s\n' "$iface" "$root_kind" "$root_handle" >> "$QDISC_STATE"

    if [ "$root_kind" = "mq" ]; then
        printf '%s\n' "$qdisc_output" | awk -v iface="$iface" '
            $1 == "qdisc" {
                parent=""
                for (field_no=1; field_no<=NF; field_no++) {
                    if ($field_no == "parent") parent=$(field_no+1)
                }
                if (parent != "" && parent !~ /^ffff:/) {
                    printf "%s\tleaf\t%s\t%s\t%s\n", iface, parent, $2, $3
                }
            }
        ' >> "$QDISC_STATE"
    fi

    safe_name=$(printf '%s' "$iface" | tr '/:' '__')
    printf '%s\n' "$qdisc_output" > "$QDISC_RAW_DIR/$safe_name.txt"
}

rps_state_has_path() {
    local target_path="$1"
    [ -r "$RPS_STATE" ] && awk -F '\t' -v target="$target_path" '$1 == target {found=1} END {exit !found}' "$RPS_STATE"
}

snapshot_rps_for_iface() {
    local iface="$1"
    local queue_path
    local setting_path
    local current_value

    touch "$RPS_STATE"
    for queue_path in "/sys/class/net/$iface/queues"/rx-*; do
        [ -d "$queue_path" ] || continue
        for setting_path in "$queue_path/rps_cpus" "$queue_path/rps_flow_cnt"; do
            [ -r "$setting_path" ] || continue
            rps_state_has_path "$setting_path" && continue
            current_value=$(cat "$setting_path")
            printf '%s\t%s\n' "$setting_path" "$current_value" >> "$RPS_STATE"
        done
    done
}

save_meta_state() {
    local systemd_enabled=0
    local systemd_active=0
    local openrc_local_enabled=0

    if command_exists systemctl && [ -d /run/systemd/system ]; then
        systemctl is-enabled bbr-optimize-persist.service >/dev/null 2>&1 && systemd_enabled=1
        systemctl is-active bbr-optimize-persist.service >/dev/null 2>&1 && systemd_active=1
    fi
    if command_exists rc-update; then
        rc-update show default 2>/dev/null | grep -qE '(^|[[:space:]])local([[:space:]]|$)' && openrc_local_enabled=1
    fi

    {
        printf 'primary_iface\t%s\n' "$PRIMARY_IFACE"
        printf 'tcp_bbr_loaded\t%s\n' "$TCP_BBR_WAS_LOADED"
        printf 'systemd_enabled\t%s\n' "$systemd_enabled"
        printf 'systemd_active\t%s\n' "$systemd_active"
        printf 'openrc_local_enabled\t%s\n' "$openrc_local_enabled"
    } > "$META_STATE"
}

save_original_state() {
    local saved_version

    if [ -L "$STATE_DIR" ]; then
        log_error "状态目录不能是符号链接：$STATE_DIR"
        return 1
    fi

    if [ -f "$STATE_MARKER" ]; then
        saved_version=$(cat "$STATE_MARKER" 2>/dev/null)
        if [ "$saved_version" != "$STATE_VERSION" ]; then
            log_error "状态快照版本不兼容：$saved_version"
            return 1
        fi
        extend_sysctl_snapshot
        snapshot_qdisc_for_iface "$PRIMARY_IFACE"
        snapshot_rps_for_iface "$PRIMARY_IFACE"
        log_info "复用首次应用前的原始快照，不覆盖原值。"
        return 0
    fi

    if [ -d "$STATE_DIR" ]; then
        if find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            log_error "发现无有效快照标记的非空状态目录：$STATE_DIR"
            log_error "为避免误删数据，请先人工检查并处理该目录。"
            return 1
        fi
    elif ! mkdir -p "$STATE_DIR"; then
        return 1
    fi

    mkdir -p "$FILES_BACKUP_DIR" "$QDISC_RAW_DIR" || return 1
    chmod 700 "$STATE_DIR" "$FILES_BACKUP_DIR" "$QDISC_RAW_DIR"
    : > "$SYSCTL_STATE"
    : > "$QDISC_STATE"
    : > "$QDISC_MODIFIED_STATE"
    : > "$RPS_STATE"

    save_meta_state || return 1
    snapshot_managed_files || return 1
    extend_sysctl_snapshot || return 1
    snapshot_qdisc_for_iface "$PRIMARY_IFACE" || return 1
    snapshot_rps_for_iface "$PRIMARY_IFACE" || return 1
    printf '%s\n' "$STATE_VERSION" > "$STATE_MARKER"
    log_ok "已保存首次应用前的系统调优快照：$STATE_DIR"
}

inspect_original_qdisc() {
    local leaf_kind
    local leaf_handle
    local root_handle
    local leaf_count=0

    QDISC_ORIGINAL_ROOT=$(awk -F '\t' -v iface="$PRIMARY_IFACE" '$1 == iface && $2 == "root" {print $3; exit}' "$QDISC_STATE")
    root_handle=$(awk -F '\t' -v iface="$PRIMARY_IFACE" '$1 == iface && $2 == "root" {print $4; exit}' "$QDISC_STATE")
    QDISC_MODE="skip"
    QDISC_PARENTS=""

    if [ "$root_handle" != "0:" ]; then
        log_warn "root qdisc 使用非默认句柄 ${root_handle:-未知}，视为用户自定义并保持现状。"
        return
    fi

    case "$QDISC_ORIGINAL_ROOT" in
        fq|fq_codel|pfifo_fast|noqueue)
            QDISC_MODE="fq-root"
            ;;
        mq)
            while IFS=$'\t' read -r iface record_type parent leaf_kind leaf_handle; do
                [ "$iface" = "$PRIMARY_IFACE" ] || continue
                [ "$record_type" = "leaf" ] || continue
                leaf_count=$((leaf_count + 1))
                if [ "$leaf_handle" != "0:" ]; then
                    log_warn "mq 下存在非默认叶子句柄 $leaf_handle，保持现状。"
                    QDISC_MODE="skip"
                    return
                fi
                case "$leaf_kind" in
                    fq|fq_codel|pfifo_fast|noqueue) ;;
                    *)
                        log_warn "mq 下存在自定义叶子 qdisc：$leaf_kind，保持现状。"
                        QDISC_MODE="skip"
                        return
                        ;;
                esac
                QDISC_PARENTS="$QDISC_PARENTS $parent"
            done < "$QDISC_STATE"
            if [ "$leaf_count" -gt 0 ]; then
                QDISC_MODE="fq-mq"
                QDISC_PARENTS=${QDISC_PARENTS# }
            fi
            ;;
        *)
            log_warn "检测到既有自定义 qdisc：${QDISC_ORIGINAL_ROOT:-未知}，不覆盖它，也不做 HTB 校准。"
            ;;
    esac
}

record_qdisc_modified() {
    local iface="$1"
    grep -Fxq "$iface" "$QDISC_MODIFIED_STATE" 2>/dev/null || printf '%s\n' "$iface" >> "$QDISC_MODIFIED_STATE"
}

restore_qdisc_from_snapshot() {
    local iface="$1"
    local root_kind
    local state_iface
    local record_type
    local parent
    local leaf_kind
    local leaf_handle
    local failed=0

    command_exists tc || return 1
    [ -r "$QDISC_STATE" ] || return 1
    root_kind=$(awk -F '\t' -v target="$iface" '$1 == target && $2 == "root" {print $3; exit}' "$QDISC_STATE")

    case "$root_kind" in
        noqueue)
            tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
            ;;
        fq|fq_codel|pfifo_fast)
            tc qdisc replace dev "$iface" root "$root_kind" >/dev/null 2>&1 || failed=1
            ;;
        mq)
            tc qdisc replace dev "$iface" root mq >/dev/null 2>&1 || failed=1
            if [ "$failed" = "0" ]; then
                while IFS=$'\t' read -r state_iface record_type parent leaf_kind leaf_handle; do
                    [ "$state_iface" = "$iface" ] || continue
                    [ "$record_type" = "leaf" ] || continue
                    if [ "$leaf_kind" = "noqueue" ]; then
                        tc qdisc del dev "$iface" parent "$parent" >/dev/null 2>&1 || true
                    else
                        tc qdisc replace dev "$iface" parent "$parent" "$leaf_kind" >/dev/null 2>&1 || failed=1
                    fi
                done < "$QDISC_STATE"
            fi
            ;;
        *)
            return 1
            ;;
    esac

    [ "$failed" = "0" ]
}

restore_rps_state() {
    local setting_path
    local original_value
    local failed=0

    [ -r "$RPS_STATE" ] || return 0
    while IFS=$'\t' read -r setting_path original_value; do
        [ -n "$setting_path" ] || continue
        if [ -w "$setting_path" ]; then
            printf '%s' "$original_value" > "$setting_path" 2>/dev/null || failed=1
        else
            failed=1
        fi
    done < "$RPS_STATE"
    [ "$failed" = "0" ]
}

restore_sysctl_state() {
    local key
    local original_value
    local failed=0

    [ -r "$SYSCTL_STATE" ] || return 1
    while IFS=$'\t' read -r key original_value; do
        [ -n "$key" ] || continue
        if sysctl_exists "$key"; then
            sysctl -w "$key=$original_value" >/dev/null 2>&1 || failed=1
        fi
    done < "$SYSCTL_STATE"
    [ "$failed" = "0" ]
}

restore_managed_files() {
    local file_path
    local existed
    local backup_name
    local failed=0

    [ -r "$FILES_STATE" ] || return 1
    while IFS=$'\t' read -r file_path existed backup_name; do
        [ -n "$file_path" ] || continue
        if [ -d "$file_path" ] && [ ! -L "$file_path" ]; then
            log_error "恢复目标变成目录，拒绝删除：$file_path"
            failed=1
            continue
        fi
        rm -f -- "$file_path" || {
            failed=1
            continue
        }
        if [ "$existed" = "1" ]; then
            (umask 022; mkdir -p "$(dirname "$file_path")")
            cp -a -- "$FILES_BACKUP_DIR/$backup_name" "$file_path" || failed=1
        fi
    done < "$FILES_STATE"
    [ "$failed" = "0" ]
}

current_root_qdisc() {
    tc qdisc show dev "$1" 2>/dev/null | awk '$1 == "qdisc" {for (field_no=1; field_no<=NF; field_no++) if ($field_no == "root") {print $2; exit}}'
}

apply_unshaped_qdisc() {
    local current_root
    local parent
    local failed=0

    [ "$QDISC_MODE" != "skip" ] || return 0
    command_exists tc || return 1
    command_exists modprobe && modprobe sch_fq >/dev/null 2>&1 || true

    case "$QDISC_MODE" in
        fq-root)
            tc qdisc replace dev "$PRIMARY_IFACE" root fq >/dev/null 2>&1 || failed=1
            ;;
        fq-mq)
            current_root=$(current_root_qdisc "$PRIMARY_IFACE")
            if [ "$current_root" != "mq" ]; then
                tc qdisc replace dev "$PRIMARY_IFACE" root mq >/dev/null 2>&1 || failed=1
            fi
            if [ "$failed" = "0" ]; then
                for parent in $QDISC_PARENTS; do
                    tc qdisc replace dev "$PRIMARY_IFACE" parent "$parent" fq >/dev/null 2>&1 || failed=1
                done
            fi
            ;;
        *)
            return 1
            ;;
    esac

    if [ "$failed" != "0" ]; then
        restore_qdisc_from_snapshot "$PRIMARY_IFACE" >/dev/null 2>&1 || true
        log_warn "当前网卡不接受安全的 fq 配置，已恢复原 qdisc 并跳过整形。"
        QDISC_MODE="skip"
        return 1
    fi

    record_qdisc_modified "$PRIMARY_IFACE"
}

shape_burst_kb() {
    local rate_mbit="$1"
    local burst_kb=$((rate_mbit / 4))

    [ "$burst_kb" -lt 32 ] && burst_kb=32
    [ "$burst_kb" -gt 1024 ] && burst_kb=1024
    echo "$burst_kb"
}

apply_shaping_qdisc() {
    local rate_mbit="$1"
    local burst_kb

    [ "$QDISC_MODE" != "skip" ] || return 1
    [ "$rate_mbit" -gt 0 ] || return 1
    command_exists tc || return 1
    command_exists modprobe && {
        modprobe sch_htb >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
    }

    burst_kb=$(shape_burst_kb "$rate_mbit")
    tc qdisc replace dev "$PRIMARY_IFACE" root handle 1: htb default 10 >/dev/null 2>&1 || return 1
    tc class replace dev "$PRIMARY_IFACE" parent 1: classid 1:10 htb \
        rate "${rate_mbit}mbit" ceil "${rate_mbit}mbit" \
        burst "${burst_kb}k" cburst "${burst_kb}k" >/dev/null 2>&1 || {
        apply_unshaped_qdisc >/dev/null 2>&1 || true
        return 1
    }
    tc qdisc replace dev "$PRIMARY_IFACE" parent 1:10 handle 10: fq >/dev/null 2>&1 || {
        apply_unshaped_qdisc >/dev/null 2>&1 || true
        return 1
    }
    record_qdisc_modified "$PRIMARY_IFACE"
}

apply_rps_now() {
    local queue_path
    local failed=0

    [ "$RPS_ENABLED" = "1" ] || return 0
    for queue_path in "/sys/class/net/$PRIMARY_IFACE/queues"/rx-*; do
        [ -d "$queue_path" ] || continue
        if [ -w "$queue_path/rps_cpus" ]; then
            printf '%s' "$RPS_MASK" > "$queue_path/rps_cpus" 2>/dev/null || failed=1
        fi
        if [ -w "$queue_path/rps_flow_cnt" ]; then
            printf '%s' "$RPS_FLOW_ENTRIES" > "$queue_path/rps_flow_cnt" 2>/dev/null || failed=1
        fi
    done

    if [ "$failed" != "0" ]; then
        restore_rps_state >/dev/null 2>&1 || true
        RPS_ENABLED=0
        log_warn "RPS/RFS 写入失败，已恢复原值并跳过。"
        return 1
    fi
}

read_tcp_counters() {
    awk '
        $1 == "Tcp:" && !header_seen {
            for (field_no=2; field_no<=NF; field_no++) field_index[$field_no]=field_no
            header_seen=1
            next
        }
        $1 == "Tcp:" && header_seen {
            print $(field_index["OutSegs"]), $(field_index["RetransSegs"])
            exit
        }
    ' /proc/net/snmp 2>/dev/null
}

read_softnet_drops() {
    local processed
    local dropped
    local remainder
    local total=0

    while read -r processed dropped remainder; do
        [ -n "$dropped" ] || continue
        total=$((total + 16#$dropped))
    done < /proc/net/softnet_stat
    echo "$total"
}

read_qdisc_drops() {
    if ! command_exists tc; then
        echo 0
        return
    fi

    tc -s qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | awk '
        {
            for (field_no=1; field_no<=NF; field_no++) {
                if ($field_no == "(dropped") {
                    value=$(field_no+1)
                    gsub(/,/, "", value)
                    total += value
                }
            }
        }
        END {print total + 0}
    '
}

run_calibration_measurement() {
    local before_tcp
    local after_tcp
    local before_out
    local before_retrans
    local after_out
    local after_retrans
    local before_softnet
    local after_softnet
    local before_qdisc
    local after_qdisc
    local speedtest_output

    before_tcp=$(read_tcp_counters)
    before_out=$(printf '%s\n' "$before_tcp" | awk '{print $1}')
    before_retrans=$(printf '%s\n' "$before_tcp" | awk '{print $2}')
    before_softnet=$(read_softnet_drops)
    before_qdisc=$(read_qdisc_drops)

    speedtest_output=$(run_speedtest_json) || {
        [ -s "$RUNTIME_TMP_DIR/speedtest.err" ] && sed -n '1,3p' "$RUNTIME_TMP_DIR/speedtest.err" >&2
        return 1
    }
    parse_speedtest_json "$speedtest_output" || return 1

    after_tcp=$(read_tcp_counters)
    after_out=$(printf '%s\n' "$after_tcp" | awk '{print $1}')
    after_retrans=$(printf '%s\n' "$after_tcp" | awk '{print $2}')
    after_softnet=$(read_softnet_drops)
    after_qdisc=$(read_qdisc_drops)

    MEASURE_OUT_SEGS=$((after_out - before_out))
    MEASURE_RETRANS_SEGS=$((after_retrans - before_retrans))
    MEASURE_SOFTNET_DROPS=$((after_softnet - before_softnet))
    MEASURE_QDISC_DROPS=$((after_qdisc - before_qdisc))
    [ "$MEASURE_OUT_SEGS" -lt 0 ] && MEASURE_OUT_SEGS=0
    [ "$MEASURE_RETRANS_SEGS" -lt 0 ] && MEASURE_RETRANS_SEGS=0
    [ "$MEASURE_SOFTNET_DROPS" -lt 0 ] && MEASURE_SOFTNET_DROPS=0
    [ "$MEASURE_QDISC_DROPS" -lt 0 ] && MEASURE_QDISC_DROPS=0

    if [ "$MEASURE_OUT_SEGS" -gt 0 ]; then
        MEASURE_RETRANS_PPM=$((MEASURE_RETRANS_SEGS * 1000000 / MEASURE_OUT_SEGS))
    else
        MEASURE_RETRANS_PPM=-1
    fi
}

format_retrans_percent() {
    local ppm="$1"
    if [ "$ppm" -lt 0 ]; then
        echo "未知"
    else
        awk -v value="$ppm" 'BEGIN {printf "%.4f%%", value / 10000}'
    fi
}

print_measurement() {
    local label="$1"

    printf '%s：上传 %s Mbps，下载 %s Mbps，重传 %s（%s/%s），softnet 丢包 %s，qdisc 丢包 %s\n' \
        "$label" "$MEASURE_UPLOAD_MBIT" "$MEASURE_DOWNLOAD_MBIT" \
        "$(format_retrans_percent "$MEASURE_RETRANS_PPM")" \
        "$MEASURE_RETRANS_SEGS" "$MEASURE_OUT_SEGS" \
        "$MEASURE_SOFTNET_DROPS" "$MEASURE_QDISC_DROPS"
}

calibrate_retransmissions() {
    local baseline_rate
    local candidate_percent
    local candidate_rate
    local minimum_expected
    local selected_rate=0
    local last_rate=0

    SHAPE_RATE_MBIT=0
    if [ "$SKIP_CALIBRATION" = "1" ]; then
        log_warn "已按 SKIP_CALIBRATION=1 跳过一次性重传校准。"
        return
    fi
    if ! printf '%s' "$RETRANS_TARGET_PPM" | grep -Eq '^[0-9]+$'; then
        RETRANS_TARGET_PPM=2000
    fi
    if ! ensure_speedtest; then
        log_warn "无法运行 Speedtest，保留不限速 fq 配置。"
        return
    fi

    echo ""
    log_info "=== 一次性低重传校准（目标 ≤ $(format_retrans_percent "$RETRANS_TARGET_PPM")） ==="
    log_warn "校准可能运行多轮 Speedtest，请确保当前业务负载较低且流量配额充足。"
    CALIBRATION_ACTIVE=1
    CALIBRATION_IFACE="$PRIMARY_IFACE"

    if [ "$QDISC_MODE" != "skip" ]; then
        apply_unshaped_qdisc >/dev/null 2>&1 || true
    fi
    sleep 1
    if ! run_calibration_measurement; then
        log_warn "基线测速失败，跳过整形。"
        [ "$QDISC_MODE" != "skip" ] && apply_unshaped_qdisc >/dev/null 2>&1 || true
        CALIBRATION_ACTIVE=0
        return
    fi
    print_measurement "不限速基线"

    if [ "$MEASURE_RETRANS_PPM" -ge 0 ] && [ "$MEASURE_RETRANS_PPM" -le "$RETRANS_TARGET_PPM" ]; then
        log_ok "不限速状态已达到低重传目标，不添加整机限速。"
        CALIBRATION_ACTIVE=0
        return
    fi

    if [ "$QDISC_MODE" = "skip" ]; then
        log_warn "既有 qdisc 不可无损覆盖，仅报告重传，不执行 HTB 校准。"
        CALIBRATION_ACTIVE=0
        return
    fi

    baseline_rate=$MEASURE_UPLOAD_MBIT
    if [ "$baseline_rate" -lt 20 ] || [ "$MEASURE_RETRANS_PPM" -lt 0 ]; then
        log_warn "基线样本不足，不依据不可靠数据限速。"
        apply_unshaped_qdisc >/dev/null 2>&1 || true
        CALIBRATION_ACTIVE=0
        return
    fi

    for candidate_percent in 98 95 92 90 85; do
        candidate_rate=$((baseline_rate * candidate_percent / 100))
        [ "$candidate_rate" -lt 1 ] && candidate_rate=1
        [ "$candidate_rate" -eq "$last_rate" ] && continue
        last_rate=$candidate_rate

        if ! apply_shaping_qdisc "$candidate_rate"; then
            log_warn "${candidate_rate} Mbps 整形应用失败，终止校准。"
            break
        fi
        sleep 1
        if ! run_calibration_measurement; then
            log_warn "${candidate_rate} Mbps 测试失败，终止校准。"
            break
        fi
        print_measurement "候选 ${candidate_percent}% / ${candidate_rate} Mbps"

        minimum_expected=$((candidate_rate * 75 / 100))
        if [ "$MEASURE_RETRANS_PPM" -ge 0 ] && \
           [ "$MEASURE_RETRANS_PPM" -le "$RETRANS_TARGET_PPM" ] && \
           [ "$MEASURE_UPLOAD_MBIT" -ge "$minimum_expected" ]; then
            selected_rate=$candidate_rate
            break
        fi
    done

    if [ "$selected_rate" -gt 0 ]; then
        if apply_shaping_qdisc "$selected_rate"; then
            SHAPE_RATE_MBIT=$selected_rate
            log_ok "选择满足重传目标的最高候选速率：${selected_rate} Mbps。"
        else
            apply_unshaped_qdisc >/dev/null 2>&1 || true
            log_warn "最终整形应用失败，已回到不限速 fq。"
        fi
    else
        apply_unshaped_qdisc >/dev/null 2>&1 || true
        log_warn "降速未能可靠达到目标，避免盲目牺牲吞吐，保留不限速 fq。"
    fi

    CALIBRATION_ACTIVE=0
}

write_runtime_config() {
    local active_qdisc_mode="$QDISC_MODE"
    local temp_config="$RUNTIME_TMP_DIR/runtime.conf"

    [ "$SHAPE_RATE_MBIT" -gt 0 ] && active_qdisc_mode="htb"
    {
        printf 'PRIMARY_IFACE=%q\n' "$PRIMARY_IFACE"
        printf 'ACTIVE_QDISC_MODE=%q\n' "$active_qdisc_mode"
        printf 'QDISC_PARENTS=%q\n' "$QDISC_PARENTS"
        printf 'SHAPE_RATE_MBIT=%q\n' "$SHAPE_RATE_MBIT"
        printf 'RPS_ENABLED=%q\n' "$RPS_ENABLED"
        printf 'RPS_MASK=%q\n' "$RPS_MASK"
        printf 'RPS_FLOW_ENTRIES=%q\n' "$RPS_FLOW_ENTRIES"
    } > "$temp_config"
    cp "$temp_config" "$RUNTIME_CONFIG"
    chmod 600 "$RUNTIME_CONFIG"
}

write_persist_script() {
    local temp_script="$RUNTIME_TMP_DIR/bbr-optimize-apply.sh"

    cat > "$temp_script" <<'PERSIST_EOF'
#!/usr/bin/env bash
# Managed by bbr-direct-tune.sh. 开机执行一次，执行完立即退出。

set -o pipefail

SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
RUNTIME_CONFIG="/var/lib/bbr-direct-tune/runtime.conf"

[ -r "$RUNTIME_CONFIG" ] || exit 0
# runtime.conf 由 root 创建且目录权限为 0700，不接收外部输入。
source "$RUNTIME_CONFIG"

[ -r "$SYSCTL_CONF" ] && sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true

shape_burst_kb() {
    local rate_mbit="$1"
    local burst_kb=$((rate_mbit / 4))
    [ "$burst_kb" -lt 32 ] && burst_kb=32
    [ "$burst_kb" -gt 1024 ] && burst_kb=1024
    echo "$burst_kb"
}

if command -v tc >/dev/null 2>&1 && [ -d "/sys/class/net/$PRIMARY_IFACE" ]; then
    case "$ACTIVE_QDISC_MODE" in
        fq-root)
            command -v modprobe >/dev/null 2>&1 && modprobe sch_fq >/dev/null 2>&1 || true
            tc qdisc replace dev "$PRIMARY_IFACE" root fq >/dev/null 2>&1 || true
            ;;
        fq-mq)
            command -v modprobe >/dev/null 2>&1 && modprobe sch_fq >/dev/null 2>&1 || true
            current_root=$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | awk '$1 == "qdisc" {for (field_no=1; field_no<=NF; field_no++) if ($field_no == "root") {print $2; exit}}')
            [ "$current_root" = "mq" ] || tc qdisc replace dev "$PRIMARY_IFACE" root mq >/dev/null 2>&1 || true
            for parent in $QDISC_PARENTS; do
                tc qdisc replace dev "$PRIMARY_IFACE" parent "$parent" fq >/dev/null 2>&1 || true
            done
            ;;
        htb)
            command -v modprobe >/dev/null 2>&1 && {
                modprobe sch_htb >/dev/null 2>&1 || true
                modprobe sch_fq >/dev/null 2>&1 || true
            }
            burst_kb=$(shape_burst_kb "$SHAPE_RATE_MBIT")
            tc qdisc replace dev "$PRIMARY_IFACE" root handle 1: htb default 10 >/dev/null 2>&1 && \
            tc class replace dev "$PRIMARY_IFACE" parent 1: classid 1:10 htb \
                rate "${SHAPE_RATE_MBIT}mbit" ceil "${SHAPE_RATE_MBIT}mbit" \
                burst "${burst_kb}k" cburst "${burst_kb}k" >/dev/null 2>&1 && \
            tc qdisc replace dev "$PRIMARY_IFACE" parent 1:10 handle 10: fq >/dev/null 2>&1 || true
            ;;
    esac
fi

if [ "$RPS_ENABLED" = "1" ]; then
    for queue_path in "/sys/class/net/$PRIMARY_IFACE/queues"/rx-*; do
        [ -d "$queue_path" ] || continue
        [ -w "$queue_path/rps_cpus" ] && printf '%s' "$RPS_MASK" > "$queue_path/rps_cpus" 2>/dev/null || true
        [ -w "$queue_path/rps_flow_cnt" ] && printf '%s' "$RPS_FLOW_ENTRIES" > "$queue_path/rps_flow_cnt" 2>/dev/null || true
    done
fi

exit 0
PERSIST_EOF

    (umask 022; mkdir -p "$(dirname "$PERSIST_SCRIPT")")
    cp "$temp_script" "$PERSIST_SCRIPT"
    chmod 700 "$PERSIST_SCRIPT"
    bash -n "$PERSIST_SCRIPT"
}

install_persistence() {
    local temp_service="$RUNTIME_TMP_DIR/bbr-optimize-persist.service"
    local temp_openrc="$RUNTIME_TMP_DIR/bbr-optimize.start"

    write_runtime_config || return 1
    write_persist_script || return 1

    if command_exists systemctl && [ -d /run/systemd/system ]; then
        systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
        cat > "$temp_service" <<'SYSTEMD_EOF'
[Unit]
Description=Apply BBR direct tuning once at boot
After=systemd-sysctl.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
        cp "$temp_service" "$SYSTEMD_SERVICE"
        chmod 644 "$SYSTEMD_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable bbr-optimize-persist.service >/dev/null 2>&1 || return 1
        systemctl start bbr-optimize-persist.service >/dev/null 2>&1 || return 1
        log_ok "已启用 systemd 开机一次性应用；执行后无常驻 PID。"
        return 0
    fi

    if command_exists rc-update; then
        cat > "$temp_openrc" <<'OPENRC_EOF'
#!/bin/sh
# Managed by bbr-direct-tune.sh
/usr/local/bin/bbr-optimize-apply.sh
OPENRC_EOF
        (umask 022; mkdir -p "$(dirname "$OPENRC_START")")
        cp "$temp_openrc" "$OPENRC_START"
        chmod 755 "$OPENRC_START"
        rc-update add local default >/dev/null 2>&1 || return 1
        "$PERSIST_SCRIPT" >/dev/null 2>&1 || return 1
        log_ok "已启用 OpenRC 开机一次性应用；执行后无常驻 PID。"
        return 0
    fi

    log_warn "未识别 systemd/OpenRC。当前参数已生效，但重启后需手工执行：$PERSIST_SCRIPT"
    return 0
}

restore_original_service_state() {
    local systemd_enabled
    local systemd_active
    local openrc_local_enabled
    local failed=0

    systemd_enabled=$(meta_get systemd_enabled || echo 0)
    systemd_active=$(meta_get systemd_active || echo 0)
    openrc_local_enabled=$(meta_get openrc_local_enabled || echo 0)

    if command_exists systemctl && [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || failed=1
        if [ "$systemd_enabled" = "1" ] && [ -f "$SYSTEMD_SERVICE" ]; then
            systemctl enable bbr-optimize-persist.service >/dev/null 2>&1 || failed=1
        else
            systemctl disable bbr-optimize-persist.service >/dev/null 2>&1 || true
        fi
        if [ "$systemd_active" = "1" ] && [ -f "$SYSTEMD_SERVICE" ]; then
            systemctl start bbr-optimize-persist.service >/dev/null 2>&1 || failed=1
        fi
    fi

    if command_exists rc-update; then
        if [ "$openrc_local_enabled" = "1" ]; then
            rc-update add local default >/dev/null 2>&1 || failed=1
        else
            rc-update del local default >/dev/null 2>&1 || failed=1
        fi
    fi

    [ "$failed" = "0" ]
}

restore_original_state() {
    local restore_confirm="${RESTORE_CONFIRM:-}"
    local modified_iface
    local failed=0
    local tcp_bbr_loaded

    if [ -L "$STATE_DIR" ]; then
        log_error "状态目录是符号链接，拒绝恢复：$STATE_DIR"
        return 1
    fi
    if [ ! -f "$STATE_MARKER" ]; then
        log_error "未找到首次应用前的状态快照，无法安全猜测原参数。"
        echo "状态目录应为：$STATE_DIR" >&2
        return 1
    fi

    echo "将恢复首次应用前保存的 sysctl、qdisc、RPS/RFS、转发状态及同名文件。"
    echo "恢复成功后会删除 $STATE_DIR 和本脚本生成的持久化文件。"
    if [ "$restore_confirm" != "YES" ]; then
        read -r -e -p "输入 YES 确认恢复: " restore_confirm
    fi
    if [ "$restore_confirm" != "YES" ]; then
        echo "已取消。"
        return 1
    fi

    command_exists systemctl && systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true

    restore_managed_files || failed=1
    command_exists systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
    restore_sysctl_state || failed=1

    if [ -r "$QDISC_MODIFIED_STATE" ]; then
        while IFS= read -r modified_iface; do
            [ -n "$modified_iface" ] || continue
            restore_qdisc_from_snapshot "$modified_iface" || failed=1
        done < "$QDISC_MODIFIED_STATE"
    fi
    restore_rps_state || failed=1
    restore_original_service_state || failed=1

    tcp_bbr_loaded=$(meta_get tcp_bbr_loaded || echo 1)
    if [ "$tcp_bbr_loaded" = "0" ] && command_exists modprobe; then
        modprobe -r tcp_bbr >/dev/null 2>&1 || true
    fi

    if [ "$failed" != "0" ]; then
        log_error "部分参数恢复失败，状态快照已保留，修复问题后可再次执行 restore。"
        return 1
    fi

    case "$STATE_DIR" in
        /var/lib/bbr-direct-tune) rm -rf -- "$STATE_DIR" ;;
        *) log_error "状态目录异常，拒绝删除。"; return 1 ;;
    esac
    log_ok "已恢复首次应用前的系统调优状态，并清理脚本生成的状态文件。"
}

show_status() {
    local iface
    local active_qdisc
    local active_cc
    local available_cc
    local runtime_shape=""

    active_cc=$(sysctl_get net.ipv4.tcp_congestion_control)
    available_cc=$(sysctl_get net.ipv4.tcp_available_congestion_control)
    if command_exists ip; then
        iface=$(ip -4 route show default 2>/dev/null | awk '{for (field_no=1; field_no<=NF; field_no++) if ($field_no == "dev") {print $(field_no+1); exit}}')
        [ -z "$iface" ] && iface=$(ip -6 route show default 2>/dev/null | awk '{for (field_no=1; field_no<=NF; field_no++) if ($field_no == "dev") {print $(field_no+1); exit}}')
    fi

    log_info "=== BBR / TCP 当前状态 ==="
    echo "拥塞控制：${active_cc:-未知}"
    echo "可用算法：${available_cc:-未知}"
    echo "BBR 代际：通用内核接口无法可靠区分 v1/v2/v3，本脚本不按内核版本猜测。"
    echo "默认 qdisc：$(sysctl_get net.core.default_qdisc)"
    echo "TCP rmem：$(sysctl_get net.ipv4.tcp_rmem)"
    echo "TCP wmem：$(sysctl_get net.ipv4.tcp_wmem)"
    echo "IPv4 转发：$(sysctl_get net.ipv4.ip_forward)"
    sysctl_exists net.ipv6.conf.all.forwarding && echo "IPv6 转发：$(sysctl_get net.ipv6.conf.all.forwarding)"
    sysctl_exists net.netfilter.nf_conntrack_max && echo "conntrack max：$(sysctl_get net.netfilter.nf_conntrack_max)"

    if [ -n "$iface" ] && command_exists tc; then
        active_qdisc=$(current_root_qdisc "$iface")
        echo "出口网卡：$iface，root qdisc：${active_qdisc:-未知}"
    fi

    if [ -r "$RUNTIME_CONFIG" ]; then
        runtime_shape=$(awk -F= '$1 == "SHAPE_RATE_MBIT" {print $2; exit}' "$RUNTIME_CONFIG")
        runtime_shape=${runtime_shape//\\/}
        if [ "${runtime_shape:-0}" -gt 0 ] 2>/dev/null; then
            echo "校准整形：${runtime_shape} Mbps"
        else
            echo "校准整形：未启用（不限速）"
        fi
    fi

    if [ -f "$STATE_MARKER" ]; then
        echo "回滚快照：可用（$STATE_DIR）"
    elif [ -d "$STATE_DIR" ]; then
        echo "回滚快照：状态目录存在，但当前用户不可读或快照不完整"
    else
        echo "回滚快照：不存在"
    fi

    if command_exists systemctl && [ -d /run/systemd/system ] && \
       systemctl is-enabled bbr-optimize-persist.service >/dev/null 2>&1; then
        echo "持久化：systemd oneshot 已启用，无常驻进程"
    elif command_exists rc-update && [ -x "$OPENRC_START" ]; then
        echo "持久化：OpenRC 开机一次性脚本已启用，无常驻进程"
    else
        echo "持久化：未检测到开机任务"
    fi
}

apply_tuning() {
    local persistence_failed=0

    check_root apply
    ensure_runtime_tmp || return 1
    command_exists sysctl || {
        log_error "缺少 sysctl 命令。"
        return 1
    }
    detect_primary_iface || return 1
    check_bbr_support || return 1

    configure_link_profile
    configure_forwarding
    calculate_buffer_size
    plan_rps
    calculate_conntrack_limit
    build_sysctl_plan || return 1
    save_original_state || return 1
    inspect_original_qdisc

    write_modules_conf || return 1
    write_sysctl_conf || return 1
    apply_sysctl_plan || return 1

    if [ "$QDISC_MODE" != "skip" ]; then
        apply_unshaped_qdisc || true
    fi
    apply_rps_now || true
    calibrate_retransmissions

    install_persistence || persistence_failed=1

    echo ""
    log_ok "调优已应用。"
    echo "- BBR：已启用"
    echo "- qdisc：$([ "$SHAPE_RATE_MBIT" -gt 0 ] && echo "HTB + fq，${SHAPE_RATE_MBIT} Mbps" || echo "$QDISC_MODE，不限速")"
    echo "- 回滚：sudo bash $0 restore"
    echo "- 临时下载：退出时自动清理，不安装 Speedtest、不启动监控进程"
    echo "说明：公网链路无法承诺绝对 0 重传；脚本只在测速证明有效时才牺牲少量峰值换取更低重传。"

    if [ "$persistence_failed" != "0" ]; then
        log_warn "当前参数已生效，但开机持久化配置失败。快照仍可用于 restore。"
        return 1
    fi
}

show_help() {
    cat <<EOF
BBR 直连/落地调优 v$SCRIPT_VERSION

用法：
  sudo bash $0 apply       应用高吞吐、低重传调优
  sudo bash $0 restore     恢复首次应用前的原系统调优参数
  sudo bash $0 rollback    restore 的别名
  bash $0 status           查看当前状态
  bash $0 --help           显示帮助

可选环境变量：
  AUTO_MODE=1                    非交互执行
  BANDWIDTH_MBIT=1000 RTT_MS=80  手工指定代表性链路画像
  SPEEDTEST_SERVER_ID=12345      固定 Ookla 测速服务器
  ENABLE_IPV4_FORWARD=1          启用 IPv4 内核转发配套参数
  ENABLE_IPV6_FORWARD=1          启用 IPv6 内核转发配套参数
  RETRANS_TARGET_PPM=2000        重传目标，2000 ppm = 0.2%
  SKIP_CALIBRATION=1             跳过一次性 Speedtest 重传校准
  RESTORE_CONFIRM=YES            非交互确认恢复

持久文件：
  $SYSCTL_CONF
  $MODULES_CONF
  $PERSIST_SCRIPT
  $STATE_DIR（原值快照，restore 成功后删除）

脚本不会修改 SWAP、THP、NUMA、limits.conf，不添加 MSS Clamp，
不会安装常驻反馈程序，也不会永久安装临时下载的 Speedtest。
已有非默认句柄或 CAKE/HTB/TBF 等自定义 qdisc 时会保持现状。
一次性重传校准可能执行多轮 Speedtest，请在业务低峰运行并留意流量配额。
EOF
}

main() {
    local command="${1:-apply}"

    case "$command" in
        apply)
            apply_tuning
            ;;
        restore|rollback)
            check_root restore
            restore_original_state
            ;;
        status)
            show_status
            ;;
        -h|--help|help)
            show_help
            ;;
        -v|--version|version)
            echo "bbr-direct-tune.sh v$SCRIPT_VERSION"
            ;;
        *)
            log_error "未知命令：$command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
