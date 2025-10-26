#!/bin/bash
set -euo pipefail

########################################
# Root check & helper functions
########################################
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo -i)."
    exit 1
fi

read_default() {
    local prompt="$1"; local default="$2"; local value=""
    read -r -p "$prompt [$default]: " value
    echo "${value:-$default}"
}

sanitize_secret() { echo "$1" | tr -cd 'A-Za-z0-9._-'; }
random_hex() { openssl rand -hex 16; }

if ! command -v openssl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y openssl
fi

########################################
# 0. Interactive input
########################################
echo "[*] Collecting setup parameters"
DOMAIN_DEFAULT="invoice.example.com"
DOMAIN=$(read_default "Domain for Invoice Ninja" "$DOMAIN_DEFAULT")
APP_SCHEME_DEFAULT="https"
APP_SCHEME=$(read_default "Protocol for APP_URL (http or https)" "$APP_SCHEME_DEFAULT")
INTERNAL_PORT_DEFAULT="9001"
INTERNAL_PORT=$(read_default "Internal port (localhost -> nginx container port 80)" "$INTERNAL_PORT_DEFAULT")

DB_NAME_DEFAULT="ninja"
DB_NAME=$(read_default "MySQL database name" "$DB_NAME_DEFAULT")
DB_USER_DEFAULT="ninja"
DB_USER=$(read_default "MySQL username" "$DB_USER_DEFAULT")

RANDPASS=$(random_hex)
DB_PASS=$(sanitize_secret "$(read_default "MySQL user password" "$RANDPASS")")
RANDROOT=$(random_hex)
DB_ROOT_PASS=$(sanitize_secret "$(read_default "MySQL ROOT password (internal)" "$RANDROOT")")

ADMIN_EMAIL_DEFAULT="admin@$DOMAIN"
ADMIN_EMAIL=$(read_default "Admin login email" "$ADMIN_EMAIL_DEFAULT")
RANDADMIN=$(random_hex)
ADMIN_PASS=$(sanitize_secret "$(read_default "Admin password" "$RANDADMIN")")

APP_DEBUG_DEFAULT="false"
APP_DEBUG=$(read_default "APP_DEBUG true/false" "$APP_DEBUG_DEFAULT")
REQ_HTTPS_DEFAULT=$([[ "$APP_SCHEME" = "https" ]] && echo true || echo false)
REQ_HTTPS=$(read_default "REQUIRE_HTTPS true/false" "$REQ_HTTPS_DEFAULT")

apt install ufw
ufw allow nginx-full
ufw allow openssh
yes | ufw enable

for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove $pkg; done

sudo apt-get update
sudo apt-get install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update


systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true

########################################
# 1. Prepare repository
########################################
INSTALL_DIR="/opt/invoiceninja"
REPO_ROOT="$INSTALL_DIR/dockerfiles"
REPO_DIR="$REPO_ROOT/debian"
mkdir -p "$INSTALL_DIR"

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "[*] Cloning Invoice Ninja repo (branch debian)"
    git clone https://github.com/invoiceninja/dockerfiles.git -b debian "$REPO_ROOT"
else
    echo "[*] Updating repository"
    cd "$REPO_ROOT"
    git fetch origin debian
    git checkout debian
    git reset --hard origin/debian
fi
cd "$REPO_DIR"

########################################
# 2. Stop existing containers (cleanup)
########################################
echo "[*] Stopping any running Docker containers"
docker compose down --remove-orphans --volumes || true
docker ps -q | xargs -r docker stop || true
docker container prune -f || true
docker network prune -f || true

########################################
# 3. Patch docker-compose.yml (127.0.0.1 binding)
########################################
echo "[*] Patching docker-compose.yml to bind internally"
if grep -q '80:80' docker-compose.yml; then
    sed -i "s/80:80/127.0.0.1:${INTERNAL_PORT}:80/g" docker-compose.yml
    echo "[+] Patched mapping to 127.0.0.1:${INTERNAL_PORT}:80"
else
    echo "[*] No 80:80 mapping found; skipping patch."
fi

