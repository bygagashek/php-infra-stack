<?php

declare(strict_types=1);

/*
 * Demo application: one write to the primary, reads from the replica, a Redis counter.
 *   GET /        records a visit and shows what each backend sees
 *   GET /health  readiness of every dependency, 503 if any is down
 */

function pdo(string $host): PDO
{
    return new PDO(
        sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $host, getenv('DB_NAME')),
        (string) getenv('DB_USER'),
        (string) getenv('DB_PASSWORD'),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 2],
    );
}

function redis(): Redis
{
    $redis = new Redis();
    $redis->connect((string) getenv('REDIS_HOST'), 6379, 1.0);

    return $redis;
}

/**
 * @param array<string, mixed> $data
 */
function respond(int $status, array $data): never
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
    exit;
}

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

if ($path === '/health') {
    $checks = [
        'primary' => fn () => pdo((string) getenv('DB_PRIMARY_HOST'))->query('SELECT 1'),
        'replica' => fn () => pdo((string) getenv('DB_REPLICA_HOST'))->query('SELECT 1'),
        'redis' => fn () => redis()->ping(),
    ];
    $result = [];
    foreach ($checks as $name => $check) {
        try {
            $check();
            $result[$name] = 'ok';
        } catch (Throwable $e) {
            error_log("health: $name: " . $e->getMessage());
            $result[$name] = 'down';
        }
    }
    respond(in_array('down', $result, true) ? 503 : 200, $result);
}

if ($path !== '/') {
    respond(404, ['error' => 'Not found.']);
}

$primary = pdo((string) getenv('DB_PRIMARY_HOST'));
$replica = pdo((string) getenv('DB_REPLICA_HOST'));

$primary->prepare('INSERT INTO visits (path) VALUES (?)')->execute([$path]);
$id = (int) $primary->lastInsertId();

// The replica applies the write asynchronously, so right after the insert it may not have it yet.
// This is why reads that must see the user's own write go to the primary (read-your-writes).
$stmt = $replica->prepare('SELECT COUNT(*) FROM visits WHERE id = ?');
$stmt->execute([$id]);
$seenByReplica = (bool) $stmt->fetchColumn();

respond(200, [
    'visit_id' => $id,
    'replica_has_it_immediately' => $seenByReplica,
    'visits_on_primary' => (int) $primary->query('SELECT COUNT(*) FROM visits')->fetchColumn(),
    'visits_on_replica' => (int) $replica->query('SELECT COUNT(*) FROM visits')->fetchColumn(),
    'redis_hits' => redis()->incr('hits'),
    'php_worker' => gethostname() . ':' . getmypid(),
    'opcache' => function_exists('opcache_get_status') && (opcache_get_status(false)['opcache_enabled'] ?? false),
]);
