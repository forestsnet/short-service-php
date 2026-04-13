<?php

/**
 * Short Service — Configuration
 * Copy this file to config.local.php and adjust values.
 * config.local.php is gitignored and never committed.
 */

return [
    // Base domain for generated short URLs (no trailing slash)
    'base_url' => 'https://s.fwp.cc',

    // Path to SQLite database file
    'db_path' => __DIR__ . '/storage/db.sqlite',

    // Token settings
    'token_length'  => 5,
    'token_charset' => 'yhnujmikolp',

    // Rate limiting
    'rate_limit' => [
        'enabled'       => true,
        'max_requests'  => 5,       // per window
        'window_seconds'=> 60,
        'whitelist'     => [        // IPs that bypass rate limiting
            '64.227.116.91',
        ],
    ],

    // Allowed redirect domains (empty = allow all)
    'allowed_domains' => [],
];
