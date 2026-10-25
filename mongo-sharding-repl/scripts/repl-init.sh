#!/bin/bash
# Инициализация шардированного кластера MongoDB с репликацией (по 3 реплики на шард).
# Запускать ПОСЛЕ docker compose up -d, когда все контейнеры здоровы.

set -e

echo "=== 1. Инициализация сервера конфигурации (configSrv) ==="
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

echo "=== 2. Инициализация набора реплик shard1 (shard1-1, shard1-2, shard1-3) ==="
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

echo "=== 3. Инициализация набора реплик shard2 (shard2-1, shard2-2, shard2-3) ==="
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

echo "=== 4. Ожидание выборов primary в наборах реплик (15 сек) ==="
sleep 15

echo "=== 5. Подключение шардов к роутеру и включение шардирования ==="
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })
EOF

echo "=== 6. Наполнение БД тестовыми данными (1000 документов) ==="
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i})
db.helloDoc.countDocuments()
EOF

echo "=== Готово. Откройте http://localhost:8080 ==="
