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
        read -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply </dev/tty
        echo "${reply:-$default}"
    else
        read -rp "$(echo -e "${CYAN}$prompt${NC}: ")" reply </dev/tty
        echo "$reply"
    fi
}

confirm() {
    local prompt="$1" reply
    read -rp "$(echo -e "${YELLOW}$prompt [y/N]:${NC} ")" reply </dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root (sudo bash setup.sh)"
}

# ── DNS / Network checks ───────────────────────────────────────────────────

get_server_ip() {
    # Try multiple sources for external IP
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) \
        || ip=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null) \
        || ip=""
    echo "$ip"
}

check_domain_dns() {
    local domain="$1"

    # Make sure dig/host is available (install dnsutils if missing)
    if ! command -v dig &>/dev/null; then
        apt install -y dnsutils &>/dev/null || true
    fi

    info "Checking DNS for ${domain}..."

    local server_ip
    server_ip=$(get_server_ip)
    if [[ -z "$server_ip" ]]; then
        warn "Could not determine this server's public IP. Skipping DNS check."
        return 0
    fi
    info "This server's public IP: ${server_ip}"

    # Resolve domain A/AAAA records
    local domain_ips
    domain_ips=$(dig +short A "$domain" 2>/dev/null; dig +short AAAA "$domain" 2>/dev/null)

    if [[ -z "$domain_ips" ]]; then
        warn "Domain ${domain} does not resolve to any IP address."
        warn "Make sure you have an A record pointing ${domain} -> ${server_ip}"
        if ! confirm "Continue anyway?"; then
            return 1
        fi
        return 0
    fi

    info "Domain ${domain} resolves to: $(echo $domain_ips | tr '\n' ' ')"

    # Check if any resolved IP matches our server
    local match=false
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" == "$server_ip" ]]; then
            match=true
            break
        fi
    done <<< "$domain_ips"

    if $match; then
        success "Domain ${domain} correctly points to this server (${server_ip})."
    else
        warn "Domain ${domain} does NOT point to this server."
        warn "  Domain resolves to: $(echo $domain_ips | tr '\n' ' ')"
        warn "  This server's IP:   ${server_ip}"
        warn "SSL certificate will fail if the domain is not pointed here."
        if ! confirm "Continue anyway?"; then
            return 1
        fi
    fi
    return 0
}

check_port_open() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -q ":${port} "; then
            return 0
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp | grep -q ":${port} "; then
            return 0
        fi
    fi
    return 1
}

check_http_reachable() {
    local domain="$1"
    info "Checking if http://${domain} is reachable from outside..."

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${domain}/" 2>/dev/null || echo "000")

    if [[ "$http_code" == "000" ]]; then
        warn "Could not reach http://${domain}/ — connection failed."
        warn "Check that port 80 is open in your firewall (ufw, iptables, cloud security group)."

        if check_port_open 80; then
            info "Port 80 is listening locally — the issue is likely an external firewall or security group."
        else
            warn "Port 80 is NOT listening locally. Is Apache running?"
        fi

        if ! confirm "Continue anyway?"; then
            return 1
        fi
    else
        success "http://${domain}/ is reachable (HTTP ${http_code})."
    fi
    return 0
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
    local domain="$1" skip_checks="${2:-false}"

    if [[ "$skip_checks" != "true" ]]; then
        check_domain_dns "$domain" || return 1
        check_http_reachable "$domain" || return 1
    fi

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
    echo -e "  ${GREEN}1) Guided install with API key (recommended)${NC}"
    echo "  2) Full install (quick, optional API key)"
    echo "  ──────────────────────────────────"
    echo "  3) Install dependencies only"
    echo "  4) Deploy/update application only"
    echo "  5) Configure application"
    echo "  6) Setup Apache virtual host"
    echo "  7) Check domain DNS"
    echo "  8) Issue SSL certificate"
    echo "  9) Verify installation"
    echo "  0) Exit"
    echo ""
}

generate_api_key() {
    # Generate a random 32-char hex key
    head -c 32 /dev/urandom | xxd -p | head -c 32
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

    echo ""
    if check_domain_dns "$domain" && check_http_reachable "$domain"; then
        if confirm "DNS looks good. Issue SSL certificate now?"; then
            step_ssl "$domain" true
        else
            warn "Skipping SSL. Run later: certbot --apache -d ${domain}"
        fi
    else
        warn "Skipping SSL due to DNS/connectivity issues."
        warn "Fix DNS, then run: certbot --apache -d ${domain}"
    fi

    step_enable "$php_ver"
    step_verify "$domain"

    print_summary "$domain" "$api_key"
}

