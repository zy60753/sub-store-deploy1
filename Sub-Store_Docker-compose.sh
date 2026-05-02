#!/usr/bin/env bash
# 已移除极易导致误杀的 set -euo pipefail 严格模式

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
    
    # === 交互式端口配置与智能冲突检测 ===
    local MAP_PORT
    while true; do
        read -p "请输入 Sub-Store 映射端口 (直接回车默认 3001): " MAP_PORT
        MAP_PORT=${MAP_PORT:-3001}

        # 检测端口是否被占用
        if ss -tuln 2>/dev/null | grep -q ":${MAP_PORT} " || netstat -tuln 2>/dev/null | grep -q ":${MAP_PORT} "; then
            echo -e "\033[0;31m[警告] 端口 ${MAP_PORT} 已被其他程序占用，请重新输入一个未被占用的端口！\033[0m"
        else
            echo -e "\033[0;32m[检测通过] 端口 ${MAP_PORT} 可用。\033[0m"
            break
        fi
    done

    # 创建绝对隔离的工作目录
    mkdir -p "${DATA_DIR}"
    cd "${BASE_DIR}"

    echo "清理旧容器、旧网络和幽灵进程..."
    docker rm -f sub-store >/dev/null 2>&1 || true
    pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true

    # 生成包含完整环境变量和动态端口的配置文件
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
      - "${MAP_PORT}:3001"
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
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y cron >/dev/null 2>&1 || true
    fi

    # 增加防误杀机制
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

    # 安全的定时任务：每天凌晨 4 点执行，且绑定绝对路径
    echo "配置安全的定时更新任务..."
    local cron_job="0 4 * * * cd ${BASE_DIR} && docker compose pull && docker compose up -d && docker image prune -f >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "sub-store" || true; echo "$cron_job") | sort -u | crontab -

    echo "等待服务启动验证 (约需 5-10 秒)..."
    for i in {1..30}; do
        if curl -s "http://127.0.0.1:${MAP_PORT}" >/dev/null; then
            echo -e "\n========================================================"
            echo -e "\033[0;32m🎉 部署成功！您的 Sub-Store 物理隔离版已就绪。\033[0m"
            echo -e "========================================================"
            echo -e "📁 安装目录：${BASE_DIR}"
            echo -e "🌐 面板登录：http://$public_ip:${MAP_PORT}"
            echo -e "🔑 后端路径：http://$public_ip:${MAP_PORT}/$secret_key"
            echo -e "--------------------------------------------------------"
            echo -e "⏱️ 自动更新已优化至每日凌晨 4 点，告别重置冲突。"
            echo -e "========================================================\n"
            return 0
        fi
        sleep 1
    done

    echo -e "\n========================================================"
    echo -e "\033[0;33m⚠️ 服务已启动，但网络验证超时。请确认服务器防火墙已放行 ${MAP_PORT} 端口。\033[0m"
    echo -e "========================================================"
    echo -e "🌐 面板登录：http://$public_ip:${MAP_PORT}"
    echo -e "🔑 后端路径：http://$public_ip:${MAP_PORT}/$secret_key"
    echo -e "========================================================\n"
}

main() {
    check_root
    public_ip=$(get_public_ip)
    install_packages
    setup_docker
}

main
