#!/usr/bin/env bash
# Standalone extraction of "BBR 直连/落地优化（智能带宽检测）"
# Source: https://github.com/Eric86777/vps-tcp-tune/blob/main/net-tcp-tune.sh
# Extracted from upstream v5.3.0, keeping only the direct/endpoint BBR tuning feature.

set -o pipefail

SCRIPT_VERSION="standalone-5.3.0"
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
AUTO_MODE="${AUTO_MODE:-0}"

gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'
gl_zi='\033[35m'
gl_hui='\033[90m'

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
    echo "按任意键继续..."
    read -n 1 -s -r -p ""
    echo ""
}

clean_sysctl_conf() {
    # 备份主配置文件
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi
    
    # 注释所有冲突参数
    sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.default_qdisc/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_congestion_control/s/^/# /' /etc/sysctl.conf 2>/dev/null
}

add_swap() {
    local new_swap=$1  # 获取传入的参数（单位：MB）

    echo -e "${gl_kjlan}=== 调整虚拟内存（仅管理 /swapfile） ===${gl_bai}"

    # 检测是否存在活跃的 /dev/* swap 分区
    local dev_swap_list
    dev_swap_list=$(awk 'NR>1 && $1 ~ /^\/dev\// {printf "  • %s (大小: %d MB, 已用: %d MB)\n", $1, int(($3+512)/1024), int(($4+512)/1024)}' /proc/swaps)

    if [ -n "$dev_swap_list" ]; then
        echo -e "${gl_huang}检测到以下 /dev/ 虚拟内存处于激活状态：${gl_bai}"
        echo "$dev_swap_list"
        echo ""
        echo -e "${gl_huang}提示:${gl_bai} 本脚本不会修改 /dev/ 分区，请使用 ${gl_zi}swapoff <设备>${gl_bai} 等命令手动处理。"
        echo ""
    fi

    echo -e "${gl_huang}警告:${gl_bai} 即将停用并重建 /swapfile，同时更新 /etc/fstab。"
    if [ -f /swapfile ]; then
        local swapfile_size
        swapfile_size=$(du -h /swapfile 2>/dev/null | awk '{print $1}')
        echo -e "当前 /swapfile 大小: ${gl_huang}${swapfile_size:-未知}${gl_bai}"
    else
        echo "当前未发现 /swapfile。"
    fi
    if grep -q '/swapfile' /etc/fstab 2>/dev/null; then
        echo "当前 /etc/fstab 中的 /swapfile 记录："
        grep '/swapfile' /etc/fstab 2>/dev/null
    fi
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认重建 /swapfile？输入 YES 继续: ${gl_bai}")" swap_confirm
    if [ "$swap_confirm" != "YES" ]; then
        echo -e "${gl_huang}已跳过 SWAP 配置${gl_bai}"
        return 1
    fi

    # 确保 /swapfile 不再被使用
    swapoff /swapfile 2>/dev/null
    
    # 删除旧的 /swapfile
    rm -f /swapfile
    
    echo "正在创建 ${new_swap}MB 虚拟内存..."
    
    # 创建新的 swap 分区
    fallocate -l $(( (new_swap + 1) * 1024 * 1024 )) /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((new_swap + 1))
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    
    # 更新 /etc/fstab
    sed -i '/\/swapfile/d' /etc/fstab
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    
    # Alpine Linux 特殊处理
    if [ -f /etc/alpine-release ]; then
        echo "nohup swapon /swapfile" > /etc/local.d/swap.start
        chmod +x /etc/local.d/swap.start
        rc-update add local 2>/dev/null
    fi
    
    echo -e "${gl_lv}虚拟内存大小已调整为 ${new_swap}MB${gl_bai}"
}

