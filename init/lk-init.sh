#!/bin/sh
# Разовая настройка каталога. Повторяет ноутбуки 01-Bootstrap и 02-Create-Warehouse
# из examples/access-control-simple. Повторный запуск ничего не ломает.
set -eu

LK=http://lakekeeper:8181/management/v1
KC_TOKEN=http://keycloak:8080/realms/iceberg/protocol/openid-connect/token

# client_id client_secret -> access_token
token() {
  curl -sSf -X POST "$KC_TOKEN" \
    -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$2" -d scope=lakekeeper \
    | sed -E 's/.*"access_token":"([^"]+)".*/\1/'
}

# Техническая учётка spark (имя из официального примера) становится первым
# администратором сервера (bootstrap) и раздаёт остальные роли.
ADMIN=$(token spark 4kj1I8W5dIOmae6ydUJl1xjvItpZeUHQ)
AUTH="Authorization: Bearer $ADMIN"

if curl -sSf -H "$AUTH" "$LK/info" | grep -q '"bootstrapped":true'; then
  echo "bootstrap: already done"
else
  curl -sSf -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"accept-terms-of-use": true}' "$LK/bootstrap"
  echo "bootstrap: done"
fi

# Технические учётки появляются в каталоге после первого обращения
register() {
  curl -sSf -o /dev/null -X POST -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d '{"update-if-exists": true}' "$LK/user"
}
register "$(token trino e5sx35mYVkG3p3dAu1IYYgfCm0wBjbIK)"
LOADER=$(token loader Dzg7qlpdBYRDVJ2HRdeYEqkFkIYSzgl6)
register "$LOADER"
echo "users trino, loader: registered"

# Идентификаторы = поле sub в токене Keycloak (id пользователя в keycloak/realm.json)
ENGINEER=oidc~cfb55bf6-fcbb-4a1e-bfec-30c6649b52f8
TRINO_ID=oidc~94eb1d88-7854-43a0-b517-a75f92c533a5
LOADER_ID=oidc~4921a5a4-4885-47ee-b24c-e786521871fb
ANALYST=oidc~d223d88c-85b6-4859-b5c5-27f3825e47f6

# Люди заводятся в каталоге заранее, по идентификатору из Keycloak, без их входа.
# Так же работает синхронизация пользователей из AD/LDAP своим скриптом.
provision() {
  curl -sSf -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"id\":\"$1\",\"name\":\"$2\",\"email\":\"$3\",\"user-type\":\"human\",\"update-if-exists\":true}" \
    "$LK/user"
}
provision "$ENGINEER" "Engineer Data" engineer@example.com
provision "$ANALYST" "Analyst Data" analyst@example.com
echo "users engineer, analyst: provisioned"

# engineer - администратор сервера и проекта, trino - администратор проекта.
# analyst прав не получает: их выдаст engineer по ходу сценария.
curl -sSf -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"writes\":[{\"type\":\"admin\",\"user\":\"$ENGINEER\"}]}" "$LK/permissions/server/assignments" \
  2>/dev/null || echo "server admin: already assigned"
curl -sSf -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"writes\":[{\"type\":\"project_admin\",\"user\":\"$ENGINEER\"},{\"type\":\"project_admin\",\"user\":\"$TRINO_ID\"}]}" \
  "$LK/permissions/project/assignments" 2>/dev/null || echo "project admins: already assigned"
echo "permissions: engineer = admin, trino = project_admin, analyst = none"

if curl -sSf -H "$AUTH" "$LK/warehouse" | grep -q '"name":"demo"'; then
  echo "warehouse demo: already exists"
else
  curl -sSf -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d @/init/create-warehouse.json "$LK/warehouse"
  echo "warehouse demo: created"
fi

# Загрузчик: создание и запись в warehouse demo, без прав администратора
WH_ID=$(curl -sSf -H "$AUTH" "$LK/warehouse" | sed -E 's/.*"warehouse-id":"([^"]+)","name":"demo".*/\1/')
curl -sSf -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"writes\":[{\"type\":\"create\",\"user\":\"$LOADER_ID\"},{\"type\":\"modify\",\"user\":\"$LOADER_ID\"}]}" \
  "$LK/permissions/warehouse/$WH_ID/assignments" 2>/dev/null || echo "loader grants: already exist"
echo "permissions: loader = create + modify on warehouse demo"
