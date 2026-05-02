#!/usr/bin/env bash
# Sub-Store 真·一键部署终极版 (全自动 HTTPS + 证书记忆 + 热重载)

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

# ================= 核心：一键大满贯安装 =================
install_sub_store() {
    clear
    local public_ip=$(get_public_ip)
    install_packages

    local secret_key=$(openssl rand -hex 16)
    echo -e "\n\033[0;34m[系统分配] 安全后端路径: $secret_key\033[0m"
    
    mkdir -p "${DATA_DIR}"
    cd "${BASE_DIR}"

    echo -e "\n\033[1;33m是否启用 HTTPS 安全访问？\033[0m"
    echo "选 y: 自动申请证书并配置内置 Nginx (一键直达 HTTPS，不开小黄云完美适用)"
    echo "选 n: 仅使用纯 HTTP 端口映射 (极简模式)"
    read -p "请选择 (y/n): " USE_SSL

    if [[ "$USE_SSL" == "y" || "$USE_SSL" == "Y" ]]; then
        # ---------------- HTTPS 自动装配向导 ----------------
        read -p "1. 请手工输入绑定的域名 (如 store.zhao0479.org): " DOMAIN
        if [ -z "$DOMAIN" ]; then echo -e "\033[0;31m域名不能为空！退出。\033[0m"; sleep 2; return; fi

        local CURRENT_TOKEN=""
        if [ -f "$CF_TOKEN_FILE" ]; then
            CURRENT_TOKEN=$(cat "$CF_TOKEN_FILE")
            echo -e "\033[0;32m[检测] 已发现本地 CF 令牌，自动调用。\033[0m"
        else
            read -p "2. 请粘贴 Cloudflare API Token: " USER_TOKEN
            if [ -z "$USER_TOKEN" ]; then echo -e "\033[0;31mToken不能为空！退出。\033[0m"; sleep 2; return; fi
            echo "$USER_TOKEN" > "$CF_TOKEN_FILE"
            chmod 600 "$CF_TOKEN_FILE"
            CURRENT_TOKEN=$USER_TOKEN
        fi

        read -p "3. 请输入 HTTPS 对外访问端口 (直接回车默认 443): " HTTPS_PORT
        HTTPS_PORT=${HTTPS_PORT:-443}

        if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
            echo "正在安装 acme.sh 证书管家..."
            apt-get update >/dev/null 2>&1; apt-get install -y socat curl >/dev/null 2>&1
            curl https://get.acme.sh | sh -s email=admin@${DOMAIN} >/dev/null 2>&1
        fi

        export CF_Token="${CURRENT_TOKEN}"
        echo -e "\n开始为您申请证书，请稍候 (约需1-2分钟)..."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
        
        if ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force; then
            CERT_DIR="/root/certs/${DOMAIN}"
            mkdir -p "$CERT_DIR"
            # 划重点：加入 reloadcmd，续期自动重启 Nginx，终身免维护
            ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
                --key-file       "$CERT_DIR/private.key"  \
                --fullchain-file "$CERT_DIR/fullchain.crt" \
                --reloadcmd      "docker restart sub-store-ssl >/dev/null 2>&1" >/dev/null 2>&1
            echo -e "\033[0;32m🎉 证书申请成功！\033[0m"
        else
            echo -e "\n\033[0;31m❌ 证书申请失败，请检查 Token 或域名配置。\033[0m"; sleep 3; return
        fi

        echo "正在清理环境..."
        docker rm -f sub-store sub-store-ssl >/dev/null 2>&1 || true
        pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true

        echo "正在生成 Nginx 代理配置..."
        cat <<EOF > nginx.conf
server {
    listen 443 ssl;
    server_name ${DOMAIN};
    ssl_certificate /etc/nginx/certs/fullchain.crt;
    ssl_certificate_key /etc/nginx/certs/private.key;
    location / {
        proxy_pass http://sub-store:3001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

        echo "正在生成组合 Docker 容器 (Sub-Store + Nginx)..."
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
    volumes:
      - ${DATA_DIR}:/opt/app/data

  nginx-ssl:
    image: nginx:alpine
    container_name: sub-store-ssl
    restart: always
    ports:
      - "${HTTPS_PORT}:443"
    volumes:
      - /root/certs/${DOMAIN}:/etc/nginx/certs:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - sub-store
EOF
        # 记录成功后的访问地址
        FINAL_URL="https://${DOMAIN}:${HTTPS_PORT}"
        FINAL_API="https://${DOMAIN}:${HTTPS_PORT}/${secret_key}"

    else
        # ---------------- 纯 HTTP 模式 ----------------
        read -p "请输入 Sub-Store 映射端口 (默认 3001): " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-3001}

        echo "正在清理环境..."
        docker rm -f sub-store sub-store-ssl >/dev/null 2>&1 || true
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
      - "${HTTP_PORT}:3001"
    volumes:
      - ${DATA_DIR}:/opt/app/data
EOF
        FINAL_URL="http://${public_ip}:${HTTP_PORT}"
        FINAL_API="http://${public_ip}:${HTTP_PORT}/${secret_key}"
    fi

    echo "拉取镜像并启动项目..."
    docker compose pull >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1

    # 配置每日凌晨4点自动更新任务
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y cron >/dev/null 2>&1 || true
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
    local cron_job="0 4 * * * cd ${BASE_DIR} && docker compose pull && docker compose up -d && docker image prune -f >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "sub-store" || true; echo "$cron_job") | sort -u | crontab -

    sleep 3
    echo -e "\n========================================================"
    echo -e "\033[0;32m🎉 完美部署成功！一键到位！\033[0m"
    echo -e "========================================================"
    echo -e "📁 安装目录：${BASE_DIR}"
    echo -e "🌐 面板登录：${FINAL_URL}"
    echo -e "🔑 后端路径：${FINAL_API}"
    echo -e "--------------------------------------------------------"
    if [[ "$USE_SSL" == "y" || "$USE_SSL" == "Y" ]]; then
        echo -e "🔒 状态：内置 Nginx 已启动，HTTPS 已挂载！"
        echo -e "⏱️ 证书续期：已配置热重载，到期自动无感更新。"
    fi
    echo -e "========================================================\n"
    
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

# ================= 卸载模块 =================
uninstall_sub_store() {
    clear
    echo -e "\033[0;31m========================================================\033[0m"
    echo -e "\033[0;31m⚠️ 警告：此操作将删除所有配置、证书和容器！\033[0m"
    echo -e "\033[0;31m========================================================\033[0m"
    read -p "确定要彻底铲除吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker rm -f sub-store sub-store-ssl >/dev/null 2>&1 || true
        docker network rm sub-store-deploy_default >/dev/null 2>&1 || true
        rm -rf "${BASE_DIR}"
        pkill -9 -f sub-store.bundle.js >/dev/null 2>&1 || true
        crontab -l 2>/dev/null | grep -v "sub-store" | crontab -
        echo -e "\n\033[0;32m✅ 卸载干净！\033[0m"
    fi
    sleep 2
}

# ================= 主菜单 =================
main_menu() {
    check_root
    while true; do
        clear
        echo -e "\033[0;36m========================================================\033[0m"
        echo -e "       \033[1;37mSub-Store 真·一键大满贯 (自带Nginx+HTTPS)\033[0m"
        echo -e "\033[0;36m========================================================\033[0m"
        echo -e "  \033[0;32m[1] 🚀 一键安装部署 (按向导选择 HTTPS/HTTP)\033[0m"
        echo -e "  \033[0;31m[2] 🗑️ 彻底卸载铲除\033[0m"
        echo -e "  \033[0;37m[0] ❌ 退出脚本\033[0m"
        echo -e "\033[0;36m========================================================\033[0m"
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1) install_sub_store ;;
            2) uninstall_sub_store ;;
            0) echo "感谢使用！"; exit 0 ;;
            *) echo -e "\033[0;31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

main_menu