ensure_speedtest() {
    if command -v speedtest >/dev/null 2>&1; then
        return 0
    fi

    local install_confirm
    echo -e "${gl_huang}speedtest 未安装。${gl_bai}" >&2
    echo -e "${gl_zi}建议优先使用系统包管理器安装 Ookla Speedtest CLI；也可以让脚本下载官方二进制。${gl_bai}" >&2

    if [ "$AUTO_MODE" = "1" ]; then
        install_confirm=N
    else
        read -e -p "是否下载 Ookla 官方 speedtest 二进制到 /usr/local/bin？(Y/N) [N]: " install_confirm
        install_confirm=${install_confirm:-N}
    fi

    case "$install_confirm" in
        [Yy])
            ;;
        *)
            echo -e "${gl_huang}已跳过 speedtest 安装，将使用手动/默认带宽配置。${gl_bai}" >&2
            return 1
            ;;
    esac

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

    if command -v wget >/dev/null 2>&1; then
        wget -q "$download_url" -O "$tmp_dir/speedtest.tgz"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$download_url" -o "$tmp_dir/speedtest.tgz"
    else
        echo -e "${gl_hong}未找到 wget 或 curl，无法下载 speedtest${gl_bai}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "$tmp_dir/speedtest.tgz" -C "$tmp_dir" 2>/dev/null || [ ! -f "$tmp_dir/speedtest" ]; then
        echo -e "${gl_hong}speedtest 解压失败${gl_bai}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! mv "$tmp_dir/speedtest" /usr/local/bin/speedtest; then
        echo -e "${gl_hong}无法写入 /usr/local/bin/speedtest${gl_bai}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    chmod +x /usr/local/bin/speedtest
    rm -rf "$tmp_dir"
    echo -e "${gl_lv}speedtest 安装成功${gl_bai}" >&2
    return 0
}

detect_bandwidth() {
    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    echo "" >&2
    echo -e "${gl_kjlan}=== 服务器带宽检测 ===${gl_bai}" >&2
    echo "" >&2
    echo "请选择带宽配置方式：" >&2
    echo "1. 自动检测（推荐，自动选择最近服务器）" >&2
    echo "2. 手动指定测速服务器（指定服务器ID）" >&2
    echo "3. 手动选择预设档位（9个常用带宽档位）" >&2
    echo "" >&2
    
    read -e -p "请输入选择 [1]: " bw_choice
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        1)
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
            local servers_list=$(speedtest --accept-license --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            
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
                    speedtest_output=$(speedtest --accept-license 2>&1)
                else
                    echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
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
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
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
        2)
            # 手动指定测速服务器ID
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动指定测速服务器 ===${gl_bai}" >&2
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
            read -e -p "是否现在查看附近的测速服务器列表？(Y/N) [Y]: " show_list
            show_list=${show_list:-Y}
            
            if [[ "$show_list" =~ ^[Yy]$ ]]; then
                echo "" >&2
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                speedtest --accept-license --servers 2>/dev/null | head -n 20 >&2
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
            
            local speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
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
                
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
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
        3)
            # 手动选择预设档位
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动选择带宽档位 ===${gl_bai}" >&2
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

