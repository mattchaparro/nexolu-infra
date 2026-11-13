#!/usr/bin/env bash
# Respaldo diario (03:00, cron de root) del droplet del POS. Se instala copiando
# este archivo a /usr/local/bin/respaldo-bases.sh. Restaurar: docs/RESPALDOS.md.
#
# 1. Vuelca cada base del MySQL en docker (nexolu-mysql-1) a
#    /opt/respaldos/db/<fecha>/<base>.sql.gz.
# 2. Empaqueta el "sistema", lo que no está en git: los .env, nginx,
#    certificados, crontab, llaves SSH, storage del Spa, sitios de /var/www sin
#    git y los cambios sin commit de los que sí lo tienen ->
#    /opt/respaldos/db/<fecha>/sistema.tar.gz. Todo con SHA256SUMS.
# 3. Cifra la carpeta del día (AES-256, clave en /root/.respaldo-clave) y la
#    sube a Spaces como pos/pos-backups/<fecha>.tar.enc, privada. Borra de
#    Spaces lo de más de 30 días (la llave está limitada al bucket y no puede
#    poner una regla de ciclo de vida). En el droplet se conservan 14 días.
# 4. Avisa a Sentry Crons (monitor respaldo-diario-droplet-pos): in_progress al
#    empezar, ok al terminar, error si algo falla. Si a las 03:30 no llegó "ok",
#    Sentry abre un issue.
set -Eeuo pipefail

DEST=/opt/respaldos/db
DIA=$(date +%F)
RETENER_DIAS=${RETENER_DIAS:-14}
REMOTE_KEEP_DAYS=30
REMOTE_PREFIX=pos/pos-backups
KEY_FILE=${RESPALDO_KEY_FILE:-/root/.respaldo-clave}
# SENTRY_CHECKIN_URL (no es secreto, pero no tiene por qué estar en git).
CONFIG_FILE=${RESPALDO_CONFIG:-/root/.respaldo.env}
# Mismo bucket y misma llave que la API (un solo Space para todo).
SPACES_ENV=/opt/nexolu/nexolu-pos-api/.env
LOG=/var/log/respaldo-bases.log

SENTRY_CHECKIN_URL=""
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

log() { echo "$(date -Is) $*" >> "$LOG"; }
checkin() {
    [ -n "$SENTRY_CHECKIN_URL" ] || return 0
    curl -fsS --max-time 10 -o /dev/null "${SENTRY_CHECKIN_URL}?status=$1" || true
}
on_error() {
    log "ERROR en la linea $1: el respaldo no termino"
    checkin error
}
trap 'on_error $LINENO' ERR

checkin in_progress
mkdir -p "$DEST/$DIA"
chmod 700 /opt/respaldos
[ -s "$KEY_FILE" ] || { log "ERROR: falta la clave de cifrado $KEY_FILE"; checkin error; exit 1; }

