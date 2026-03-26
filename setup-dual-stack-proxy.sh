#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

CURRENT_DIR=$(
    cd "$(dirname "$0")"
    pwd
)

function log() {
    message="[Proxy Log]: $1 "
    echo -e "${message}" 2>&1 | tee -a ${CURRENT_DIR}/proxy-install.log
}

function log_section() {
    echo -e "\n${BLUE}$1${NC}" | tee -a ${CURRENT_DIR}/proxy-install.log
}

echo -e "${BLUE}=== IPv4 + IPv6 双栈代理池一键配置脚本 ===${NC}\n"

# ==================== 基础检查 ====================
function Check_Root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 或 sudo 权限运行此脚本${NC}"
        exit 1
    fi
}

# ==================== 系统文件描述符限制优化 ====================
function Set_System_Limits() {
    log_section "[0/3] 优化系统文件描述符限制..."

    echo "root soft nofile 1000000" > /etc/security/limits.d/99-custom.conf
    echo "root hard nofile 1000000" >> /etc/security/limits.d/99-custom.conf
    echo "* soft nofile 1000000"    >> /etc/security/limits.d/99-custom.conf
    echo "* hard nofile 1000000"    >> /etc/security/limits.d/99-custom.conf

    sed -i "s/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1000000/" /etc/systemd/system.conf
    sed -i "s/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1000000/" /etc/systemd/user.conf

    grep -q "pam_limits" /etc/pam.d/sshd || echo "session required pam_limits.so" >> /etc/pam.d/sshd

    systemctl daemon-reexec
    systemctl restart sshd

    log "系统文件描述符限制已设置为 1000000"
}