# 缓冲区大小计算函数
calculate_buffer_size() {
    local bandwidth=$1
    local region=${2:-asia}  # asia（亚太）或 overseas（美欧）
    local buffer_mb
    local bandwidth_level

    # 输入验证：确保 bandwidth 是正整数
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [ "$bandwidth" -le 0 ] 2>/dev/null; then
        local fallback_mb=16
        [ "$region" = "overseas" ] && fallback_mb=64
        echo -e "${gl_huang}⚠️ 带宽值无效 (${bandwidth})，使用默认值 ${fallback_mb}MB${gl_bai}" >&2
        echo "$fallback_mb"
        return 0
    fi

    if [ "$region" = "overseas" ]; then
        # ===== 美国/欧洲档位（RTT ~200ms，buffer ≈ BDP × 2.5，上限 64MB）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（100 Mbps·远距离）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（200 Mbps·远距离）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（300 Mbps·远距离）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=32
            bandwidth_level="预设档位（500 Mbps·远距离）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=48
            bandwidth_level="预设档位（700 Mbps·远距离）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1 Gbps·远距离）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1.5 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2.5 Gbps·远距离）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=16
            bandwidth_level="小带宽（< 500 Mbps·远距离）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=48
            bandwidth_level="中等带宽（500-1000 Mbps·远距离）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=64
            bandwidth_level="标准带宽（1-2 Gbps·远距离）"
        else
            buffer_mb=64
            bandwidth_level="高带宽（> 2 Gbps·远距离）"
        fi
    else
        # ===== 亚太地区档位（RTT ~50ms，原有逻辑不变）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=6
            bandwidth_level="预设档位（100 Mbps）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（200 Mbps）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=10
            bandwidth_level="预设档位（300 Mbps）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=12
            bandwidth_level="预设档位（500 Mbps）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=14
            bandwidth_level="预设档位（700 Mbps）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（1 Gbps）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（1.5 Gbps）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=24
            bandwidth_level="预设档位（2 Gbps）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=28
            bandwidth_level="预设档位（2.5 Gbps）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=8
            bandwidth_level="小带宽（< 500 Mbps）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=12
            bandwidth_level="中等带宽（500-1000 Mbps）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=16
            bandwidth_level="标准带宽（1-2 Gbps）"
        elif [ "$bandwidth" -lt 5000 ]; then
            buffer_mb=24
            bandwidth_level="高带宽（2-5 Gbps）"
        elif [ "$bandwidth" -lt 10000 ]; then
            buffer_mb=28
            bandwidth_level="超高带宽（5-10 Gbps）"
        else
            buffer_mb=32
            bandwidth_level="极高带宽（> 10 Gbps）"
        fi
    fi

    # 显示计算结果（输出到stderr）
    local region_label="亚太地区"
    [ "$region" = "overseas" ] && region_label="美国/欧洲"
    echo "" >&2
    echo -e "${gl_kjlan}根据带宽和地区计算最优缓冲区:${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "  检测带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}" >&2
    echo -e "  服务地区: ${gl_huang}${region_label}${gl_bai}" >&2
    echo -e "  带宽等级: ${bandwidth_level}" >&2
    echo -e "  推荐缓冲区: ${gl_lv}${buffer_mb} MB${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 询问确认
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: ${gl_bai}")" confirm
        confirm=${confirm:-Y}
    fi

    case "$confirm" in
        [Yy])
            # 返回缓冲区大小（MB）
            echo "$buffer_mb"
            return 0
            ;;
        *)
            local default_mb=16
            [ "$region" = "overseas" ] && default_mb=32
            echo "" >&2
            echo -e "${gl_huang}已取消，将使用通用值 ${default_mb}MB${gl_bai}" >&2
            echo "$default_mb"
            return 1
            ;;
    esac
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
    echo -e "${gl_huang}提示:${gl_bai} SWAP 调整会重建 /swapfile 并修改 /etc/fstab；不确定时建议先跳过。"
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
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=N
    else
        read -e -p "$(echo -e "${gl_huang}是否现在配置虚拟内存？(Y/N) [N]: ${gl_bai}")" confirm
        confirm=${confirm:-N}
    fi

    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_lv}开始配置虚拟内存...${gl_bai}"
            echo ""
            add_swap "$recommended_swap"
            echo ""
            echo -e "${gl_lv}✅ 虚拟内存配置完成！${gl_bai}"
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
    echo -e "${gl_kjlan}=== 检查 sysctl 配置冲突 ===${gl_bai}"
    local conflicts=()
    # 搜索 /etc/sysctl.d/ 下可能覆盖 tcp_rmem/tcp_wmem 的高序号文件
    for conf in /etc/sysctl.d/[0-9]*-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        if grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" "$conf" 2>/dev/null; then
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
    if [ -f /etc/sysctl.conf ] && grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        echo -e "${gl_lv}✓ 未发现可能的覆盖配置${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}发现可能的覆盖配置：${gl_bai}"
    for f in "${conflicts[@]}"; do
        echo "  - $f"; grep -E "net\.ipv4\.tcp_(rmem|wmem)" "$f" | sed 's/^/      /'
    done
    [ $has_sysctl_conflict -eq 1 ] && echo "  - /etc/sysctl.conf (含 tcp_rmem/tcp_wmem)"

    if [ "$AUTO_MODE" = "1" ]; then
        ans=Y
    else
        read -e -p "是否自动禁用/注释这些覆盖配置？(Y/N): " ans
    fi
    case "$ans" in
        [Yy])
            # 注释 /etc/sysctl.conf 中相关行
            if [ $has_sysctl_conflict -eq 1 ]; then
                # 先创建一次备份，再用 sed -i 逐行注释（避免多次 .bak 覆盖）
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                echo -e "${gl_lv}✓ 已注释 /etc/sysctl.conf 中的相关配置（备份: .bak.conflict）${gl_bai}"
            fi
            # 将高优先级冲突文件重命名禁用
            for f in "${conflicts[@]}"; do
                if [ ! -f "$f" ]; then
                    echo -e "${gl_lv}✓ 已跳过: $(basename "$f")（已处理）${gl_bai}"
                    continue
                fi
                if mv "$f" "${f}.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
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
        echo -e "${gl_huang}警告: 未检测到 tc（iproute2），跳过 fq 应用${gl_bai}"
        return 0
    fi
    local applied=0
    for dev in $(eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    [ $applied -gt 0 ] && echo -e "${gl_lv}已对 $applied 个网卡应用 fq（即时生效）${gl_bai}" || echo -e "${gl_huang}未发现可应用 fq 的网卡${gl_bai}"
}

