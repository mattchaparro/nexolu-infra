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

deploy_pos_api() {
    local image="$API_IMAGE:$version"

    log "==> descargando $image"
    docker pull -q "$image" >/dev/null || fallar "no se pudo descargar $image (¿existe el tag? ¿el paquete es publico?)"
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

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://pos-backend.nexolu.co/up || echo 000)"
    log "curl https://pos-backend.nexolu.co/up -> $code"
    [ "$code" = "200" ] || fallar "la API no respondio 200. Volver atras: desplegar la version anterior."
}

case "$target" in
    pos-api)     deploy_pos_api ;;
    pos-front)   "$NEXOLU_DIR/nexolu-pos-front/deploy.sh" artifact "$version" ;;
    store-front) "$NEXOLU_DIR/nexolu-store-front/deploy.sh" artifact "$version" ;;
    *) fallar "destino no valido: '$target'" ;;
esac

log "==> listo: $target $version"