########################################
# 4. Pull image & generate APP_KEY
########################################
echo "[*] Pulling latest Invoice Ninja image"
docker pull invoiceninja/invoiceninja-debian:latest
echo "[*] Generating APP_KEY"
APP_KEY=$(docker run --rm -i invoiceninja/invoiceninja-debian php artisan key:generate --show 2>/dev/null | grep -o 'base64:.*' | tr -d '\r\n')
[ -z "$APP_KEY" ] && { echo "ERROR: APP_KEY generation failed"; exit 1; }

########################################
# 5. Write .env
########################################
ENV_FILE="$REPO_DIR/.env"
echo "[*] Writing .env -> $ENV_FILE"
cat >"$ENV_FILE" <<EOF
APP_ENV=production
APP_URL=${APP_SCHEME}://${DOMAIN}/
APP_KEY=${APP_KEY}
APP_DEBUG=${APP_DEBUG}
REQUIRE_HTTPS=${REQ_HTTPS}

IN_USER_EMAIL=${ADMIN_EMAIL}
IN_PASSWORD=${ADMIN_PASS}

DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
DB_ROOT_PASSWORD=${DB_ROOT_PASS}

MYSQL_USER=${DB_USER}
MYSQL_PASSWORD=${DB_PASS}
MYSQL_DATABASE=${DB_NAME}
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}

CACHE_DRIVER=redis
SESSION_DRIVER=redis
REDIS_HOST=redis
TRUSTED_PROXIES=*
EOF

########################################
# 6. Bring up stack
########################################
echo "[*] Starting Invoice Ninja Docker stack"
docker compose up -d

########################################
# 7. Ensure nginx base config & availability
########################################
echo "[*] Installing and configuring Nginx + Certbot"
apt-get install -y nginx certbot python3-certbot-nginx >/dev/null 2>&1

# ensure valid base config
NGINX_CONF_MAIN="/etc/nginx/nginx.conf"
if ! grep -q "include /etc/nginx/sites-enabled/" "$NGINX_CONF_MAIN"; then
    echo "[!] Rebuilding nginx.conf to include sites-enabled"
    cat >"$NGINX_CONF_MAIN" <<'CONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768; }

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
CONF
fi

# stop any docker-proxy on port 80
echo "[*] Checking for docker-proxy on port 80"
docker ps --filter "publish=80" --format "{{.ID}} {{.Names}}" | while read -r ID NAME; do
    [ -n "$ID" ] && echo "    -> Stopping $NAME" && docker stop "$ID" >/dev/null 2>&1 || true
done
sleep 2

systemctl enable nginx
systemctl restart nginx
sleep 2
systemctl is-active --quiet nginx || { echo "[!] Nginx failed to start"; exit 1; }
echo "[+] Nginx service active"

########################################
# 8. Create reverse proxy & SSL
########################################
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}.conf"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html
cat >"$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
}
EOF

ln -sf "$NGINX_SITE" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
nginx -t && systemctl reload nginx

echo "[*] Requesting Let's Encrypt certificate for ${DOMAIN}"
if certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" --redirect >/dev/null 2>&1; then
    echo "[+] SSL certificate successfully issued for ${DOMAIN}"
    systemctl reload nginx
else
    echo "[!] Let's Encrypt certificate request failed; check /var/log/letsencrypt/"
fi

########################################
# 9. Final info
########################################
echo
echo "======================================================================="
echo "Invoice Ninja is now running with HTTPS reverse proxy and Let's Encrypt."
echo
echo "Access URL: https://${DOMAIN}"
echo "Internal (container): http://127.0.0.1:${INTERNAL_PORT}/"
echo
echo "Database:"
echo "  Name: ${DB_NAME}"
echo "  User: ${DB_USER}"
echo "  Pass: ${DB_PASS}"
echo "  RootPW: ${DB_ROOT_PASS}"
echo
echo "Login:"
echo "  Email: ${ADMIN_EMAIL}"
echo "  Pass:  ${ADMIN_PASS}"
echo
echo "SSL auto-renewal via systemd timer (certbot)"
echo "======================================================================="
