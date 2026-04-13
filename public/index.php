<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/Config.php';
require_once __DIR__ . '/../src/Database.php';
require_once __DIR__ . '/../src/RateLimiter.php';
require_once __DIR__ . '/../src/UrlShortener.php';
require_once __DIR__ . '/../src/Router.php';

use ShortService\Config;
use ShortService\Database;
use ShortService\RateLimiter;
use ShortService\Router;
use ShortService\UrlShortener;

// ── Security headers ─────────────────────────────────────────────────────────
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: SAMEORIGIN');
header('X-XSS-Protection: 1; mode=block');
header('Referrer-Policy: no-referrer');
header('Content-Security-Policy: default-src \'none\'');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, GET, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');

// ── Bootstrap ────────────────────────────────────────────────────────────────
ini_set('display_errors', '0');
error_reporting(E_ALL);

$configPath = file_exists(__DIR__ . '/../config.local.php')
    ? __DIR__ . '/../config.local.php'
    : __DIR__ . '/../config.php';

Config::load($configPath);

$db = new Database(Config::get('db_path'));

$rateLimiter = new RateLimiter(
    pdo:           $db->pdo(),
    maxRequests:   (int) Config::get('rate_limit.max_requests', 5),
    windowSeconds: (int) Config::get('rate_limit.window_seconds', 60),
    whitelist:     (array) Config::get('rate_limit.whitelist', []),
);

$shortener = new UrlShortener(
    pdo:            $db->pdo(),
    baseUrl:        (string) Config::get('base_url'),
    tokenLength:    (int) Config::get('token_length', 5),
    charset:        (string) Config::get('token_charset', 'yhnujmikolp'),
    allowedDomains: (array) Config::get('allowed_domains', []),
);

// ── Dispatch ─────────────────────────────────────────────────────────────────
(new Router($shortener, $rateLimiter))->dispatch();
