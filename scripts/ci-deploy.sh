#!/bin/bash
# Puerta de entrada de los despliegues desde GitHub Actions.
#
# La llave SSH de GitHub está en /root/.ssh/authorized_keys con
#   command="/opt/nexolu/nexolu-infra/scripts/ci-deploy.sh",restrict
# así que esa llave NO abre una terminal: lo único que puede hacer es correr
# este script, y lo que pidió llega en SSH_ORIGINAL_COMMAND. Si alguien se
# roba la llave, lo peor que puede hacer es desplegar una versión que ya
# existe en GitHub. Ver docs/CI_DEPLOY.md.
#
# Comandos aceptados (cualquier otra cosa se rechaza):
#   pos-api     <version>   descarga la imagen ya construida y reinicia
#   pos-front   <version>   publica el build que llega por stdin (tar.gz)
#   store-front <version>   igual que pos-front
#
# <version> es un tag (v1.4.0) o un commit (sha-1a2b3c4).
#
# Por qué existe: compilar en el droplet de 2 GB (docker build de la API,
# vite build de los fronts) lo mandaba al swap en cada deploy y dejaba a
# dockerd con cientos de MB. Ahora se compila en GitHub y aquí solo se
# descarga y se arranca.
set -euo pipefail

NEXOLU_DIR="/opt/nexolu"
API_IMAGE="ghcr.io/mattchaparro/nexolu-pos-api"
# Nombre con el que docker-compose.yml conoce la imagen de pos-web,
# pos-queue y pos-scheduler. Se re-etiqueta la descargada con este nombre
# para no tener que cambiar el compose.
API_LOCAL_IMAGE="nexolu-pos-api:latest"
# Versiones de la API que se guardan para volver atrás sin descargar.
API_KEEP=3
# Volcados previos a cada deploy de la API (ver backup_before_deploy).
PREDEPLOY_BACKUP_DIR="${CI_DEPLOY_BACKUP_DIR:-/opt/respaldos/pre-deploy}"
PREDEPLOY_KEEP=7
LOG_FILE="${CI_DEPLOY_LOG:-/var/log/nexolu-ci-deploy.log}"

log() { echo "[ci-deploy] $*" | tee -a "$LOG_FILE" >&2; }
fallar() { log "ERROR: $*"; exit 1; }

# read -a y no args=($VAR): así un "*" no se expande a nombres de archivo.
read -r -a args <<< "${SSH_ORIGINAL_COMMAND:-}"
[ "${#args[@]}" -eq 2 ] || fallar "comando no valido: '${SSH_ORIGINAL_COMMAND:-}'"
target="${args[0]}"
version="${args[1]}"

[[ "$version" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?|sha-[0-9a-f]{7,40})$ ]] \
    || fallar "version no valida: '$version'"

# Un deploy a la vez: dos releases seguidos no se pisan los symlinks ni el
# docker compose.
exec 9>"${CI_DEPLOY_LOCK:-/var/lock/nexolu-ci-deploy.lock}"
flock -w 600 9 || fallar "hay otro deploy en curso desde hace 10 minutos"

log "==> $(date '+%F %T') $target $version"