guided_install() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Guided Setup — step by step with API key    ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo ""

    local domain php_ver api_key

    # ── 1. Domain ────────────────────────────────────────────────────────────
    domain=$(ask "Enter your domain (e.g. s.example.com)")
    [[ -z "$domain" ]] && { error "Domain is required."; return; }

    # ── 2. DNS pre-check ─────────────────────────────────────────────────────
    echo ""
    info "Step 1/8 — Checking DNS for ${domain}..."
    if ! check_domain_dns "$domain"; then
        warn "You can fix DNS and re-run this later."
        return
    fi

    # ── 3. API key ───────────────────────────────────────────────────────────
    echo ""
    info "Step 2/8 — API key setup"
    echo -e "  An API key protects ${CYAN}POST /generate-token${NC} from unauthorized use."
    echo ""
    echo "  1) Generate random key automatically"
    echo "  2) Enter my own key"
    echo "  3) Skip (no protection)"
    echo ""
    local key_choice
    read -rp "  Choose [1]: " key_choice </dev/tty
    key_choice="${key_choice:-1}"

    case "$key_choice" in
        1)
            api_key=$(generate_api_key)
            success "Generated API key: ${api_key}"
            ;;
        2)
            api_key=$(ask "Enter your API key")
            [[ -z "$api_key" ]] && { warn "Empty key — skipping API protection."; api_key=""; }
            ;;
        *) api_key="" ;;
    esac

    # ── 4. System update & deps ──────────────────────────────────────────────
    echo ""
    info "Step 3/8 — System update & dependencies"
    if ! confirm "Update system and install Apache, PHP, certbot?"; then
        warn "Cannot continue without dependencies."; return
    fi
    php_ver=$(detect_php_version)
    info "PHP version: ${php_ver}"
    step_update
    step_deps "$php_ver"

    # ── 5. Apache modules ────────────────────────────────────────────────────
    echo ""
    info "Step 4/8 — Apache modules"
    step_apache_modules "$php_ver"

    # ── 6. Deploy app ────────────────────────────────────────────────────────
    echo ""
    info "Step 5/8 — Deploy application"
    step_deploy

    # ── 7. Config ────────────────────────────────────────────────────────────
    echo ""
    info "Step 6/8 — Application configuration"
    step_config "$domain" "$api_key"

    # ── 8. Virtual host ──────────────────────────────────────────────────────
    echo ""
    info "Step 7/8 — Apache virtual host"
    step_vhost "$domain" "$php_ver"

    # ── 9. SSL ───────────────────────────────────────────────────────────────
    echo ""
    info "Step 8/8 — SSL certificate"
    if check_http_reachable "$domain"; then
        step_ssl "$domain" true
    else
        warn "Skipping SSL. Fix connectivity, then run: certbot --apache -d ${domain}"
    fi

    # ── 10. Enable & verify ──────────────────────────────────────────────────
    step_enable "$php_ver"
    echo ""
    step_verify "$domain"

    print_summary "$domain" "$api_key"
}

print_summary() {
    local domain="$1" api_key="$2"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Installation complete!          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  URL:    ${GREEN}https://${domain}${NC}"
    echo -e "  Config: ${GREEN}${INSTALL_DIR}/config.local.php${NC}"
    echo -e "  Logs:   ${GREEN}/var/log/apache2/short-*.log${NC}"
    if [[ -n "$api_key" ]]; then
        echo ""
        echo -e "  API key: ${GREEN}${api_key}${NC}"
        echo ""
        echo -e "  ${CYAN}Example usage:${NC}"
        echo -e "  curl -s -X POST https://${domain}/generate-token \\"
        echo -e "       -H 'Content-Type: application/json' \\"
        echo -e "       -H 'X-Api-Key: ${api_key}' \\"
        echo -e "       -d '{\"url\":\"https://example.com\"}'"
    else
        echo ""
        echo -e "  ${YELLOW}No API key configured — anyone can generate links.${NC}"
        echo -e "  To add one later: edit ${INSTALL_DIR}/config.local.php"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_root

    while true; do
        menu
        local choice
        read -rp "Select option: " choice </dev/tty

        case "$choice" in
            1) guided_install ;;
            2) full_install ;;
            3)
                local php_ver
                php_ver=$(detect_php_version)
                step_update
                step_deps "$php_ver"
                step_apache_modules "$php_ver"
                step_enable "$php_ver"
                ;;
            4) step_deploy ;;
            5)
                local domain api_key
                domain=$(ask "Enter your domain" "s.example.com")
                if confirm "Protect with API key?"; then
                    api_key=$(ask "Enter API key")
                else
                    api_key=""
                fi
                step_config "$domain" "$api_key"
                ;;
            6)
                local domain php_ver
                domain=$(ask "Enter your domain" "s.example.com")
                php_ver=$(detect_php_version)
                step_vhost "$domain" "$php_ver"
                ;;
            7)
                local domain
                domain=$(ask "Enter your domain" "s.example.com")
                check_domain_dns "$domain"
                check_http_reachable "$domain"
                ;;
            8)
                local domain
                domain=$(ask "Enter your domain" "s.example.com")
                step_ssl "$domain"
                ;;
            9)
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