# ==================== IPv4 代理配置（Glider） ====================
function Install_Docker(){
    if which docker >/dev/null 2>&1; then
        log "检测到 Docker 已安装，跳过安装步骤"
        systemctl start docker 2>&1 | tee -a ${CURRENT_DIR}/install.log
    else
        log "... 在线安装 docker"

        if [[ $(curl -s ipinfo.io/country) == "CN" ]]; then
            sources=(
                "https://mirrors.aliyun.com/docker-ce"
                "https://mirrors.tencent.com/docker-ce"
                "https://mirrors.163.com/docker-ce"
                "https://mirrors.cernet.edu.cn/docker-ce"
            )

            get_average_delay() {
                local source=$1
                local total_delay=0
                local iterations=3
                for ((i = 0; i < iterations; i++)); do
                    delay=$(curl -o /dev/null -s -w "%{time_total}\n" "$source")
                    total_delay=$(awk "BEGIN {print $total_delay + $delay}")
                done
                average_delay=$(awk "BEGIN {print $total_delay / $iterations}")
                echo "$average_delay"
            }

            min_delay=${#sources[@]}
            selected_source=""
            for source in "${sources[@]}"; do
                average_delay=$(get_average_delay "$source")
                if (( $(awk 'BEGIN { print '"$average_delay"' < '"$min_delay"' }') )); then
                    min_delay=$average_delay
                    selected_source=$source
                fi
            done

            if [ -n "$selected_source" ]; then
                echo "选择延迟最低的源 $selected_source，延迟为 $min_delay 秒"
                export DOWNLOAD_URL="$selected_source"
                curl -fsSL "https://get.docker.com" -o get-docker.sh
                sh get-docker.sh 2>&1 | tee -a ${CURRENT_DIR}/install.log
                systemctl enable docker; systemctl daemon-reload; systemctl start docker 2>&1 | tee -a ${CURRENT_DIR}/install.log
                docker version >/dev/null 2>&1 || { log "docker 安装失败"; exit 1; }
                log "docker 安装成功"
            fi
        else
            export DOWNLOAD_URL="https://download.docker.com"
            curl -fsSL "https://get.docker.com" -o get-docker.sh
            sh get-docker.sh 2>&1 | tee -a ${CURRENT_DIR}/install.log
            systemctl enable docker; systemctl daemon-reload; systemctl start docker 2>&1 | tee -a ${CURRENT_DIR}/install.log
            docker version >/dev/null 2>&1 || { log "docker 安装失败"; exit 1; }
            log "docker 安装成功"
        fi
    fi
}

function Install_Compose(){
    docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        log "... 在线安装 docker-compose"
        arch=$(uname -m)
        [ "$arch" == 'armv7l' ] && arch='armv7'
        curl -L https://resource.fit2cloud.com/docker/compose/releases/download/v2.22.0/docker-compose-$(uname -s | tr A-Z a-z)-$arch -o /usr/local/bin/docker-compose 2>&1 | tee -a ${CURRENT_DIR}/install.log
        chmod +x /usr/local/bin/docker-compose
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        docker compose version >/dev/null 2>&1 || { log "docker-compose 安装失败"; exit 1; }
        log "docker-compose 安装成功"
    else
        log "检测到 Docker Compose 已安装，跳过安装步骤"
    fi
}

function Set_IPV4_Port(){
    DEFAULT_PORT=`expr $RANDOM % 55535 + 10000`
    while true; do
        read -p "设置 IPv4 代理端口（默认为$DEFAULT_PORT）：" PANEL_PORT
        if [[ "$PANEL_PORT" == "" ]];then
            PANEL_PORT=$DEFAULT_PORT
        fi
        if ! [[ "$PANEL_PORT" =~ ^[1-9][0-9]{0,4}$ && "$PANEL_PORT" -le 65535 ]]; then
            echo "错误：输入的端口号必须在 1 到 65535 之间"
            continue
        fi
        if ss -tlun | grep -q ":$PANEL_PORT " >/dev/null 2>&1; then
            echo "端口$PANEL_PORT被占用，请重新输入..."
            continue
        fi
        log "IPv4 代理端口设置为：$PANEL_PORT"
        break
    done
}

function Set_IPV4_Credentials(){
    DEFAULT_USERNAME=`cat /dev/urandom | head -n 16 | md5sum | head -c 10`
    while true; do
        read -p "设置 IPv4 代理用户（默认为$DEFAULT_USERNAME）：" PANEL_USERNAME
        if [[ "$PANEL_USERNAME" == "" ]];then
            PANEL_USERNAME=$DEFAULT_USERNAME
        fi
        if [[ ! "$PANEL_USERNAME" =~ ^[a-zA-Z0-9_]{3,30}$ ]]; then
            echo "错误：用户仅支持字母、数字、下划线，长度 3-30 位"
            continue
        fi
        break
    done

    DEFAULT_PASSWORD=`cat /dev/urandom | head -n 16 | md5sum | head -c 10`
    while true; do
        read -p "设置 IPv4 代理密码（默认为$DEFAULT_PASSWORD）：" PANEL_PASSWORD
        if [[ "$PANEL_PASSWORD" == "" ]];then
            PANEL_PASSWORD=$DEFAULT_PASSWORD
        fi
        if [[ ! "$PANEL_PASSWORD" =~ ^[a-zA-Z0-9_!@#$%*,.?]{3,30}$ ]]; then
            echo "错误：密码仅支持字母、数字、特殊字符（!@#$%*_,.?），长度 3-30 位"
            continue
        fi
        break
    done
    log "IPv4 代理认证：$PANEL_USERNAME / $PANEL_PASSWORD"
}

function Init_IPV4_Proxy() {
    log_section "[1/3] 配置 IPv4 代理池 (Glider)..."

    cd $CURRENT_DIR
    if [ -d "chatgpt-proxy-node" ]; then
        rm -rf chatgpt-proxy-node
    fi

    git clone -b main --depth=1 https://github.com/wm-chatgpt/chatgpt-proxy-node-deploy.git chatgpt-proxy-node 2>&1 | tee -a ${CURRENT_DIR}/install.log
    cd chatgpt-proxy-node

    RUN_BASE_DIR=/opt/chatgpt-proxy-node
    mkdir -p $RUN_BASE_DIR
    rm -rf $RUN_BASE_DIR/*
    cp ./docker-compose.yml $RUN_BASE_DIR

    sed -i "s/8443:8443/$PANEL_PORT:8443/g" $RUN_BASE_DIR/docker-compose.yml
    echo "listen=$PANEL_USERNAME:$PANEL_PASSWORD@0.0.0.0:8443" > $RUN_BASE_DIR/glider.conf

    cd $RUN_BASE_DIR
    docker compose pull 2>&1 | tee -a ${CURRENT_DIR}/install.log
    docker compose up -d --remove-orphans 2>&1 | tee -a ${CURRENT_DIR}/install.log

    log "IPv4 代理池启动成功"
}

# ==================== IPv6 代理配置 ====================
function Setup_IPV6_Proxy() {
    log_section "[2/3] 配置 IPv6 代理池 (Dynamic Pool)..."

    IFACE=$(ip -6 route show default 2>/dev/null | grep -oP 'dev \K\w+' | head -1)
    [ -z "$IFACE" ] && IFACE=$(ip link | grep -E '^[0-9]+: (eth|ens|enp|eno)' | head-1 | cut -d: -f2 | tr -d ' ')

    IPV6_INFO=$(ip -6 addr show dev $IFACE | grep "scope global" | grep -v "temporary" | head -1)
    if [ -z "$IPV6_INFO" ]; then
        echo -e "${YELLOW}警告：未检测到 IPv6 地址，跳过 IPv6 代理配置${NC}"
        return 1
    fi

    IPV6_ADDR=$(echo "$IPV6_INFO" | awk '{print $2}')
    IPV6_PREFIX=$(echo "$IPV6_ADDR" | cut -d':' -f1-4)
    IPV6_SUBNET="${IPV6_PREFIX}::/64"

    echo -e "${GREEN}✓ 网卡: $IFACE${NC}"
    echo -e "${GREEN}✓ 子网: $IPV6_SUBNET${NC}"

    log "安装 IPv6 依赖..."
    apt-get update -qq && apt-get install -y -qq ndppd curl wget net-tools 2>/dev/null

    log "配置内核参数..."
    sed -i '/# IPv6 Proxy/d' /etc/sysctl.conf
    sed -i '/net.ipv6.ip_nonlocal_bind/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.*accept_ra/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.*forwarding/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf << SYSEOF
# IPv6 Proxy
net.ipv6.ip_nonlocal_bind = 1
net.ipv6.conf.$IFACE.accept_ra = 2
net.ipv6.conf.$IFACE.forwarding = 1
net.ipv6.conf.all.forwarding = 1
SYSEOF
    sysctl -p > /dev/null 2>&1

    log "配置 ndppd..."
    cat > /etc/ndppd.conf << NDPEOF
route-ttl 30000
proxy $IFACE {
    router no
    timeout 500
    ttl 30000
    rule $IPV6_SUBNET {
        static
    }
}
NDPEOF

    systemctl enable ndppd > /dev/null 2>&1
    systemctl restart ndppd

    log "配置路由..."
    ip -6 route del local $IPV6_SUBNET dev lo 2>/dev/null
    ip -6 route add local $IPV6_SUBNET dev lo

    # 设置 IPv6 代理端口
    if ss -tlun | grep -q ":33001 "; then
        echo -e "${YELLOW}警告：33001 端口被占用，IPv6 代理将使用随机端口${NC}"
        IPV6_PORT=$(shuf -i 40000-60000 -n 1)
    else
        IPV6_PORT=33001
    fi

    # 设置最大并发连接数
    DEFAULT_MAX_CONNS=50000
    read -p "设置 IPv6 代理最大并发连接数（默认 $DEFAULT_MAX_CONNS，推荐 10000-100000）：" MAX_CONNS
    if [[ "$MAX_CONNS" == "" ]]; then
        MAX_CONNS=$DEFAULT_MAX_CONNS
    fi
    if ! [[ "$MAX_CONNS" =~ ^[0-9]+$ ]] || [ "$MAX_CONNS" -lt 100 ] || [ "$MAX_CONNS" -gt 1000000 ]; then
        echo -e "${YELLOW}无效输入，使用默认值 $DEFAULT_MAX_CONNS${NC}"
        MAX_CONNS=$DEFAULT_MAX_CONNS
    fi
    log "最大并发连接数设置为：$MAX_CONNS"

    log "下载 IPv6 代理程序..."
    cd /opt
    ARCH=$(uname -m)
    [ "$ARCH" == "aarch64" ] && BINARY="go-ipv6-pool-linux-arm64" || BINARY="go-ipv6-pool-linux-amd64"

    # 尝试从 GitHub Releases 下载，如果失败则从源码编译
    LATEST_VERSION=$(curl -s https://api.github.com/repos/Mrio233/go-ipv6-pool/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null || echo "v1.0.0")

    if [ ! -f "$BINARY" ]; then
        log "尝试从 GitHub Releases 下载 $LATEST_VERSION 版本..."
        wget -q "https://github.com/Mrio233/go-ipv6-pool/releases/download/${LATEST_VERSION}/${BINARY}" -O /opt/$BINARY 2>/dev/null

        if [ $? -ne 0 ] || [ ! -s "/opt/$BINARY" ]; then
            log "下载失败，尝试从源码编译..."
            rm -f /opt/$BINARY

            # 检查 Go 是否安装
            if ! command -v go &> /dev/null; then
                log "安装 Go 环境..."
                wget -q https://go.dev/dl/go1.21.5.linux-${ARCH}.tar.gz -O /tmp/go.tar.gz
                tar -C /usr/local -xzf /tmp/go.tar.gz
                rm /tmp/go.tar.gz
                export PATH=$PATH:/usr/local/go/bin
                echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
            fi

            # 克隆并编译
            log "克隆仓库并编译..."
            cd /tmp
            rm -rf go-ipv6-pool
            git clone --depth=1 https://github.com/Mrio233/go-ipv6-pool.git 2>&1 | tee -a ${CURRENT_DIR}/install.log
            cd go-ipv6-pool

            # 设置 Go 代理（国内加速）
            export GOPROXY=https://goproxy.cn,direct
            export CGO_ENABLED=0
            go build -ldflags="-s -w" -o /opt/$BINARY .

            if [ $? -ne 0 ]; then
                echo -e "${RED}编译失败，请检查网络或手动编译${NC}"
                return 1
            fi

            log "编译成功"
            cd /opt
            rm -rf /tmp/go-ipv6-pool
        fi

        chmod +x /opt/$BINARY
    fi

    # 创建 systemd 服务
    cat > /etc/systemd/system/ipv6-proxy-pool.service << SVCEOF
[Unit]
Description=IPv6 Dynamic Proxy Pool (Optimized)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt
ExecStart=/opt/$BINARY --port $IPV6_PORT --cidr $IPV6_SUBNET --max-conns $MAX_CONNS
Restart=always
RestartSec=10
LimitNOFILE=1000000
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable ipv6-proxy-pool.service > /dev/null 2>&1
    systemctl stop ipv6-proxy-pool 2>/dev/null
    systemctl start ipv6-proxy-pool

    sleep 3
    if systemctl is-active --quiet ipv6-proxy-pool; then
        log "IPv6 代理池启动成功 (端口: $IPV6_PORT, 最大连接: $MAX_CONNS)"
        echo "$IPV6_PORT" > /opt/ipv6_proxy_port
        echo "$IPV6_SUBNET" > /opt/ipv6_subnet
        echo "$MAX_CONNS" > /opt/ipv6_max_conns
    else
        echo -e "${RED}警告：IPv6 代理启动失败，请检查日志${NC}"
        journalctl -u ipv6-proxy-pool --no-pager -n 20
        return 1
    fi

    # 防火墙
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && ufw allow $IPV6_PORT/tcp > /dev/null 2>&1
    command -v iptables &>/dev/null && iptables -I INPUT -p tcp --dport $IPV6_PORT -j ACCEPT 2>/dev/null

    export IPV6_PORT_SET=$IPV6_PORT
    return 0
}

# ==================== 获取 IP 信息 ====================
function Get_IP_Info(){
    active_interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {print $5}')
    if [[ -z $active_interface ]]; then
        LOCAL_IP="127.0.0.1"
    else
        LOCAL_IP=`ip -4 addr show dev "$active_interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1`
        [[ -z "$LOCAL_IP" ]] && LOCAL_IP="127.0.0.1"
    fi

    PUBLIC_IP=$(curl -s -4 https://api4.ipify.org 2>/dev/null || curl -s -4 ip.sb 2>/dev/null || echo "N/A")

    IPV6_PUB=$(ip -6 addr show dev $active_interface 2>/dev/null | grep "scope global" | grep -v "temporary" | awk '{print $2}' | cut -d'/' -f1 | head -1)
    [[ -z "$IPV6_PUB" ]] && IPV6_PUB="N/A"
}

# ==================== 展示结果 ====================
function Show_Result(){
    IPV6_PORT=$(cat /opt/ipv6_proxy_port 2>/dev/null || echo "33001")
    IPV6_SUBNET=$(cat /opt/ipv6_subnet 2>/dev/null || echo "N/A")
    MAX_CONNS=$(cat /opt/ipv6_max_conns 2>/dev/null || echo "50000")

    log_section "[3/3] 安装完成！"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${CYAN}          IPv4 代理池 (SOCKS5)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "协议类型: ${YELLOW}SOCKS5${NC}"
    echo -e "代理地址: ${YELLOW}socks5://$PANEL_USERNAME:$PANEL_PASSWORD@$PUBLIC_IP:$PANEL_PORT${NC}"
    echo -e "本地地址: ${YELLOW}socks5://$PANEL_USERNAME:$PANEL_PASSWORD@$LOCAL_IP:$PANEL_PORT${NC}"
    echo -e "使用说明: ${CYAN}支持 TCP/UDP 代理，需认证${NC}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${CYAN}          IPv6 代理池 (HTTP/SOCKS5)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "协议类型: ${YELLOW}HTTP + SOCKS5${NC}"
    echo -e "HTTP代理: ${YELLOW}http://$PUBLIC_IP:$IPV6_PORT${NC}"
    echo -e "SOCKS5:  ${YELLOW}socks5://$PUBLIC_IP:$((IPV6_PORT + 1))${NC}"
    echo -e "出口特征: ${YELLOW}动态 IPv6 出口 ($IPV6_SUBNET)${NC}"
    echo -e "最大连接: ${YELLOW}$MAX_CONNS 并发${NC}"
    echo -e "测试命令: ${CYAN}curl -x http://$PUBLIC_IP:$IPV6_PORT ipv6.ip.sb${NC}"
    echo -e "使用说明: ${CYAN}每请求轮换 IPv6 出口，无需认证${NC}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${YELLOW}重要提示：${NC}"
    echo -e "1. 如果使用的是云服务器，请至安全组开放 ${PANEL_PORT} 和 ${IPV6_PORT}-${IPV6_PORT+1} 端口"
    echo -e "2. IPv6 代理需要服务器拥有 /64 子网才能正常工作"
    echo -e "3. 查看日志: ${CYAN}docker logs -f chatgpt-proxy-node${NC} (IPv4)"
    echo -e "            ${CYAN}journalctl -u ipv6-proxy-pool -f${NC} (IPv6)"
    echo -e "4. 查看状态: ${CYAN}systemctl status ipv6-proxy-pool${NC}"
    echo -e "5. 重启服务: ${CYAN}systemctl restart ipv6-proxy-pool${NC}"
    echo -e "${GREEN}========================================${NC}"

    echo -e "\n${CYAN}性能优化说明：${NC}"
    echo -e "- 已修复内存泄漏问题"
    echo -e "- 已添加连接超时控制 (10s 连接, 30s IO)"
    echo -e "- 已添加并发连接数限制 ($MAX_CONNS)"
    echo -e "- 已启用连接池复用"
    echo -e "- 已添加优雅关闭支持"
}

# ==================== 主函数 ====================
function main(){
    Check_Root

    echo -e "${YELLOW}>>> 准备安装 IPv4 + IPv6 双栈代理池...${NC}\n"

    # 系统优化
    Set_System_Limits

    # 基础安装
    Install_Docker
    Install_Compose

    # 配置 IPv4
    Set_IPV4_Port
    Set_IPV4_Credentials
    Init_IPV4_Proxy

    # 配置 IPv6
    Setup_IPV6_Proxy

    # 获取信息并展示
    Get_IP_Info
    Show_Result
}

main
