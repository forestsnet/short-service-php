#!/usr/bin/env bash
set -euo pipefail

# ── Short Service PHP — Interactive Setup Script ─────────────────────────────
# Supports: Debian 12/13, Ubuntu 22.04/24.04
# Run as root: bash setup.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/short"
REPO_URL="https://github.com/forestsnet/short-service-php.git"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply
        echo "${reply:-$default}"
    else
        read -rp "$(echo -e "${CYAN}$prompt${NC}: ")" reply
        echo "$reply"
    fi
}

confirm() {
    local prompt="$1" reply
    read -rp "$(echo -e "${YELLOW}$prompt [y/N]:${NC} ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root (sudo bash setup.sh)"
}

# ── Detect PHP version ──────────────────────────────────────────────────────

detect_php_version() {
    if command -v php &>/dev/null; then
        php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;'
        return
    fi
    # Check available packages
    for ver in 8.4 8.3 8.2; do
        if apt-cache show "php${ver}" &>/dev/null 2>&1; then
            echo "$ver"
            return
        fi
    done
    echo "8.3"
}

# ── Step 1: System Update ───────────────────────────────────────────────────

step_update() {
    info "Updating system packages..."
    apt update -y
    apt upgrade -y
    success "System updated."
}

# ── Step 2: Install Dependencies ────────────────────────────────────────────

step_deps() {
    local php_ver="$1"
    info "Installing Apache, PHP ${php_ver}, and tools..."

    apt install -y \
        apache2 \
        php${php_ver} \
        php${php_ver}-fpm \
        php${php_ver}-sqlite3 \
        php${php_ver}-mbstring \
        certbot \
        python3-certbot-apache \
        git \
        curl

    success "Dependencies installed."
}

# ── Step 3: Enable Apache Modules ───────────────────────────────────────────

step_apache_modules() {
    local php_ver="$1"
    info "Enabling Apache modules..."
    a2enmod rewrite headers proxy_fcgi setenvif ssl
    a2enconf "php${php_ver}-fpm" 2>/dev/null || true
    systemctl restart apache2 "php${php_ver}-fpm"
    success "Apache modules enabled."
}

# ── Step 4: Deploy Application ──────────────────────────────────────────────

step_deploy() {
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Existing installation found at ${INSTALL_DIR}, pulling updates..."
        git -C "$INSTALL_DIR" pull --ff-only
    else
        info "Cloning repository to ${INSTALL_DIR}..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi

    chown -R www-data:www-data "$INSTALL_DIR"
    chmod -R 755 "$INSTALL_DIR"
    chmod 775 "$INSTALL_DIR/storage"

    success "Application deployed to ${INSTALL_DIR}."
}

# ── Step 5: Configure Application ───────────────────────────────────────────

step_config() {
    local domain="$1" api_key="$2"
    local config_file="${INSTALL_DIR}/config.local.php"

    info "Generating config.local.php..."

    local api_key_line="'api_key' => '',"
    if [[ -n "$api_key" ]]; then
        api_key_line="'api_key' => '${api_key}',"
    fi

    cat > "$config_file" <<PHPEOF
<?php

return [
    'base_url' => 'https://${domain}',
    'db_path' => __DIR__ . '/storage/db.sqlite',
    'token_length' => 5,
    'token_charset' => 'yhnujmikolp',
    'rate_limit' => [
        'enabled' => true,
        'max_requests' => 5,
        'window_seconds' => 60,
        'whitelist' => [],
    ],
    ${api_key_line}
    'allowed_domains' => [],
];
PHPEOF

    chown www-data:www-data "$config_file"
    chmod 640 "$config_file"
    success "Configuration saved."
}

# ── Step 6: Apache Virtual Host ─────────────────────────────────────────────

