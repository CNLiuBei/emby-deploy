#!/bin/bash
set -e

# ==== 配置参数 ====
DOMAIN="emby.liubei.org"
EMAIL="12345678@qq.com"
MYSQL_ROOT_PASS="StrongRootPass123!"
MYSQL_USER="emby"
MYSQL_PASS="EmbyPass123!"
MYSQL_DB="emby"
TIMEZONE="Asia/Shanghai"
MEDIA_DIR="/opt/emby/media"

# 管理员账号固定
EMBY_ADMIN_USER="trueliu"
EMBY_ADMIN_PASS="TrueLiu"

LIBRARY_NAME="Movies"
LIBRARY_TYPE="Movie"

# 等待 Emby 启动时间
EMBY_START_WAIT=30  # 秒

# ==== 系统更新 & 安装依赖 ====
sudo apt update && sudo apt upgrade -y
sudo apt install -y wget curl gnupg lsb-release sudo mariadb-server nginx jq socat inotify-tools

# ==== MySQL 初始化 ====
sudo systemctl enable mariadb
sudo systemctl start mariadb

mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${MYSQL_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# ==== 安装 Emby Server ====
wget https://github.com/MediaBrowser/Emby.Releases/releases/download/4.8.11.0/emby-server-deb_4.8.11.0_amd64.deb -O /tmp/emby.deb
sudo dpkg -i /tmp/emby.deb || sudo apt-get install -f -y
sudo systemctl enable emby-server
sudo systemctl start emby-server

# ==== 配置国内 TMDB 镜像 ====
sudo sed -i "s#<TmdbApiUrl>.*</TmdbApiUrl>#<TmdbApiUrl>https://tmdb.liubei.org</TmdbApiUrl>#" /var/lib/emby/config/system.xml
sudo systemctl restart emby-server

# ==== 配置 Nginx HTTPS ====
sudo mkdir -p /etc/nginx/cert

# 安装 acme.sh 并申请证书
curl https://get.acme.sh | sh
export PATH="$HOME/.acme.sh:$PATH"
~/.acme.sh/acme.sh --issue -d ${DOMAIN} --webroot /var/www/html --email ${EMAIL} --force
~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} \
    --cert-file /etc/nginx/cert/fullchain.pem \
    --key-file /etc/nginx/cert/privkey.pem \
    --reloadcmd "systemctl reload nginx"

# ==== Nginx 配置反向代理 + User-Agent限制 ====
cat > /etc/nginx/sites-available/emby <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/cert/fullchain.pem;
    ssl_certificate_key /etc/nginx/cert/privkey.pem;

    if (\$http_user_agent !~* "VidHub|Infuse|Jellyfin") {
        return 403;
    }

    location / {
        proxy_pass http://127.0.0.1:8096;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/emby /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# ==== 创建媒体目录 ====
sudo mkdir -p ${MEDIA_DIR}
sudo chown -R emby:emby ${MEDIA_DIR}

# ==== 等待 Emby 启动 ====
echo "等待 ${EMBY_START_WAIT} 秒让 Emby 完全启动..."
sleep $EMBY_START_WAIT

# ==== 创建管理员账号 ====
EMBY_API_KEY=$(curl -s -X POST "http://127.0.0.1:8096/Users/New" \
  -H "Content-Type: application/json" \
  -d "{\"Name\":\"${EMBY_ADMIN_USER}\",\"Password\":\"${EMBY_ADMIN_PASS}\",\"IsAdministrator\":true}" \
  | jq -r '.Id')

echo "管理员账号创建成功，User ID: $EMBY_API_KEY"

# ==== 创建媒体库 ====
LIBRARY_ID=$(curl -s -X POST "http://127.0.0.1:8096/Library/LibraryOptions" \
  -H "Content-Type: application/json" \
  -H "X-Emby-Token: $EMBY_API_KEY" \
  -d "{\"Name\":\"${LIBRARY_NAME}\",\"CollectionType\":\"${LIBRARY_TYPE}\",\"PathInfos\":[{\"Path\":\"${MEDIA_DIR}\"}]}")

echo "媒体库创建完成，Library ID: $LIBRARY_ID"

# ==== 首次扫描媒体库 ====
curl -X POST "http://127.0.0.1:8096/Library/Refresh?LibraryId=${LIBRARY_ID}" \
     -H "X-Emby-Token: ${EMBY_API_KEY}"

# ==== 后台监控新增文件 ====
echo "设置后台监控媒体目录，新增影视文件自动触发扫描..."
cat > /usr/local/bin/emby_auto_scan.sh <<EOF
#!/bin/bash
MEDIA_DIR="${MEDIA_DIR}"
EMBY_API_KEY="${EMBY_API_KEY}"
LIBRARY_ID="${LIBRARY_ID}"

inotifywait -m -r -e create -e moved_to -e close_write --format "%w%f" "\${MEDIA_DIR}" | while read FILE
do
    echo "检测到新文件: \${FILE}, 触发 Emby 扫描"
    curl -s -X POST "http://127.0.0.1:8096/Library/Refresh?LibraryId=\${LIBRARY_ID}" -H "X-Emby-Token: \${EMBY_API_KEY}"
done
EOF

sudo chmod +x /usr/local/bin/emby_auto_scan.sh

# ==== 设置 systemd 服务自动启动监控 ====
cat > /etc/systemd/system/emby-auto-scan.service <<EOF
[Unit]
Description=Emby Auto Scan Media Library
After=network.target emby-server.service

[Service]
Type=simple
ExecStart=/usr/local/bin/emby_auto_scan.sh
Restart=always
User=emby
Group=emby

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable emby-auto-scan
sudo systemctl start emby-auto-scan

echo "=== 部署完成 ==="
echo "访问地址: https://${DOMAIN}"
echo "管理员账号: ${EMBY_ADMIN_USER} / ${EMBY_ADMIN_PASS}"
echo "媒体目录: ${MEDIA_DIR}"
echo "媒体库已创建，新增影视文件将自动扫描抓取海报。"