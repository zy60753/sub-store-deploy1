#!/usr/bin/env bash
set -euo pipefail

# 1. 定义安全隔离的绝对路径
BASE_DIR="/root/sub-store-deploy"
DATA_DIR="${BASE_DIR}/data"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "运行脚本需要 root 权限" >&2
        exit 1
    fi
}

install_packages() {
    if ! command -v docker &> /dev/null; then
        echo "正在安装 Docker 和 Docker Compose..."
        if ! curl -fsSL https://get.docker.com | bash; then
            echo "Docker 安装失败" >&2
            exit 1
        fi
        if ! apt-get update && apt-get install -y docker-compose-plugin; then
            echo "Docker Compose 安装失败" >&2
            exit 1
        fi
        echo "Docker 和 Docker Compose 安装完成。"
    else
        echo "Docker 和 Docker Compose 已安装。"
    fi
}

get_public_ip() {
    local ip_services=("ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "ipecho.net/plain" "ident.me")
    local public_ip
    for service in "${ip_services[@]}"; do
        if public_ip=$(curl -sS --connect-timeout 5 "$service"); then
            if [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$public_ip"
                return 0
            fi
        fi
        sleep 1
    done
    echo "无法获取公共 IP 地址。" >&2
    exit 1
}

setup_docker() {
    local secret_key
    secret_key=$(openssl rand -hex 16)
    echo "生成的安全后端路径: $secret_key"
    
    # 2. 创建绝对隔离的工作目录
    mkdir -p "${DATA_DIR}"
    cd "${BASE_DIR}"

    echo "清理旧容器、旧网络和幽灵进程..."
    docker rm -f sub-store >/dev/null 2>&1 || true
    # 3. 斩杀抢占 3001 端口的原生 Node 幽灵进程
    pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true

    # 4. 生成包含完整环境变量的配置文件
    cat <<EOF > docker-compose.yml
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: always
    environment:
      - SUB_STORE_BACKEND_UPLOAD_CRON=55 23 * * *
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$secret_key
      - SUB_STORE_BACKEND_API_PATH=/$secret_key
      - SUB_STORE_BACKEND_API_TOKEN=$secret_key
    ports:
      - "3001:3001"
    volumes:
      - ${DATA_DIR}:/opt/app/data
EOF

    echo "拉取最新镜像并启动容器..."
    docker compose pull
    docker compose up -d

    echo "正在清理未使用的镜像和缓存..."
    docker image prune -f >/dev/null 2>&1 || true

    if ! command -v cron &>/dev/null; then
        echo "安装 cron..."
        apt-get update >/dev/null 2>&1
        apt-get install -y cron >/dev/null 2>&1
    fi

    systemctl enable cron >/dev/null 2>&1
    systemctl start cron

    # 5. 安全的定时任务：每天凌晨 4 点执行，且绑定绝对路径
    echo "配置安全的定时更新任务..."
    local cron_job="0 4 * * * cd ${BASE_DIR} && docker compose pull && docker compose up -d && docker image prune -f >/dev/null 2>&1"
    
    # 清理掉旧的危险定时任务，写入新的安全任务
    (crontab -l 2>/dev/null | grep -v "sub-store" || true; echo "$cron_job") | sort -u | crontab -

    echo "等待服务启动..."
    for i in {1..30}; do
        if curl -s "http://127.0.0.1:3001" >/dev/null; then
            echo -e "\n========================================================"
            echo -e "\033[0;32m部署成功！您的 Sub-Store 物理隔离版已就绪。\033[0m"
            echo -e "========================================================"
            echo -e "安装目录：${BASE_DIR}"
            echo -e "Sub-Store 面板：http://$public_ip:3001"
            echo -e "后端地址：http://$public_ip:3001/$secret_key"
            echo -e "--------------------------------------------------------"
            echo -e "定时更新已安全优化至每日凌晨 4 点，不再引发重置冲突。"
            echo -e "========================================================\n"
            return 0
        fi
        sleep 1
    done

    echo "警告: 服务似乎未能在预期时间内启动，请检查端口是否被其他项目占用。"
    echo -e "\n备用信息："
    echo -e "后端地址：http://$public_ip:3001/$secret_key\n"
}

main() {
    check_root
    public_ip=$(get_public_ip)
    install_packages
    setup_docker
}

trap 'echo "错误发生在第 $LINENO 行"; exit 1' ERR
main
