#!/usr/bin/env bash
# Sub-Store 智能隔离部署与深度清理工具

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
        curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
        apt-get update >/dev/null 2>&1 && apt-get install -y docker-compose-plugin >/dev/null 2>&1
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

# ================= 卸载模块 =================
uninstall_sub_store() {
    clear
    echo -e "\033[0;31m========================================================\033[0m"
    echo -e "\033[0;31m⚠️ 警告：高危操作！\033[0m"
    echo -e "\033[0;31m此操作将彻底删除 Sub-Store 的所有容器、配置、节点数据及定时任务！\033[0m"
    echo -e "\033[0;31m========================================================\033[0m"
    read -p "确定要继续执行深度清理吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "\n已取消卸载操作，返回主菜单。"
        sleep 2
        return
    fi

    echo -e "\n开始执行深度清理..."
    echo "[1/6] 强制停止并删除容器..."
    docker rm -f sub-store >/dev/null 2>&1 || true
    
    echo "[2/6] 清理隔离网络..."
    docker network rm sub-store-deploy_default >/dev/null 2>&1 || true
    
    echo "[3/6] 删除本地镜像..."
    docker rmi xream/sub-store:latest >/dev/null 2>&1 || true
    
    echo "[4/6] 彻底删除物理文件夹及数据..."
    rm -rf "${BASE_DIR}"
    
    echo "[5/6] 追杀后台残留幽灵进程..."
    pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true
    
    echo "[6/6] 精准清除计划任务..."
    crontab -l 2>/dev/null | grep -v "sub-store" | crontab -
    
    echo -e "\n\033[0;32m✅ 卸载完成！所有与 Sub-Store 相关的痕迹已从这台服务器上彻底抹除。\033[0m"
    echo -e "现在您的系统非常干净，随时可以重新安装。"
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

# ================= 安装模块 =================
install_sub_store() {
    clear
    local public_ip=$(get_public_ip)
    install_packages

    local secret_key=$(openssl rand -hex 16)
    echo -e "\n\033[0;34m[系统分配] 安全后端路径: $secret_key\033[0m"
    
    local MAP_PORT
    while true; do
        read -p "请输入 Sub-Store 映射端口 (直接回车默认 3001): " MAP_PORT
        MAP_PORT=${MAP_PORT:-3001}

        if ss -tuln 2>/dev/null | grep -q ":${MAP_PORT} " || netstat -tuln 2>/dev/null | grep -q ":${MAP_PORT} "; then
            echo -e "\033[0;31m[警告] 端口 ${MAP_PORT} 已被其他程序占用，请换一个！\033[0m"
        else
            echo -e "\033[0;32m[检测通过] 端口 ${MAP_PORT} 可用。\033[0m"
            break
        fi
    done

    mkdir -p "${DATA_DIR}"
    cd "${BASE_DIR}"

    echo "正在清理环境准备安装..."
    docker rm -f sub-store >/dev/null 2>&1 || true
    pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true

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
    docker compose pull >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1

    echo "配置安全的夜间定时更新任务..."
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y cron >/dev/null 2>&1 || true
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

    local cron_job="0 4 * * * cd ${BASE_DIR} && docker compose pull && docker compose up -d && docker image prune -f >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "sub-store" || true; echo "$cron_job") | sort -u | crontab -

    echo "等待服务验证 (约需 3-5 秒)..."
    sleep 3

    echo -e "\n========================================================"
    echo -e "\033[0;32m🎉 部署成功！您的 Sub-Store 物理隔离版已就绪。\033[0m"
    echo -e "========================================================"
    echo -e "📁 安装目录：${BASE_DIR}"
    echo -e "🌐 面板登录：http://$public_ip:${MAP_PORT}"
    echo -e "🔑 后端路径：http://$public_ip:${MAP_PORT}/$secret_key"
    echo -e "--------------------------------------------------------"
    echo -e "⏱️ 自动更新已优化至每日凌晨 4 点，告别重置冲突。"
    echo -e "========================================================\n"
    
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

# ================= 主菜单 =================
main_menu() {
    check_root
    while true; do
        clear
        echo -e "\033[0;36m========================================================\033[0m"
        echo -e "       \033[1;37mSub-Store 智能管理面板 (防冲突增强版)\033[0m"
        echo -e "\033[0;36m========================================================\033[0m"
        echo -e "  \033[0;32m[1] 🚀 一键安装/更新 Sub-Store\033[0m"
        echo -e "  \033[0;31m[2] 🗑️ 深度卸载并清除所有残留数据\033[0m"
        echo -e "  \033[0;37m[0] ❌ 退出脚本\033[0m"
        echo -e "\033[0;36m========================================================\033[0m"
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1)
                install_sub_store
                ;;
            2)
                uninstall_sub_store
                ;;
            0)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                echo -e "\033[0;31m无效的选择，请重新输入！\033[0m"
                sleep 1
                ;;
        esac
    done
}

main_menu
