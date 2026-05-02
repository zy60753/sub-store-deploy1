#!/usr/bin/env bash
# Sub-Store 智能隔离部署、深度清理与 CF API 证书管家 (最终版)

BASE_DIR="/root/sub-store-deploy"
DATA_DIR="${BASE_DIR}/data"
CF_TOKEN_FILE="${BASE_DIR}/.cf_token"

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

# ================= 证书申请模块 (CF Token 记忆版) =================
apply_ssl() {
    clear
    echo -e "\033[0;36m========================================================\033[0m"
    echo -e "       \033[1;37m🔐 申请 SSL 证书 (Cloudflare API 记忆模式)\033[0m"
    echo -e "\033[0;36m========================================================\033[0m"
    
    # 检查本地是否已经存有 Token
    local CURRENT_TOKEN=""
    if [ -f "$CF_TOKEN_FILE" ]; then
        CURRENT_TOKEN=$(cat "$CF_TOKEN_FILE")
        echo -e "\033[0;32m[检测] 已发现本地存储的 CF 令牌，将自动调用。\033[0m"
    fi

    echo ""
    read -p "1. 请输入你要申请证书的域名 (例如 xg.zhaozhao.de): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "\033[0;31m域名不能为空！\033[0m"; sleep 2; return
    fi

    if [ -z "$CURRENT_TOKEN" ]; then
        echo -e "\n\033[0;33m首次使用需要配置令牌：\033[0m"
        read -p "2. 请粘贴你的 Cloudflare API Token: " USER_TOKEN
        if [ -z "$USER_TOKEN" ]; then
            echo -e "\033[0;31mToken 不能为空！\033[0m"; sleep 2; return
        fi
        # 保存到本地文件供以后自动使用
        mkdir -p "$BASE_DIR"
        echo "$USER_TOKEN" > "$CF_TOKEN_FILE"
        chmod 600 "$CF_TOKEN_FILE"
        CURRENT_TOKEN=$USER_TOKEN
        echo -e "\033[0;32m[已记忆] 令牌已安全存储在本地，下次申请将免输入。\033[0m"
    fi

    # 安装 acme.sh 
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo -e "\n正在安装 acme.sh 证书管家..."
        apt-get update >/dev/null 2>&1
        apt-get install -y socat curl >/dev/null 2>&1
        curl https://get.acme.sh | sh -s email=admin@${DOMAIN} >/dev/null 2>&1
    fi

    export CF_Token="${CURRENT_TOKEN}"

    echo -e "\n开始申请证书，请稍候 (约需1-2分钟)..."
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    
    if ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force; then
        CERT_DIR="/root/certs/${DOMAIN}"
        mkdir -p "$CERT_DIR"
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
            --key-file       "$CERT_DIR/private.key"  \
            --fullchain-file "$CERT_DIR/fullchain.crt" >/dev/null 2>&1

        echo -e "\n\033[0;32m🎉 证书申请成功！\033[0m"
        echo -e "你的证书已安全提取至以下路径："
        echo -e "私钥 (Key): \033[0;33m$CERT_DIR/private.key\033[0m"
        echo -e "公钥 (Crt): \033[0;33m$CERT_DIR/fullchain.crt\033[0m"
        echo -e "--------------------------------------------------------"
        echo -e "⏱️  自动续期已生效。acme.sh 将会利用本地 Token 实现无感续期。"
    else
        echo -e "\n\033[0;31m❌ 证书申请失败！\033[0m"
        echo -e "常见原因："
        echo -e "1. Token 权限不对 (必须包含 Zone:DNS:Edit 权限)。"
        echo -e "2. 域名并没有托管在 Cloudflare 上。"
        echo -e "提示：如果需更换 Token，请在卸载菜单中重置环境或手动删除 $CF_TOKEN_FILE"
    fi

    echo -e "\n按任意键返回主菜单..."
    read -n 1 -s
}

# ================= 卸载模块 =================
uninstall_sub_store() {
    clear
    echo -e "\033[0;31m========================================================\033[0m"
    echo -e "\033[0;31m⚠️ 警告：高危操作！\033[0m"
    echo -e "\033[0;31m此操作将彻底删除 Sub-Store 的所有容器、配置、节点数据及相关的记忆令牌！\033[0m"
    echo -e "\033[0;31m========================================================\033[0m"
    read -p "确定要继续执行深度清理吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "\n已取消卸载操作，返回主菜单。"
        sleep 2
        return
    fi

    echo -e "\n开始执行深度清理..."
    docker rm -f sub-store >/dev/null 2>&1 || true
    docker network rm sub-store-deploy_default >/dev/null 2>&1 || true
    docker rmi xream/sub-store:latest >/dev/null 2>&1 || true
    rm -rf "${BASE_DIR}"
    pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true
    crontab -l 2>/dev/null | grep -v "sub-store" | crontab -
    
    echo -e "\n\033[0;32m✅ 卸载完成！所有痕迹 (含本地保存的 Token) 已彻底抹除。\033[0m"
    echo -e "按任意键返回主菜单..."
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
            echo -e "\033[0;31m[警告] 端口 ${MAP_PORT} 已被占用，请换一个！\033[0m"
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

    apt-get update >/dev/null 2>&1 || true
    apt-get install -y cron >/dev/null 2>&1 || true
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

    local cron_job="0 4 * * * cd ${BASE_DIR} && docker compose pull && docker compose up -d && docker image prune -f >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "sub-store" || true; echo "$cron_job") | sort -u | crontab -

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
        echo -e "       \033[1;37mSub-Store 智能管理面板 (最终收藏版)\033[0m"
        echo -e "\033[0;36m========================================================\033[0m"
        echo -e "  \033[0;32m[1] 🚀 一键安装/更新 Sub-Store\033[0m"
        echo -e "  \033[0;31m[2] 🗑️ 深度卸载并清除所有残留数据\033[0m"
        echo -e "  \033[0;33m[3] 🔐 申请 SSL 证书 (CF API 记忆模式)\033[0m"
        echo -e "  \033[0;37m[0] ❌ 退出脚本\033[0m"
        echo -e "\033[0;36m========================================================\033[0m"
        read -p "请选择操作 [0-3]: " choice

        case $choice in
            1) install_sub_store ;;
            2) uninstall_sub_store ;;
            3) apply_ssl ;;
            0) echo "感谢使用，再见！"; exit 0 ;;
            *) echo -e "\033[0;31m无效的选择，请重新输入！\033[0m"; sleep 1 ;;
        esac
    done
}

main_menu