step_vhost() {
    local domain="$1" php_ver="$2"
    local vhost_file="/etc/apache2/sites-available/short.conf"

    info "Creating Apache virtual host for ${domain}..."

    cat > "$vhost_file" <<VHOSTEOF
<VirtualHost *:80>
    ServerName ${domain}
    DocumentRoot ${INSTALL_DIR}/public

    <Directory ${INSTALL_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:/run/php/php${php_ver}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "no-referrer"

    ErrorLog  \${APACHE_LOG_DIR}/short-error.log
    CustomLog \${APACHE_LOG_DIR}/short-access.log combined
</VirtualHost>
VHOSTEOF

    a2ensite short.conf
    a2dissite 000-default.conf 2>/dev/null || true
    systemctl reload apache2

    success "Virtual host configured."
}

# ── Step 7: SSL Certificate ─────────────────────────────────────────────────

step_ssl() {
    local domain="$1"
    info "Requesting SSL certificate for ${domain}..."
    certbot --apache -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email || {
        warn "Certbot failed. You can run it manually later: certbot --apache -d ${domain}"
        return
    }
    systemctl enable certbot.timer
    success "SSL certificate installed."
}

# ── Step 8: Enable Services ─────────────────────────────────────────────────

step_enable() {
    local php_ver="$1"
    systemctl enable apache2 "php${php_ver}-fpm"
    success "Services enabled for autostart."
}

# ── Step 9: Verify ──────────────────────────────────────────────────────────

step_verify() {
    local domain="$1"
    info "Running verification..."

    local url="https://${domain}/generate-token"
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url" \
        -H 'Content-Type: application/json' \
        -d '{"url":"https://example.com"}' 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^(201|401)$ ]]; then
        success "Service is responding (HTTP ${http_code})."
    else
        warn "Got HTTP ${http_code} — check logs: tail /var/log/apache2/short-error.log"
    fi
}

# ── Interactive Menu ─────────────────────────────────────────────────────────

menu() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Short Service PHP — Setup Wizard       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  1) Full install (recommended for fresh servers)"
    echo "  2) Install dependencies only"
    echo "  3) Deploy/update application only"
    echo "  4) Configure application"
    echo "  5) Setup Apache virtual host"
    echo "  6) Issue SSL certificate"
    echo "  7) Verify installation"
    echo "  0) Exit"
    echo ""
}

full_install() {
    local domain php_ver api_key

    domain=$(ask "Enter your domain" "s.example.com")
    php_ver=$(detect_php_version)
    info "Detected PHP version: ${php_ver}"

    if confirm "Protect link generation with an API key?"; then
        api_key=$(ask "Enter API key")
    else
        api_key=""
    fi

    echo ""
    info "Starting full installation..."
    echo ""

    step_update
    step_deps "$php_ver"
    step_apache_modules "$php_ver"
    step_deploy
    step_config "$domain" "$api_key"
    step_vhost "$domain" "$php_ver"

    if confirm "Issue SSL certificate now? (domain must point to this server)"; then
        step_ssl "$domain"
    else
        warn "Skipping SSL. Run later: certbot --apache -d ${domain}"
    fi

    step_enable "$php_ver"
    step_verify "$domain"

    echo ""
    success "Installation complete!"
    echo -e "  URL:    ${GREEN}https://${domain}${NC}"
    echo -e "  Config: ${GREEN}${INSTALL_DIR}/config.local.php${NC}"
    echo -e "  Logs:   ${GREEN}/var/log/apache2/short-*.log${NC}"
    if [[ -n "$api_key" ]]; then
        echo -e "  API key: ${GREEN}${api_key}${NC}"
        echo -e "  Usage:   ${CYAN}curl -X POST https://${domain}/generate-token -H 'X-Api-Key: ${api_key}' ...${NC}"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_root

    while true; do
        menu
        local choice
        read -rp "Select option: " choice

        case "$choice" in
            1) full_install ;;
            2)
                local php_ver
                php_ver=$(detect_php_version)
                step_update
                step_deps "$php_ver"
                step_apache_modules "$php_ver"
                step_enable "$php_ver"
                ;;
            3) step_deploy ;;
            4)
                local domain api_key
                domain=$(ask "Enter your domain" "s.example.com")
                if confirm "Protect with API key?"; then
                    api_key=$(ask "Enter API key")
                else
                    api_key=""
                fi
                step_config "$domain" "$api_key"
                ;;
            5)
                local domain php_ver
                domain=$(ask "Enter your domain" "s.example.com")
                php_ver=$(detect_php_version)
                step_vhost "$domain" "$php_ver"
                ;;
            6)
                local domain
                domain=$(ask "Enter your domain" "s.example.com")
                step_ssl "$domain"
                ;;
            7)
                local domain
                domain=$(ask "Enter your domain" "s.example.com")
                step_verify "$domain"
                ;;
            0) info "Bye!"; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

main "$@"
