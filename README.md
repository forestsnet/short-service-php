# short-service-php

A lightweight URL shortener written in pure PHP 8.3 with SQLite.  
No frameworks, no Composer — just drop it on any Apache + PHP-FPM server.

## Features

- Short token generation (configurable charset & length)
- Permanent short links (same URL always returns the same token)
- Usage counter per token
- SQLite-based rate limiting (5 requests/min per IP by default)
- IP whitelist for rate limit bypass
- Optional API key authentication for link generation
- Optional domain allowlist for redirect targets
- CORS headers out of the box
- Security headers (CSP, X-Frame-Options, X-Content-Type-Options, etc.)

## API

### `POST /generate-token`

Create or retrieve a short token for a URL.

**Request**
```json
{
  "url": "https://example.com/very/long/path",
  "domain": "https://s.fwp.cc",   // optional, overrides base_url
  "view": false                    // optional, wraps URL in viewer
}
```

**Response `201`**
```json
{
  "token": "yhjmk",
  "url": "https://s.fwp.cc/yhjmk"
}
```

**Headers** (if `api_key` is configured):
```
X-Api-Key: your-secret-key
```

**Response `401`** — invalid or missing API key  
**Response `429`** — rate limit exceeded  
**Response `400`** — missing or invalid URL  
**Response `403`** — domain not in allowlist

---

### `GET /{token}`

Redirect to the original URL.

```
GET /yhjmk  →  302  Location: https://example.com/very/long/path
```

**Response `404`** — token not found

---

## Quick Start (Automated)

One-liner for a fresh Debian/Ubuntu server — no need to clone first:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/forestsnet/short-service-php/main/setup.sh)
```

Or clone and run locally:

```bash
git clone https://github.com/forestsnet/short-service-php.git /opt/short
sudo bash /opt/short/setup.sh
```

The interactive wizard will guide you through domain setup, API key, Apache, SSL, and verification.

## Quick Start (Manual)

```bash
# Clone
git clone https://github.com/forestsnet/short-service-php.git /opt/short
cd /opt/short

# Copy config
cp config.php config.local.php
# Edit config.local.php — set base_url, db_path, etc.

# Fix permissions
chown -R www-data:www-data storage/
chmod 755 storage/
```

See [INSTALL.md](INSTALL.md) for full manual Debian 13 setup with Apache and SSL.

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `base_url` | `https://s.fwp.cc` | Base URL for generated short links |
| `db_path` | `storage/db.sqlite` | Path to SQLite database |
| `token_length` | `5` | Token character count |
| `token_charset` | `yhnujmikolp` | Characters used in tokens |
| `rate_limit.enabled` | `true` | Enable rate limiting |
| `rate_limit.max_requests` | `5` | Max requests per window |
| `rate_limit.window_seconds` | `60` | Rate limit window (seconds) |
| `rate_limit.whitelist` | `[]` | IPs that bypass rate limiting |
| `api_key` | `''` | API key for generating links (empty = no auth) |
| `allowed_domains` | `[]` | Allowed redirect domains (empty = all) |

## File Structure

```
short-service-php/
├── public/
│   ├── index.php       # Entry point (pointed to by Apache DocumentRoot)
│   └── .htaccess       # Rewrite rules
├── src/
│   ├── Config.php      # Config loader
│   ├── Database.php    # PDO + SQLite migrations
│   ├── RateLimiter.php # SQLite-based rate limiting
│   ├── Router.php      # Request routing & handlers
│   └── UrlShortener.php# Token generation & resolution
├── storage/
│   └── .gitkeep        # db.sqlite lives here (gitignored)
├── config.php          # Default config (commit-safe template)
├── config.local.php    # Your real config (gitignored)
├── setup.sh            # Interactive setup wizard
├── .htaccess           # Root → public/ redirect
├── .gitignore
├── README.md
└── INSTALL.md
```

## Requirements

- PHP 8.3+ with extensions: `pdo_sqlite`, `mbstring`
- Apache 2.4+ with modules: `rewrite`, `headers`
- Certbot (for SSL)

## License

MIT