# MSS clamp（防分片）自动启用
apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 iptables，跳过 MSS clamp${gl_bai}"
        return 0
    fi
    if [ "$action" = "enable" ]; then
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
          || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    fi
}

#=============================================================================
# BBR 配置函数（智能检测版）
#=============================================================================

# 直连/落地优化配置
bbr_configure_direct() {
    echo -e "${gl_kjlan}=== 配置 BBR v3 + FQ 直连/落地优化（智能检测版） ===${gl_bai}"
    echo ""
    
    # 步骤 0：SWAP智能检测和建议
    echo -e "${gl_zi}[步骤 1/6] 检测虚拟内存（SWAP）配置...${gl_bai}"
    check_and_suggest_swap
    
    # 步骤 0.5：带宽检测和缓冲区计算
    echo ""
    echo -e "${gl_zi}[步骤 2/6] 检测服务器带宽并计算最优缓冲区...${gl_bai}"

    local detected_bandwidth=$(detect_bandwidth)

    # 地区选择（影响缓冲区大小：高延迟地区需要更大缓冲区）
    local region="asia"
    local region_choice=""
    echo ""
    echo -e "${gl_kjlan}请选择服务器主要服务的地区：${gl_bai}"
    echo ""
    echo "1. 亚太地区（港/日/新/韩等）⭐ 推荐"
    echo "   延迟较低（RTT < 100ms），使用标准缓冲区"
    echo ""
    echo "2. 美国/欧洲（跨太平洋/大西洋）"
    echo "   延迟较高（RTT 150-300ms），使用大缓冲区"
    echo ""
    read -e -p "请输入选择 [1]: " region_choice
    region_choice=${region_choice:-1}
    case "$region_choice" in
        2) region="overseas" ;;
        *) region="asia" ;;
    esac

    local buffer_mb=$(calculate_buffer_size "$detected_bandwidth" "$region")
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    
    echo -e "${gl_lv}✅ 将使用 ${buffer_mb}MB 缓冲区配置${gl_bai}"
    sleep 2
    
    echo ""
    echo -e "${gl_zi}[步骤 3/6] 清理配置冲突...${gl_bai}"
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
    
    # 删除可能存在的软链接
    if [ -L /etc/sysctl.d/99-sysctl.conf ]; then
        rm -f /etc/sysctl.d/99-sysctl.conf
        echo "已删除配置软链接"
    fi
    
    # 检查并清理可能覆盖的新旧配置冲突
    check_and_clean_conflicts

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    echo -e "${gl_zi}[步骤 4/6] 创建配置文件...${gl_bai}"
    echo "正在创建新配置..."
    
    # 获取物理内存用于虚拟内存参数调整
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local vm_swappiness=5
    local vm_dirty_ratio=15
    local vm_min_free_kbytes=65536
    
    # 根据内存大小微调虚拟内存参数
    if [ "$mem_total" -lt 2048 ]; then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi
    
    cat > "$SYSCTL_CONF" << EOF
