#!/usr/bin/env bash
# Respaldo diario de todas las bases del MySQL en docker (nexolu-mysql-1).
# Deja /opt/respaldos/db/<fecha>/<base>.sql.gz + SHA256SUMS y conserva 14 dias.
# Instalado el 2026-10-16 al apagar el droplet legacy. Ver nexolu-infra/scripts/.
set -euo pipefail
DEST=/opt/respaldos/db
DIA=$(date +%F)
RETENER_DIAS=${RETENER_DIAS:-14}
mkdir -p "$DEST/$DIA"; chmod 700 /opt/respaldos
bases=$(docker exec nexolu-mysql-1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "show databases"' 2>/dev/null \
  | grep -v -E '^(mysql|sys|information_schema|performance_schema)$')
for db in $bases; do
  docker exec nexolu-mysql-1 sh -c "mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --routines --triggers --events --set-gtid-purged=OFF --no-tablespaces --databases $db" 2>/dev/null \
    | gzip -6 > "$DEST/$DIA/$db.sql.gz.tmp"
  mv "$DEST/$DIA/$db.sql.gz.tmp" "$DEST/$DIA/$db.sql.gz"
done
(cd "$DEST/$DIA" && sha256sum *.sql.gz > SHA256SUMS)
find "$DEST" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENER_DIAS" -exec rm -rf {} +
echo "$(date -Is) ok $(du -sh "$DEST/$DIA" | cut -f1) $bases" >> /var/log/respaldo-bases.log
