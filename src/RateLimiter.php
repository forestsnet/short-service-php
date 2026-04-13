<?php

declare(strict_types=1);

namespace ShortService;

class RateLimiter
{
    public function __construct(
        private readonly \PDO $pdo,
        private readonly int  $maxRequests,
        private readonly int  $windowSeconds,
        private readonly array $whitelist = [],
    ) {}

    /**
     * Check and record a request.
     * Returns true if allowed, false if rate limited.
     */
    public function check(string $ip): bool
    {
        if (in_array($ip, $this->whitelist, true)) {
            return true;
        }

        $now = time();

        $stmt = $this->pdo->prepare(
            'SELECT count, window_start FROM rate_limits WHERE ip = :ip'
        );
        $stmt->execute([':ip' => $ip]);
        $row = $stmt->fetch();

        if (!$row || ($now - $row['window_start']) >= $this->windowSeconds) {
            // New window
            $this->pdo->prepare(
                'INSERT INTO rate_limits (ip, count, window_start)
                 VALUES (:ip, 1, :ws)
                 ON CONFLICT(ip) DO UPDATE SET count = 1, window_start = :ws'
            )->execute([':ip' => $ip, ':ws' => $now]);

            return true;
        }

        if ($row['count'] >= $this->maxRequests) {
            return false;
        }

        $this->pdo->prepare(
            'UPDATE rate_limits SET count = count + 1 WHERE ip = :ip'
        )->execute([':ip' => $ip]);

        return true;
    }
}
