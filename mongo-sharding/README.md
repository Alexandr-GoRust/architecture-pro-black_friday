# mongo-sharding — MongoDB с шардированием (Задание 2)

Стенд «Мобильного мира» с шардированной MongoDB: два шарда, сервер конфигурации и роутер `mongos`. Приложение `pymongo-api` подключается к кластеру через роутер.

## Запуск

```shell
docker compose up -d
```

Дождитесь, пока все контейнеры станут здоровыми (`docker compose ps`), затем выполните инициализацию шардирования:

```shell
./scripts/sharding-init.sh
```

Скрипт выполняет шаги, описанные ниже (то же самое можно проделать вручную).

## Шаги инициализации шардирования

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

### 2. Инициализация шардов

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate(
  {
    _id: "shard1",
    members: [
      { _id: 0, host: "shard1:27018" }
    ]
  }
)
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate(
  {
    _id: "shard2",
    members: [
      { _id: 1, host: "shard2:27019" }
    ]
  }
)
EOF
```

Шард в MongoDB — это Replicaset, поэтому каждый шард инициализируется командой `rs.initiate` со своим именем набора реплик (`shard1`, `shard2`).

### 3. Подключение шардов к роутеру и включение шардирования

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })
EOF
```

- `sh.addShard` регистрирует наборы реплик шардов в кластере;
- `sh.enableSharding("somedb")` включает шардирование для базы `somedb`;
- `sh.shardCollection` назначает коллекции `helloDoc` шард-ключ `{ name: "hashed" }` — хэшированное шардирование даёт равномерное распределение документов по шардам (значения `name` монотонно растут, диапазонное шардирование привело бы к hot spot на последнем шарде).

### 4. Наполнение тестовыми данными

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i})
db.helloDoc.countDocuments()
EOF
```

## Проверка

Приложение: [http://localhost:8080](http://localhost:8080) — JSON со статусом `OK`, топологией `Sharded`, списком шардов и общим количеством документов (1000).

Количество документов в каждом шарде:

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Сумма по шардам равна общему количеству документов; благодаря хэшированному шард-ключу документы распределяются примерно поровну (~500/500).