# BBR v3 Direct/Endpoint Configuration (Intelligent Detection Edition)
# Generated on $(date)
# Bandwidth: ${detected_bandwidth} Mbps | Region: ${region} | Buffer: ${buffer_mb} MB

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲区优化（智能检测：${buffer_mb}MB）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}

# ===== 直连/落地优化参数 =====

# TIME_WAIT 重用（启用，提高并发）
net.ipv4.tcp_tw_reuse=1

# 端口范围（最大化）
net.ipv4.ip_local_port_range=1024 65535

# 连接队列（高性能）
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192

# 网络队列（高带宽优化）
net.core.netdev_max_backlog=5000

# 高级TCP优化
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# ===== Reality终极优化参数 =====

# 发送低水位（上传速度优化关键）
net.ipv4.tcp_notsent_lowat=16384

# 连接回收优化
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000

# TCP Fast Open（节省1个RTT，加速连接建立）
net.ipv4.tcp_fastopen=3

# TCP保活优化（更快检测死连接）
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# UDP缓冲区（QUIC/Hysteria 支持）
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP安全增强
net.ipv4.tcp_syncookies=1

# 虚拟内存优化（根据物理内存调整）
vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50

# CPU调度优化
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    # 检查配置文件是否创建成功
    if [ ! -f "$SYSCTL_CONF" ] || [ ! -s "$SYSCTL_CONF" ]; then
        echo -e "${gl_hong}❌ 配置文件创建失败！请检查磁盘空间和权限${gl_bai}"
        return 1
    fi

    # 步骤 4：应用配置
    echo ""
    echo -e "${gl_zi}[步骤 5/6] 应用所有优化参数...${gl_bai}"
    echo "正在应用配置..."
    local sysctl_output
    sysctl_output=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    local sysctl_rc=$?
    if [ $sysctl_rc -ne 0 ]; then
        echo -e "${gl_huang}⚠️ sysctl 部分参数应用失败（可能有不支持的参数）:${gl_bai}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -5
        echo -e "${gl_zi}已支持的参数仍然生效，不影响整体优化${gl_bai}"
    else
        echo -e "${gl_lv}✓ 所有 sysctl 参数已成功应用${gl_bai}"
    fi

    # 立即应用 fq，并启用 MSS clamp（无需重启）
    echo "正在应用队列与防分片（无需重启）..."
    apply_tc_fq_now >/dev/null 2>&1
    apply_mss_clamp enable >/dev/null 2>&1

    # 持久化 tc fq 和 iptables MSS clamp（重启后自动恢复）
    echo "正在配置重启持久化..."
    # 创建 systemd 服务实现 tc fq + MSS clamp 开机恢复
    cat > /etc/systemd/system/bbr-optimize-persist.service << 'PERSISTEOF'
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
PERSISTEOF

    cat > /usr/local/bin/bbr-optimize-apply.sh << 'APPLYEOF'
