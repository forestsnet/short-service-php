<?php

declare(strict_types=1);

namespace ShortService;

class Router
{
    public function __construct(
        private readonly UrlShortener $shortener,
        private readonly RateLimiter  $rateLimiter,
    ) {}

    public function dispatch(): void
    {
        $method = $_SERVER['REQUEST_METHOD'];
        $uri    = strtok($_SERVER['REQUEST_URI'], '?');
        $ip     = $this->clientIp();

        // Preflight CORS
        if ($method === 'OPTIONS') {
            http_response_code(204);
            exit;
        }

        // Apply rate limit to all non-GET requests
        if ($method !== 'GET' && !$this->rateLimiter->check($ip)) {
            $this->jsonResponse(['message' => 'Too many requests, try again later.'], 429);
            return;
        }

        // POST /generate-token
        if ($uri === '/generate-token' && $method === 'POST') {
            if (!$this->authenticate()) {
                $this->jsonResponse(['message' => 'Invalid or missing API key.'], 401);
                return;
            }
            $this->handleGenerate();
            return;
        }

        // GET /{token}
        if ($method === 'GET' && preg_match('~^/([a-z0-9]+)$~i', $uri, $m)) {
            $this->handleRedirect($m[1]);
            return;
        }

        $this->jsonResponse(['message' => 'Not found.'], 404);
    }

    // ── Handlers ─────────────────────────────────────────────────────────────

    private function handleGenerate(): void
    {
        $input = json_decode(file_get_contents('php://input'), true) ?? [];

        $originalUrl    = trim($input['url'] ?? '');
        $redirectDomain = trim($input['domain'] ?? Config::get('base_url'));
        $needView       = ($input['view'] ?? false) === true;

        if ($originalUrl === '') {
            $this->jsonResponse(['message' => 'URL is required.'], 400);
            return;
        }

        $targetUrl = $needView
            ? "https://s.fwp.cc/?url=" . urlencode($originalUrl)
            : $originalUrl;

        try {
            $result = $this->shortener->shorten($targetUrl);
            // Override short URL domain if caller passed custom domain
            $result['url'] = rtrim($redirectDomain, '/') . '/' . $result['token'];
            $this->jsonResponse($result, 201);
        } catch (\InvalidArgumentException $e) {
            $this->jsonResponse(['message' => $e->getMessage()], 400);
        } catch (\DomainException $e) {
            $this->jsonResponse(['message' => $e->getMessage()], 403);
        }
    }

    private function handleRedirect(string $token): void
    {
        $url = $this->shortener->resolve($token);

        if ($url === null) {
            $this->jsonResponse(['message' => 'Token not found.'], 404);
            return;
        }

        header('Location: ' . $url, true, 302);
        exit;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private function jsonResponse(array $data, int $status = 200): void
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    private function authenticate(): bool
    {
        $apiKey = Config::get('api_key', '');
        if ($apiKey === '') {
            return true;
        }
        $provided = $_SERVER['HTTP_X_API_KEY'] ?? '';
        return hash_equals($apiKey, $provided);
    }

    private function clientIp(): string
    {
        return $_SERVER['HTTP_X_FORWARDED_FOR']
            ?? $_SERVER['HTTP_X_REAL_IP']
            ?? $_SERVER['REMOTE_ADDR']
            ?? '0.0.0.0';
    }
}
