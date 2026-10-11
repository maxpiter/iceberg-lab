#!/bin/sh
# Разовая генерация секретов стенда (запускается сервисом secrets-init).
# Ничего не перезаписывает: если файлы уже есть, выходит сразу.
set -eu
cd /secrets

if [ ! -f nginx.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout nginx.key -out nginx.crt \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
  echo "nginx: self-signed certificate created"
else
  echo "nginx: certificate already exists"
fi

if [ ! -f trino-shared-secret ]; then
  openssl rand -base64 512 | tr -d '\n' > trino-shared-secret
  echo "trino: shared secret created"
else
  echo "trino: shared secret already exists"
fi

# nginx и trino читают файлы под своими пользователями
chmod 644 nginx.crt nginx.key trino-shared-secret
