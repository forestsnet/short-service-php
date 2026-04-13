# Installation Guide — Debian 13

## Requirements

- Debian 13 (Trixie) or Ubuntu 24.04
- Root or sudo access
- Domain pointed to the server

---

## 1. Install Dependencies

```bash
apt update && apt install -y \
    apache2 \
    php8.3 \
    php8.3-fpm \
    php8.3-sqlite3 \
    php8.3-mbstring \
    certbot \
    python3-certbot-apache \
    git
```

## 2. Enable Apache Modules

```bash
a2enmod rewrite headers proxy_fcgi setenvif ssl
a2enconf php8.3-fpm
systemctl restart apache2 php8.3-fpm
```

## 3. Deploy the Application

```bash
git clone https://github.com/forestsnet/short-service-php.git /opt/short
cd /opt/short

# Create local config
cp config.php config.local.php
nano config.local.php   # Set base_url and other settings

# Set permissions
chown -R www-data:www-data /opt/short
chmod -R 755 /opt/short
chmod 775 /opt/short/storage
```

## 4. Configure Apache Virtual Host

Create `/etc/apache2/sites-available/short.conf`:

```apache
<VirtualHost *:80>
    ServerName s.fwp.cc                      # ← change to your domain
    DocumentRoot /opt/short/public

    <Directory /opt/short>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # PHP-FPM
    <FilesMatch "\.php$">
        SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "no-referrer"

    ErrorLog  ${APACHE_LOG_DIR}/short-error.log
    CustomLog ${APACHE_LOG_DIR}/short-access.log combined
</VirtualHost>
```

Enable and reload:

```bash
a2ensite short.conf
a2dissite 000-default.conf   # optional: disable default site
systemctl reload apache2
```

## 5. Issue SSL Certificate

```bash
# Issue certificate (auto-configures Apache)
certbot --apache -d s.fwp.cc       # ← your domain

# Verify auto-renewal
systemctl status certbot.timer

# Enable --reuse-key so SPKI pin never changes on renewal
sed -i 's|ExecStart=/usr/bin/certbot -q renew|ExecStart=/usr/bin/certbot -q renew --reuse-key|' \
    /lib/systemd/system/certbot.service
systemctl daemon-reload
```

> **Skip this step** if a certificate already exists — certbot will detect it.

## 6. Verify

```bash
# Test HTTP → HTTPS redirect
curl -I http://s.fwp.cc/

# Test token generation
curl -s -X POST https://s.fwp.cc/generate-token \
     -H 'Content-Type: application/json' \
     -d '{"url":"https://example.com"}' | python3 -m json.tool

# Test redirect (use the token from above)
curl -I https://s.fwp.cc/yhjmk
```

## 7. Autostart

Apache and PHP-FPM are managed by systemd and start automatically on boot:

```bash
systemctl enable apache2 php8.3-fpm
```

Check status:

```bash
systemctl status apache2
systemctl status php8.3-fpm
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `502 Bad Gateway` | Check PHP-FPM: `systemctl status php8.3-fpm` |
| `403 Forbidden` | Check ownership: `chown -R www-data /opt/short` |
| `500 Internal Server Error` | Check Apache log: `tail /var/log/apache2/short-error.log` |
| DB not writable | `chmod 775 /opt/short/storage && chown www-data /opt/short/storage` |
| `.htaccess not working` | Ensure `mod_rewrite` is enabled: `a2enmod rewrite` |
