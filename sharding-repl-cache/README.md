# sharding-repl-cache — финальный стенд: шардирование + репликация + кеширование (Задание 4)

Итоговая конфигурация «Мобильного мира» (решения заданий 2, 3 и 4):

- **Шардирование**: два шарда, сервер конфигурации `configSrv`, роутер `mongos_router`;
- **Репликация**: каждый шард — Replicaset из трёх узлов (`shard1-1…1-3`, `shard2-1…2-3`);
- **Кеширование**: инстанс Redis (паттерн Cache Aside), приложение подключается через переменную окружения `REDIS_URL: "redis://redis:6379"`.

## Запуск

```shell
docker compose up -d
```

Дождитесь, пока все контейнеры станут здоровыми (`docker compose ps`), затем выполните инициализацию кластера:

```shell
./scripts/cache-init.sh
```

Скрипт выполняет следующие шаги.

### 1. Инициализация сервера конфигурации

```shell
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate(
  {
    _id: "config_server",
    configsvr: true,
    members: [
      { _id: 0, host: "configSrv:27017" }
    ]
  }
)
EOF
```

### 2. Инициализация наборов реплик шардов (по 3 реплики)

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.initiate(
  {
    _id: "shard1",
    members: [
      { _id: 0, host: "shard1-1:27018" },
      { _id: 1, host: "shard1-2:27018" },
      { _id: 2, host: "shard1-3:27018" }
    ]
  }
)
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.initiate(
  {
    _id: "shard2",
    members: [
      { _id: 0, host: "shard2-1:27019" },
      { _id: 1, host: "shard2-2:27019" },
      { _id: 2, host: "shard2-3:27019" }
    ]
  }
)
EOF
```

### 3. Подключение шардов к роутеру и включение шардирования

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })
EOF
```

### 4. Наполнение тестовыми данными

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i})
db.helloDoc.countDocuments()
EOF
```

## Проверка

**Приложение**: [http://localhost:8080](http://localhost:8080) — JSON: топология `Sharded`, список шардов со всеми репликами, общее количество документов (1000) и `"cache_enabled": true`.

**Количество документов в каждом шарде** (~500/500 благодаря хэшированному шард-ключу):

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

**Количество реплик** (1 PRIMARY + 2 SECONDARY в каждом шарде):

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))
EOF
```

**Скорость кешированного эндпоинта** — первый вызов `/{collection_name}/users` идёт в MongoDB и занимает ~1 секунду, второй и последующие отдаются из Redis за <100 мс:

```shell
curl -o /dev/null -s -w "первый вызов: %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -o /dev/null -s -w "второй вызов: %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -o /dev/null -s -w "третий вызов: %{time_total}s\n" http://localhost:8080/helloDoc/users
```

Работает паттерн Cache Aside: приложение сначала проверяет Redis; при промахе читает MongoDB и кладёт результат в кеш (TTL ответа — 60 секунд).
