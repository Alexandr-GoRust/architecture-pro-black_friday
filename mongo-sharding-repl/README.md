# mongo-sharding-repl — MongoDB с шардированием и репликацией (Задание 3)

Стенд «Мобильного мира»: два шарда, каждый — Replicaset из трёх узлов (отказоустойчивость: при потере узла набор реплик выбирает новый primary и продолжает работать). Плюс сервер конфигурации и роутер `mongos`.

Состав шардов:

| Шард | Узлы (Replicaset) |
|---|---|
| `shard1` | `shard1-1:27018` (первичный при инициализации), `shard1-2`, `shard1-3` |
| `shard2` | `shard2-1:27019` (первичный при инициализации), `shard2-2`, `shard2-3` |

## Запуск

```shell
docker compose up -d
```

Дождитесь, пока все контейнеры станут здоровыми (`docker compose ps`), затем выполните настройку репликации и шардирования:

```shell
./scripts/repl-init.sh
```

Скрипт выполняет шаги, описанные ниже (то же самое можно проделать вручную).

## Шаги настройки репликации для каждого шарда

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

### 2. Инициализация набора реплик первого шарда

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
```

Команда выполняется на одном узле будущего набора: узел инициирует Replicaset `shard1`, остальные два узла присоединяются как члены набора. Через несколько секунд узлы проводят выборы — `shard1-1` становится primary, `shard1-2` и `shard1-3` — secondary.

### 3. Инициализация набора реплик второго шарда

```shell
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

### 4. Подключение шардов к роутеру и включение шардирования

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })
EOF
```

В `sh.addShard` передаётся имя Replicaset и список её членов — так роутер узнаёт обо всех репликах шарда.

### 5. Наполнение тестовыми данными

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i})
db.helloDoc.countDocuments()
EOF
```

## Проверка

Приложение: [http://localhost:8080](http://localhost:8080) — JSON со статусом `OK`, топологией `Sharded`, списком шардов (со всеми репликами в хостах шардов) и общим количеством документов (1000).

Количество документов в каждом шарде:

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

Состояние наборов реплик (количество реплик, primary/secondary):

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))
EOF
```

Каждый шард показывает трёх членов набора: один `PRIMARY` и два `SECONDARY`. Реплики хранят копию данных шарда — при отказе primary набор автоматически выбирает новый из secondary.
