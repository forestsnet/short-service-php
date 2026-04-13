<?php

declare(strict_types=1);

namespace ShortService;

class UrlShortener
{
    public function __construct(
        private readonly \PDO   $pdo,
        private readonly string $baseUrl,
        private readonly int    $tokenLength = 5,
        private readonly string $charset     = 'yhnujmikolp',
        private readonly array  $allowedDomains = [],
    ) {}

    /**
     * Generate or return existing short token for a URL.
     *
     * @return array{token: string, url: string}
     */
    public function shorten(string $originalUrl): array
    {
        $url = $this->resolveUrl($originalUrl);

        $this->validateUrl($url);

        // Return existing token if URL already shortened
        $stmt = $this->pdo->prepare('SELECT token FROM tokens WHERE url = :url');
        $stmt->execute([':url' => $url]);
        $existing = $stmt->fetchColumn();

        if ($existing !== false) {
            return [
                'token' => $existing,
                'url'   => "{$this->baseUrl}/{$existing}",
            ];
        }

        $token = $this->generateUniqueToken();

        $this->pdo->prepare(
            'INSERT INTO tokens (token, url) VALUES (:token, :url)'
        )->execute([':token' => $token, ':url' => $url]);

        return [
            'token' => $token,
            'url'   => "{$this->baseUrl}/{$token}",
        ];
    }

    /**
     * Resolve redirect URL for a token.
     * Returns null if token not found.
     */
    public function resolve(string $token): ?string
    {
        $stmt = $this->pdo->prepare(
            'SELECT url FROM tokens WHERE token = :token'
        );
        $stmt->execute([':token' => $token]);
        $url = $stmt->fetchColumn();

        if ($url === false) {
            return null;
        }

        $this->pdo->prepare(
            'UPDATE tokens SET used = used + 1 WHERE token = :token'
        )->execute([':token' => $token]);

        return $url;
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private function resolveUrl(string $originalUrl): string
    {
        // view=true wrapping is handled by the caller if needed;
        // here we accept the final target URL as-is
        return $originalUrl;
    }

    private function validateUrl(string $url): void
    {
        if (!filter_var($url, FILTER_VALIDATE_URL)) {
            throw new \InvalidArgumentException('Invalid URL format.');
        }

        if (!empty($this->allowedDomains)) {
            $host = parse_url($url, PHP_URL_HOST) ?? '';
            $allowed = false;
            foreach ($this->allowedDomains as $domain) {
                if (str_contains($host, $domain)) {
                    $allowed = true;
                    break;
                }
            }
            if (!$allowed) {
                throw new \DomainException("Domain not allowed: {$host}");
            }
        }
    }

    private function generateUniqueToken(): string
    {
        do {
            $token = $this->generateToken();
            $stmt  = $this->pdo->prepare(
                'SELECT COUNT(*) FROM tokens WHERE token = :token'
            );
            $stmt->execute([':token' => $token]);
        } while ($stmt->fetchColumn() > 0);

        return $token;
    }

    private function generateToken(): string
    {
        $max   = strlen($this->charset) - 1;
        $token = '';
        for ($i = 0; $i < $this->tokenLength; $i++) {
            $token .= $this->charset[random_int(0, $max)];
        }
        return $token;
    }
}
