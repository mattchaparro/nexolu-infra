#!/bin/bash
# Menu interactivo para desplegar los servicios de Nexolu en ESTE droplet.
# No reemplaza los `deploy.sh` de cada repo (nexolu-pos-api/deploy.sh, etc.)
# - los llama. Ver README.md para el detalle de que hace cada uno.
#
# Uso:
#   ./deploy-menu.sh              Menu interactivo.
#   ./deploy-menu.sh pos-api      Despliega directo un servicio, sin menu
#                                 (valores: pos-api, ia-core, comms-api,
#                                 payments-core, pos-front, all, infra).
set -u
cd "$(dirname "$0")"

SERVICIOS_PY=(ia-core:nexolu-ia-core:8000 comms-api:nexolu-comms-api:8010 payments-core:nexolu-payments-core:8020)

log() { echo "[deploy] $*"; }

# ---------------------------------------------------------------------------
# Infra base: mysql + redis, con espera a que mysql este healthy.
# ---------------------------------------------------------------------------
levantar_infra() {
    log "Levantando mysql + redis..."
    docker compose up -d mysql redis
    log "Esperando a que mysql este healthy..."
    for i in $(seq 1 30); do
        st="$(docker inspect -f '{{.State.Health.Status}}' nexolu-mysql-1 2>/dev/null)"
        [ "$st" = "healthy" ] && break
        sleep 2
    done
    if [ "$st" != "healthy" ]; then
        log "ERROR: mysql no quedo healthy a tiempo. Revisar: docker compose logs mysql"
        return 1
    fi
    log "mysql + redis OK."

    # Primera vez: pos_saas sin tablas -> ofrecer cargar schema.sql (nunca se
    # corre migrate, ver nexolu-pos-api/CLAUDE.md y nexolu-infra/README.md).
    TABLAS="$(docker compose exec -T mysql mysql -unexolu -p"$(grep -E '^MYSQL_APP_PASSWORD=' .env | cut -d= -f2-)" -N -e 'SHOW TABLES;' pos_saas 2>/dev/null | wc -l)"
    if [ "$TABLAS" -eq 0 ]; then
        log "AVISO: pos_saas no tiene tablas todavia."
        read -r -p "    Cargar database/legacy-schema/schema.sql de nexolu-pos-api ahora? [s/N] " resp
        if [[ "$resp" =~ ^[sS]$ ]]; then
            docker compose exec -T mysql mysql -unexolu -p"$(grep -E '^MYSQL_APP_PASSWORD=' .env | cut -d= -f2-)" pos_saas \
                < ../nexolu-pos-api/database/legacy-schema/schema.sql \
                && log "    schema.sql cargado (85 tablas)." \
                || log "    ERROR cargando schema.sql - revisar a mano."
        else
            log "    Salteado. pos-api no va a funcionar hasta cargar el schema."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Chequeo liviano de .env: avisa (no bloquea) que credenciales externas
# siguen vacias, para no hacerte perder tiempo con un deploy que va a andar
# a medias sin avisar por que.
# ---------------------------------------------------------------------------
avisar_env_faltante() {
    local servicio="$1" archivo="$2"
    shift 2
    for var in "$@"; do
        val="$(grep -E "^${var}=" "$archivo" 2>/dev/null | cut -d= -f2-)"
        if [ -z "$val" ]; then
            log "    AVISO ($servicio): $var vacio en $archivo - esa funcionalidad va a fallar hasta completarlo."
        fi
    done
}

# ---------------------------------------------------------------------------
# Health check con reintentos - el contenedor recien reiniciado necesita un
# instante para que el proceso adentro empiece a aceptar conexiones. Un solo
# curl inmediato despues del `up -d`/`deploy.sh` es una carrera perdida (bug
# real visto en vivo el 2026-08-20: el deploy funcionaba de punta a punta
# pero el script terminaba "con error" porque el ultimo comando de la
# funcion era ese curl fallido, y su exit code se colaba como el de todo el
# script). Nunca hace que el deploy en si "falle" - solo informa.
# ---------------------------------------------------------------------------
verificar_salud() {
    local url="$1" intentos=10 codigo="000"
    for i in $(seq 1 "$intentos"); do
        codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
        case "$codigo" in
            000|5*) sleep 2 ;;
            *) break ;;
        esac
    done
    log "    curl $url -> $codigo"
}

# ---------------------------------------------------------------------------
# Despliegue de cada servicio: delega en su propio deploy.sh.
# ---------------------------------------------------------------------------
deploy_pos_api() {
    log "=== pos-api ==="
    avisar_env_faltante "pos-api" "../nexolu-pos-api/.env" PAYMENTS_CORE_API_KEY WHATSAPP_ACCESS_TOKEN
    ../nexolu-pos-api/deploy.sh || return 1
    verificar_salud http://127.0.0.1:8001/up
    return 0
}