# --- 1. Bases de datos -------------------------------------------------------
bases=$(docker exec nexolu-mysql-1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "show databases"' 2>/dev/null \
    | grep -v -E '^(mysql|sys|information_schema|performance_schema)$')
for db in $bases; do
    docker exec nexolu-mysql-1 sh -c "mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --routines --triggers --events --set-gtid-purged=OFF --no-tablespaces --databases $db" 2>/dev/null \
        | gzip -6 > "$DEST/$DIA/$db.sql.gz.tmp"
    mv "$DEST/$DIA/$db.sql.gz.tmp" "$DEST/$DIA/$db.sql.gz"
done

# --- 2. Sistema --------------------------------------------------------------
build_system_bundle() {
    local out="$1" meta list repo name
    meta=$(mktemp -d)
    list="$meta/rutas.txt"
    mkdir -p "$meta/meta"

    crontab -l > "$meta/meta/crontab-root.txt" 2>/dev/null || true
    docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}' > "$meta/meta/docker-ps.txt" 2>/dev/null || true

    # Repos con git: el código está en GitHub; aquí solo va en qué commit estaba
    # cada uno, sus cambios sin commit y sus archivos nuevos sin seguimiento.
    for repo in /opt/nexolu/*/ /var/www/*/; do
        [ -d "$repo.git" ] || continue
        name=$(basename "$repo")
        git -C "$repo" rev-parse HEAD > "$meta/meta/git-$name.head" 2>/dev/null || true
        git -C "$repo" diff HEAD > "$meta/meta/git-$name.patch" 2>/dev/null || true
        git -C "$repo" ls-files --others --exclude-standard 2>/dev/null \
            | sed "s|^|${repo#/}|" >> "$list" || true
    done

    # Lo que no está en git (rutas relativas a /; las que no existan se omiten).
    # Ojo con pipefail: un `ls` sin coincidencias o un `[ ] && echo` que da
    # falso en la última vuelta tumbarían el respaldo entero.
    {
        ls -d /opt/nexolu/*/.env /var/www/*/.env 2>/dev/null || true
        echo /etc/nginx
        echo /etc/letsencrypt
        echo /etc/cron.d
        echo /usr/local/bin
        echo /root/.ssh
        echo /opt/nexolu/nexolu-spa-api/storage/app
        ls -d /var/www/*/storage/app/public 2>/dev/null || true
        for repo in /var/www/*/; do
            if [ ! -d "$repo.git" ]; then echo "${repo%/}"; fi
        done
    } | while read -r path; do
        if [ -e "$path" ]; then echo "${path#/}"; fi
    done >> "$list"

    # tar sale con 1 si un archivo cambió mientras se leía: no es un fallo.
    # releases/ de los fronts son builds: se regeneran con un deploy.
    tar -C / --ignore-failed-read --exclude=node_modules --exclude=vendor \
        --exclude='opt/nexolu/*/releases' --exclude='opt/nexolu/*/dist' \
        -czf "$out.tmp" -T "$list" -C "$meta" meta 2>/dev/null || [ $? -eq 1 ]
    mv "$out.tmp" "$out"
    rm -rf "$meta"
}
build_system_bundle "$DEST/$DIA/sistema.tar.gz"

(cd "$DEST/$DIA" && sha256sum ./*.gz > SHA256SUMS)

# --- 3. Copia cifrada en Spaces ----------------------------------------------
spaces_var() { grep -m1 "^$1=" "$SPACES_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//'; }
SPACES_ID=$(spaces_var AWS_ACCESS_KEY_ID)
SPACES_SECRET=$(spaces_var AWS_SECRET_ACCESS_KEY)
SPACES_REGION=$(spaces_var AWS_DEFAULT_REGION)
SPACES_BUCKET=$(spaces_var AWS_BUCKET)
SPACES_BASE="https://$SPACES_BUCKET.$SPACES_REGION.digitaloceanspaces.com"

# La llave viaja por stdin (-K -): no aparece en `ps`.
s3() {
    printf 'user = "%s:%s"\n' "$SPACES_ID" "$SPACES_SECRET" \
        | curl -sS --max-time 900 -K - --aws-sigv4 "aws:amz:$SPACES_REGION:s3" \
            -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$@"
}

archive="/opt/respaldos/offsite-$DIA.tar.enc"
tar -C "$DEST" -cf - "$DIA" \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$KEY_FILE" > "$archive"
local_size=$(stat -c %s "$archive")
remote_key="$REMOTE_PREFIX/$DIA.tar.enc"

code=$(s3 -o /dev/null -w '%{http_code}' -T "$archive" -H 'x-amz-acl: private' "$SPACES_BASE/$remote_key")
[ "$code" = "200" ] || { log "ERROR: Spaces respondio $code al subir $remote_key"; rm -f "$archive"; false; }
remote_size=$(s3 -I "$SPACES_BASE/$remote_key" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')
rm -f "$archive"
[ "$remote_size" = "$local_size" ] || { log "ERROR: en Spaces quedo $remote_size bytes y eran $local_size"; false; }

# Los nombres son fechas: se borran las de 31 a 45 días atrás (si no existen,
# Spaces responde 204 igual). Así no hace falta listar el bucket.
for days_ago in $(seq $((REMOTE_KEEP_DAYS + 1)) $((REMOTE_KEEP_DAYS + 15))); do
    s3 -o /dev/null -X DELETE "$SPACES_BASE/$REMOTE_PREFIX/$(date -d "-$days_ago day" +%F).tar.enc" || true
done

# --- Limpieza local y aviso ---------------------------------------------------
find "$DEST" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENER_DIAS" -exec rm -rf {} +
log "ok local=$(du -sh "$DEST/$DIA" | cut -f1) spaces=$remote_key ($((local_size / 1048576)) MB cifrado) bases=$(echo $bases | tr ' ' ',')"
checkin ok