#!/bin/bash
# BBR Optimize 重启恢复脚本 - 自动生成，勿手动编辑
# 应用 tc fq 到所有物理网卡
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null
done
# 应用 iptables MSS clamp
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
# 禁用透明大页
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
fi
# 优化 TCP 初始拥塞窗口（加速连接起步）
DEF_ROUTE=$(ip route show default 2>/dev/null | head -1)
if [ -n "$DEF_ROUTE" ]; then
    CLEAN_ROUTE=$(echo "$DEF_ROUTE" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $CLEAN_ROUTE initcwnd 32 initrwnd 32 2>/dev/null
fi
# RPS/RFS 多核网络优化（遍历所有物理网卡）
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
if [ "$CPU_COUNT" -gt 1 ]; then
    RPS_MASK=$(printf '%x' $((2**CPU_COUNT - 1)))
    FLOW_ENTRIES=$((4096 * CPU_COUNT))
    echo "$FLOW_ENTRIES" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for D in /sys/class/net/*; do
        [ -e "$D" ] || continue
        DEV=$(basename "$D")
        case "$DEV" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        [ -d "/sys/class/net/$DEV/queues" ] || continue
        for RXQ in /sys/class/net/$DEV/queues/rx-*/rps_cpus; do
            [ -f "$RXQ" ] && echo "$RPS_MASK" > "$RXQ" 2>/dev/null
        done
        for RXQ_DIR in /sys/class/net/$DEV/queues/rx-*/; do
            [ -f "${RXQ_DIR}rps_flow_cnt" ] && echo "$((FLOW_ENTRIES / CPU_COUNT))" > "${RXQ_DIR}rps_flow_cnt" 2>/dev/null
        done
    done
fi
APPLYEOF
    chmod +x /usr/local/bin/bbr-optimize-apply.sh
    systemctl daemon-reload 2>/dev/null
    systemctl enable bbr-optimize-persist.service 2>/dev/null
    echo -e "${gl_lv}✓ tc fq / MSS clamp / 透明大页 重启持久化已配置${gl_bai}"

    # 配置文件描述符限制
    echo "正在优化文件描述符限制..."
    if ! grep -q "^\* soft nofile 524288" /etc/security/limits.conf 2>/dev/null && \
       ! grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITSEOF'
# BBR - 文件描述符优化
* soft nofile 524288
* hard nofile 524288
LIMITSEOF
    fi
    ulimit -n 524288 2>/dev/null

    # 禁用透明大页面（当前运行时）
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    # 优化 TCP 初始拥塞窗口（加速连接起步，节省1-2个RTT）
    echo "正在优化 TCP 初始拥塞窗口..."
    local def_route
    def_route=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$def_route" ]; then
        # 清除已有的 initcwnd/initrwnd 再重新设置，避免重复
        local clean_route
        clean_route=$(echo "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        if ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null; then
            echo -e "${gl_lv}✓ initcwnd=32 initrwnd=32 已应用（加速 TCP 连接起步）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ initcwnd 设置失败（不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠️ 未检测到默认路由，跳过 initcwnd 优化${gl_bai}"
    fi

    # RPS/RFS 多核网络优化（将网卡收包分散到所有 CPU 核心）
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    if [ "$cpu_count" -gt 1 ]; then
        echo "正在配置 RPS/RFS 多核网络优化..."
        # 计算 CPU 掩码（所有核心参与）：2核=3, 4核=f, 8核=ff
        local rps_mask
        rps_mask=$(printf '%x' $((2**cpu_count - 1)))
        local flow_entries=$((4096 * cpu_count))
        echo "$flow_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        # 遍历所有物理网卡（排除虚拟/隧道接口）
        local rps_ok=0
        local rps_devs=""
        local dev
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            dev=$(basename "$d")
            case "$dev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -d "/sys/class/net/$dev/queues" ] || continue
            # 设置 RPS：将收包分散到所有核心
            for rxq in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
                if [ -f "$rxq" ]; then
                    echo "$rps_mask" > "$rxq" 2>/dev/null
                    # 写入后读回验证（有些环境 echo 返回0但内核没接受）
                    local verify_val
                    verify_val=$(cat "$rxq" 2>/dev/null | tr -d ',' | sed 's/^0*//')
                    [ -z "$verify_val" ] && verify_val="0"
                    [ "$verify_val" = "$rps_mask" ] && rps_ok=1
                fi
            done
            # 设置 RFS：同一连接的包尽量在同一核处理（减少 cache miss）
            for rxq_dir in /sys/class/net/$dev/queues/rx-*/; do
                if [ -f "${rxq_dir}rps_flow_cnt" ]; then
                    echo "$((flow_entries / cpu_count))" > "${rxq_dir}rps_flow_cnt" 2>/dev/null
                fi
            done
            rps_devs="${rps_devs} ${dev}"
        done
        if [ $rps_ok -eq 1 ]; then
            echo -e "${gl_lv}✓ RPS/RFS 已启用（${cpu_count} 核，掩码: 0x${rps_mask}，网卡:${rps_devs}）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ RPS 设置未生效（当前虚拟化环境可能不支持，不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_zi}ℹ 单核 CPU，跳过 RPS/RFS（单核无需分担）${gl_bai}"
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    echo -e "${gl_zi}[步骤 6/6] 验证配置...${gl_bai}"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    
    echo ""
    echo -e "${gl_kjlan}=== 配置验证 ===${gl_bai}"
    
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

    # 验证 initcwnd
    local actual_initcwnd
    actual_initcwnd=$(ip route show default 2>/dev/null | head -1 | grep -oP 'initcwnd \K[0-9]+')
    if [ "$actual_initcwnd" = "32" ]; then
        echo -e "初始窗口:   ${gl_lv}initcwnd=$actual_initcwnd ✓${gl_bai}"
    elif [ -n "$actual_initcwnd" ]; then
        echo -e "初始窗口:   ${gl_huang}initcwnd=$actual_initcwnd (期望: 32) ⚠${gl_bai}"
    else
        echo -e "初始窗口:   ${gl_huang}未设置 (期望: initcwnd=32) ⚠${gl_bai}"
    fi

    # 验证 RPS
    if [ "$cpu_count" -gt 1 ]; then
        local expected_mask
        expected_mask=$(printf '%x' $((2**cpu_count - 1)))
        local rps_verify_devs=""
        local rps_all_ok=1
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            local vdev=$(basename "$d")
            case "$vdev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -f "/sys/class/net/$vdev/queues/rx-0/rps_cpus" ] || continue
            local rps_val
            # rps_cpus 可能返回 "3" 或 "00000003" 或 "00000000,00000003"
            rps_val=$(cat /sys/class/net/$vdev/queues/rx-0/rps_cpus 2>/dev/null | tr -d ',' | sed 's/^0*//')
            [ -z "$rps_val" ] && rps_val="0"
            if [ "$rps_val" = "$expected_mask" ]; then
                rps_verify_devs="${rps_verify_devs} ${vdev}✓"
            else
                rps_verify_devs="${rps_verify_devs} ${vdev}✗"
                rps_all_ok=0
            fi
        done
        if [ -n "$rps_verify_devs" ]; then
            if [ $rps_all_ok -eq 1 ]; then
                echo -e "RPS/RFS:    ${gl_lv}${cpu_count}核分担 (0x${expected_mask})${rps_verify_devs} ✓${gl_bai}"
            else
                echo -e "RPS/RFS:    ${gl_huang}部分网卡未生效:${rps_verify_devs} ⚠${gl_bai}"
            fi
        else
            echo -e "RPS/RFS:    ${gl_huang}未检测到物理网卡 ⚠${gl_bai}"
        fi
    else
        echo -e "RPS/RFS:    ${gl_zi}单核跳过${gl_bai}"
    fi

    echo ""

    # 最终判断
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "bbr" ] && \
       [ "$actual_wmem" = "$buffer_bytes" ] && [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "${gl_lv}✅ BBR v3 直连/落地优化配置完成并已生效！${gl_bai}"
        echo -e "${gl_zi}配置说明: ${buffer_mb}MB 缓冲区（${detected_bandwidth} Mbps 带宽），适合直连/落地场景${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 配置已保存但部分参数未生效${gl_bai}"
        echo -e "${gl_huang}建议执行以下操作：${gl_bai}"
        echo "1. 检查是否有其他配置文件冲突"
        echo "2. 重启服务器使配置完全生效: reboot"
    fi
}

check_bbr_status() {
    echo -e "${gl_kjlan}=== 当前 BBR 直连优化状态 ===${gl_bai}"
    echo "内核版本: $(uname -r)"

    local congestion="未知"
    local qdisc="未知"
    local tcp_wmem="未知"
    local tcp_rmem="未知"

    if command -v sysctl >/dev/null 2>&1; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "未知")
        tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "未知")
    fi

    echo "拥塞控制算法: $congestion"
    echo "队列调度算法: $qdisc"
    echo "发送缓冲区: $tcp_wmem"
    echo "接收缓冲区: $tcp_rmem"

    if command -v modinfo >/dev/null 2>&1; then
        local bbr_version
        bbr_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
        [ -n "$bbr_version" ] && echo "tcp_bbr 模块版本: $bbr_version"
    fi

    if [ -f "$SYSCTL_CONF" ]; then
        echo -e "配置文件: ${gl_lv}${SYSCTL_CONF}${gl_bai}"
    else
        echo -e "配置文件: ${gl_huang}未找到 ${SYSCTL_CONF}${gl_bai}"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled bbr-optimize-persist.service >/dev/null 2>&1; then
            echo -e "持久化服务: ${gl_lv}已启用${gl_bai}"
        else
            echo -e "持久化服务: ${gl_huang}未启用${gl_bai}"
        fi
    fi
}

