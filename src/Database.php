<?php

declare(strict_types=1);

namespace ShortService;

class Database
{
    private \PDO $pdo;

    public function __construct(string $dbPath)
    {
        $dir = dirname($dbPath);
        if (!is_dir($dir) && !mkdir($dir, 0755, true)) {
            throw new \RuntimeException("Cannot create database directory: {$dir}");
        }

        $this->pdo = new \PDO("sqlite:{$dbPath}");
        $this->pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $this->pdo->setAttribute(\PDO::ATTR_DEFAULT_FETCH_MODE, \PDO::FETCH_ASSOC);

        $this->migrate();
    }

    public function pdo(): \PDO
    {
        return $this->pdo;
    }

    private function migrate(): void
    {
        $this->pdo->exec("
            CREATE TABLE IF NOT EXISTS tokens (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                token      TEXT    UNIQUE NOT NULL,
                url        TEXT    NOT NULL,
                used       INTEGER DEFAULT 0,
                created_at INTEGER DEFAULT (strftime('%s','now'))
            )
        ");

        $this->pdo->exec("
            CREATE TABLE IF NOT EXISTS rate_limits (
                ip         TEXT    PRIMARY KEY,
                count      INTEGER NOT NULL DEFAULT 1,
                window_start INTEGER NOT NULL
            )
        ");
    }
}