# Volcado de pos_saas justo antes de tocar nada. El respaldo de las 03:00
# (respaldo-bases.sh) puede tener hasta 24 h de antigüedad; este es el punto
# de retorno de ESTE deploy, que puede traer migraciones. Si el volcado falla
# el deploy se aborta ANTES de reiniciar, así producción queda como estaba.
# Se guardan los últimos $PREDEPLOY_KEEP en $PREDEPLOY_BACKUP_DIR (mismo
# disco: la copia fuera del droplet es el respaldo nocturno a Spaces).
backup_before_deploy() {
    local dir="$PREDEPLOY_BACKUP_DIR/$(date +%F_%H%M%S)_$version"
    local file="$dir/pos_saas.sql.gz"
    local free_mb

    free_mb="$(df -Pm "$(dirname "$PREDEPLOY_BACKUP_DIR")" | awk 'NR==2 {print $4}')"
    [ "${free_mb:-0}" -ge 2048 ] || fallar "menos de 2 GB libres (${free_mb:-?} MB): no se arriesga a volcar y desplegar"

    log "==> respaldo previo de pos_saas"
    mkdir -p "$dir" && chmod 700 "$PREDEPLOY_BACKUP_DIR" "$dir"
    # mismas opciones que respaldo-bases.sh; pipefail hace fallar el pipe si
    # mysqldump falla aunque gzip termine bien.
    if ! ionice -c3 nice -n 19 docker exec nexolu-mysql-1 sh -c \
        'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --events --set-gtid-purged=OFF --no-tablespaces --databases pos_saas' 2>/dev/null \
        | gzip -6 > "$file.tmp"; then
        rm -rf -- "$dir"
        fallar "el respaldo previo de pos_saas fallo; no se despliega nada"
    fi
    # Un dump vacío o truncado también es un fallo.
    if ! gzip -t "$file.tmp" 2>/dev/null || [ "$(stat -c %s "$file.tmp")" -lt 10240 ]; then
        rm -rf -- "$dir"
        fallar "el respaldo previo de pos_saas salio vacio o corrupto; no se despliega nada"
    fi
    mv "$file.tmp" "$file"
    log "==> respaldo previo listo: $file ($(du -h "$file" | cut -f1))"

    { ls -1dt "$PREDEPLOY_BACKUP_DIR"/*/ 2>/dev/null || true; } \
        | tail -n +"$((PREDEPLOY_KEEP + 1))" \
        | while read -r old; do rm -rf -- "$old"; done
}

deploy_pos_api() {
    local image="$API_IMAGE:$version"

    log "==> descargando $image"
    docker pull -q "$image" >/dev/null || fallar "no se pudo descargar $image (¿existe el tag? ¿el paquete es publico?)"

    backup_before_deploy

    docker tag "$image" "$API_LOCAL_IMAGE"

    cd "$NEXOLU_DIR/nexolu-infra"
    log "==> reiniciando pos-web, pos-queue y pos-scheduler"
    docker compose up -d --no-build pos-web pos-queue pos-scheduler

    # Lo mismo que hace nexolu-pos-api/deploy.sh después del build.
    log "==> migraciones"
    docker compose exec -T pos-web php artisan migrate:baseline
    docker compose exec -T pos-web php artisan migrate --force
    docker compose exec -T pos-web php artisan permissions:sync

    log "==> borrando versiones viejas de la imagen (se guardan $API_KEEP)"
    docker images "$API_IMAGE" --format '{{.Tag}}' \
        | { grep -vx "$version" || true; } \
        | tail -n +"$API_KEEP" \
        | while read -r old; do docker rmi "$API_IMAGE:$old" >/dev/null 2>&1 || true; done
    docker image prune -f >/dev/null || true

    # pos-web acaba de recrearse: el primer /up puede dar 502 mientras arranca
    # php-fpm. Se reintenta hasta 60 s antes de dar el deploy por fallido.
    local code="000" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://pos-backend.nexolu.co/up || echo 000)"
        log "curl https://pos-backend.nexolu.co/up -> $code (intento $attempt/12)"
        [ "$code" = "200" ] && break
        sleep 5
    done
    [ "$code" = "200" ] || fallar "la API no respondio 200. Volver atras: desplegar la version anterior."
}

case "$target" in
    pos-api)     deploy_pos_api ;;
    pos-front)   "$NEXOLU_DIR/nexolu-pos-front/deploy.sh" artifact "$version" ;;
    store-front) "$NEXOLU_DIR/nexolu-store-front/deploy.sh" artifact "$version" ;;
    *) fallar "destino no valido: '$target'" ;;
esac

log "==> listo: $target $version"