deploy_python() {
    local nombre="$1" repo="$2" puerto="$3"
    log "=== $nombre ==="
    case "$nombre" in
        ia-core) avisar_env_faltante "$nombre" "../$repo/.env" OPENROUTER_API_KEY ;;
        comms-api) avisar_env_faltante "$nombre" "../$repo/.env" BREVO_API_KEY ;;
        payments-core) log "    (Wompi sandbox: se completa aparte, ver README de nexolu-payments-core)" ;;
    esac
    ( cd "../$repo" && ./deploy.sh ) || return 1
    verificar_salud "http://127.0.0.1:${puerto}/health"
    return 0
}

# pos-front tiene DOS patrones de deploy segun el droplet - cual aplica no
# se puede saber por el repo (nexolu-pos-front es el mismo checkout en
# ambos lados), solo mirando que existe en ESTE droplet:
#   - SG (staging): sin Dockerfile todavia, corre como dev server de Vite
#     directo sobre el codigo fuente (bind mount, ver
#     docker-compose.override.yml - NO commiteado, local a ese droplet -
#     servicio "frontend"/contenedor nexolu-pos-front). Desplegar es
#     git pull + recrear el contenedor (su `npm install && npm run dev`
#     de `command:` corre de nuevo solo con eso).
#   - Produccion: build estatico servido directo por nginx del host desde
#     dist/ (ver nginx/new-pos.nexolu.co.conf) - sin contenedor, delega en
#     nexolu-pos-front/deploy.sh (git pull + npm install + npm run build).
# Se distingue por si el compose YA MEZCLADO de este droplet define un
# servicio "frontend" (solo pasa si el override de SG esta presente) -
# mismo chequeo tanto en modo interactivo como en modo directo (`pos-front`
# como argumento), asi que el panel de SuperAdmin no necesita saber en
# cual de los dos esta el droplet al que le habla.
deploy_frontend() {
    log "=== pos-front ==="
    if docker compose config --services 2>/dev/null | grep -qx frontend; then
        log "    (patron SG: dev server de Vite en contenedor)"
        ( cd ../nexolu-pos-front && git pull ) || return 1
        docker compose up -d --force-recreate frontend
        verificar_salud http://127.0.0.1:5173/
    elif [ -x ../nexolu-pos-front/deploy.sh ]; then
        log "    (patron produccion: build estatico servido por nginx)"
        ../nexolu-pos-front/deploy.sh || return 1
        verificar_salud https://new-pos.nexolu.co/
    else
        log "    ERROR: ni el servicio 'frontend' de SG ni ../nexolu-pos-front/deploy.sh existen en este droplet - no se puede desplegar aca."
        return 1
    fi
    return 0
}

deploy_uno() {
    case "$1" in
        pos-api) deploy_pos_api ;;
        ia-core) deploy_python ia-core nexolu-ia-core 8000 ;;
        comms-api) deploy_python comms-api nexolu-comms-api 8010 ;;
        payments-core) deploy_python payments-core nexolu-payments-core 8020 ;;
        pos-front) deploy_frontend ;;
        *) log "Servicio desconocido: $1"; return 1 ;;
    esac
}

deploy_todos() {
    levantar_infra || return 1
    deploy_pos_api
    for entry in "${SERVICIOS_PY[@]}"; do
        IFS=: read -r nombre repo puerto <<< "$entry"
        deploy_python "$nombre" "$repo" "$puerto"
    done
    deploy_frontend
}

# ---------------------------------------------------------------------------
# Modo directo (arg) o menu interactivo.
# ---------------------------------------------------------------------------
if [ "${1:-}" != "" ]; then
    case "$1" in
        infra) levantar_infra ;;
        all) deploy_todos ;;
        pos-api|ia-core|comms-api|payments-core) levantar_infra && deploy_uno "$1" ;;
        pos-front) deploy_uno "$1" ;;
        *) echo "Uso: $0 [pos-api|ia-core|comms-api|payments-core|pos-front|all|infra]"; exit 1 ;;
    esac
    exit $?
fi

echo "Nexolu - Deploy interactivo"
echo
PS3=$'\n''Que queres desplegar? '
opciones=("Todos (infra + 5 servicios)" "Solo infra (mysql+redis)" "pos-api" "ia-core" "comms-api" "payments-core" "pos-front" "Salir")
select opt in "${opciones[@]}"; do
    case "$REPLY" in
        1) deploy_todos; break ;;
        2) levantar_infra; break ;;
        3) levantar_infra && deploy_uno pos-api; break ;;
        4) levantar_infra && deploy_uno ia-core; break ;;
        5) levantar_infra && deploy_uno comms-api; break ;;
        6) levantar_infra && deploy_uno payments-core; break ;;
        7) deploy_uno pos-front; break ;;
        8) exit 0 ;;
        *) echo "Opcion invalida." ;;
    esac
done
