<?php

declare(strict_types=1);

namespace ShortService;

class Config
{
    private static array $data = [];

    public static function load(string $path): void
    {
        if (!file_exists($path)) {
            throw new \RuntimeException("Config file not found: {$path}");
        }

        self::$data = require $path;
    }

    public static function get(string $key, mixed $default = null): mixed
    {
        $keys  = explode('.', $key);
        $value = self::$data;

        foreach ($keys as $segment) {
            if (!is_array($value) || !array_key_exists($segment, $value)) {
                return $default;
            }
            $value = $value[$segment];
        }

        return $value;
    }
}
