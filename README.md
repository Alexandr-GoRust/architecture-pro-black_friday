# «Мобильный мир»: масштабирование к «чёрной пятнице» — проектная работа спринта 4

Стенд онлайн-магазина, подготовленный к распродаже: шардированная MongoDB с репликацией, кеширование в Redis, а также схемы масштабирования (API Gateway, Consul, CDN) и архитектурный документ.

## Структура репозитория

| Путь | Что это | Задание |
|---|---|---|
| `mongo-sharding/` | Стенд с шардированием MongoDB (2 шарда + configSrv + роутер) | 1 (шаг 1), 2 |
| `mongo-sharding-repl/` | + репликация: каждый шард — Replicaset из 3 узлов | 1 (шаг 2), 3 |
| `sharding-repl-cache/` | **Финальный стенд** (проверять здесь): + Redis, паттерн Cache Aside | 1 (шаг 3), 2, 3, 4 |
| `schemas.drawio` | Пять схем эволюции системы (5 страниц): шардирование → репликация → кеш → API Gateway + Consul → итоговая с CDN | 1, 5, 6 |
| `Tasks_7-10_architecture.md` | Архитектурный документ: шард-ключи коллекций, горячие шарды, чтение с реплик, миграция на Cassandra | 7, 8, 9, 10 |
| `api_app/`, `compose.yaml`, `scripts/` | Исходный стенд Практикума (не изменён) | — |

## Как поднять финальный стенд (задания 2–4)

Для проверки используется директория `sharding-repl-cache`:

```shell
cd sharding-repl-cache
docker compose up -d
```

Дождитесь, пока все контейнеры станут здоровыми:

```shell
docker compose ps
```

Выполните инициализацию кластера (настройка Replicaset, подключение шардов, включение шардирования, наполнение данными):

```shell
./scripts/cache-init.sh
```

## Как проверить

**Приложение** — [http://localhost:8080](http://localhost:8080): JSON со статусом `OK`, топологией `Sharded`, списком шардов со всеми репликами, количеством документов (`1000`) и `"cache_enabled": true`.

**Количество документов в каждом шарде**:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Ожидаемо ~500/500 (шард-ключ `{ name: "hashed" }`).

**Количество реплик** (в каждом шарде 1 PRIMARY + 2 SECONDARY):

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))
EOF
```

**Кеширование** — повторные вызовы кешируемого эндпоинта выполняются <100 мс:

```shell
curl -o /dev/null -s -w "первый вызов: %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -o /dev/null -s -w "повторный:    %{time_total}s\n" http://localhost:8080/helloDoc/users
```

Первый вызов ~1 с (чтение из MongoDB), повторные ~10 мс (из Redis).

## Схемы (задания 1, 5, 6)

`schemas.drawio` — открыть в [draw.io](https://app.diagrams.net). Пять страниц соответствуют шагам проектной работы:

1. `1-sharding` — шардирование: `pymongo-api` → `mongos_router` → `configSrv` + 2 шарда;
2. `2-replication` — группы репликации: Replicaset «shard1» и «shard2» по 3 узла;
3. `3-cache` — добавлен `redis` (Cache Aside);
4. `4-gateway-discovery` — горизонтальное масштабирование приложения: API Gateway (балансировка) + Consul (Service Discovery);
5. `5-final-cdn` — **итоговая схема**: всё вышеперечисленное + CDN в точках присутствия и источник статики.

## Архитектурный документ (задания 7–10)

`Tasks_7-10_architecture.md` — схемы коллекций `products`/`orders`/`carts` с выбором шард-ключей и командами, метрики и механизмы борьбы с «горячими» шардами, таблица чтения primary/secondary с допустимыми задержками репликации, модель данных Cassandra (partition/clustering keys, CQL) и стратегии восстановления целостности (Hinted Handoff / Read Repair / Anti-Entropy).

## Доступные эндпоинты приложения

- `/` — статус кластера и кеша (JSON);
- `/{collection}/count` — количество документов;
- `/{collection}/users` — кешируемый список (Cache Aside);
- `/docs` — Swagger.