restore_bbr_direct() {
    echo -e "${gl_huang}即将清理本脚本生成的 BBR 直连优化配置。${gl_bai}"
    echo "将处理："
    echo "  - $SYSCTL_CONF"
    echo "  - /etc/systemd/system/bbr-optimize-persist.service"
    echo "  - /usr/local/bin/bbr-optimize-apply.sh"
    echo "  - /etc/security/limits.conf 中的 BBR 文件描述符块"
    echo "  - iptables mangle 表中的 TCPMSS clamp 规则（如存在）"
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认清理？输入 YES 继续: ${gl_bai}")" restore_confirm
    if [ "$restore_confirm" != "YES" ]; then
        echo "已取消。"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    fi

    rm -f /etc/systemd/system/bbr-optimize-persist.service
    rm -f /usr/local/bin/bbr-optimize-apply.sh
    rm -f "$SYSCTL_CONF"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; do
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || break
        done
    fi

    if [ -f /etc/security/limits.conf ] && grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cp /etc/security/limits.conf "/etc/security/limits.conf.bak.bbr-restore.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        sed -i '/^# BBR - 文件描述符优化$/,+2d' /etc/security/limits.conf 2>/dev/null || true
    fi

    if [ -f /etc/sysctl.conf.bak.original ]; then
        echo ""
        read -e -p "发现 /etc/sysctl.conf.bak.original，是否恢复到 /etc/sysctl.conf？(Y/N) [N]: " restore_sysctl
        restore_sysctl=${restore_sysctl:-N}
        if [[ "$restore_sysctl" =~ ^[Yy]$ ]]; then
            cp /etc/sysctl.conf "/etc/sysctl.conf.bak.before-restore.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            cp /etc/sysctl.conf.bak.original /etc/sysctl.conf
            echo -e "${gl_lv}已恢复 /etc/sysctl.conf${gl_bai}"
        fi
    fi

    if command -v sysctl >/dev/null 2>&1; then
        sysctl --system >/dev/null 2>&1 || true
    fi

    echo -e "${gl_lv}清理完成。建议重新执行 status 查看当前状态。${gl_bai}"
}

show_help() {
    cat << EOF
BBR 直连/落地优化（智能带宽检测）独立版 v${SCRIPT_VERSION}

用法:
  sudo bash $0              交互式应用优化
  sudo bash $0 apply        交互式应用优化
  sudo bash $0 restore      清理由本脚本生成的配置与持久化服务
  bash $0 status            查看当前 BBR / qdisc 状态
  bash $0 -h|--help         显示帮助

说明:
  - 会写入 ${SYSCTL_CONF}
  - 可能备份并注释 /etc/sysctl.conf 中冲突的 TCP 参数
  - 会创建 /etc/systemd/system/bbr-optimize-persist.service
  - 会创建 /usr/local/bin/bbr-optimize-apply.sh
  - 若你确认配置 SWAP，会重建 /swapfile 并更新 /etc/fstab
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
