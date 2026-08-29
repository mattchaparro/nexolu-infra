#!/bin/bash
# Primer arranque del droplet. Pensado para correr UNA vez, a mano, en un
# droplet nuevo de Ubuntu 24.04 - no es para CI ni para deploys posteriores
# (esos son los `deploy.sh` de cada repo de servicio, ver README.md).
#
# Precondiciones que este script NO resuelve por ti:
#   - Los 4 dominios (api/ia/comms/payments.nexolu.co) ya apuntando (registro
#     A) a la IP de este droplet - certbot falla si no resuelven todavia.
#   - Tu llave SSH ya autorizada contra los 4 repos de GitHub (clone por SSH,
#     no HTTPS - ver README.md).
set -e

# Los droplets de Nexolu son de 1-2 GB y DigitalOcean no provisiona swap por
# defecto. Sin swap, un pico de memoria no dispara el OOM killer de forma
# ordenada: la maquina entra en thrashing y se cuelga entera, sin SSH ni
# consola. Paso real el 2026-08-28 en nexolu-pos-prod (build de pos-front,
# ver docs/DEPLOY_POS_FRONT.md) - se llevo puestos MySQL, pos-api y nginx.
# El swap no es para "tener mas RAM": es la red de contencion que convierte
# un cuelgue duro en un proceso lento o un proceso muerto.
echo "==> Configurando swap (2 GB) si no existe"
if [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # swappiness bajo: usar swap como red de contencion ante picos, no como
    # memoria de uso corriente (degradaria MySQL).
    sysctl -w vm.swappiness=10
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo "    swap de 2 GB activo y persistente en /etc/fstab"
else
    echo "    ya hay swap configurado, se salta"
fi

echo "==> Instalando Docker Engine + Compose plugin"
curl -fsSL https://get.docker.com | sh

echo "==> Instalando nginx + certbot"
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx

echo "==> Clonando los 4 repos de servicio como hermanos de este directorio"
cd ..
for repo in nexolu-pos-api nexolu-ia-core nexolu-comms-api nexolu-payments-core; do
    if [ -d "$repo" ]; then
        echo "    $repo ya existe, se salta (usa su propio deploy.sh para actualizar)"
    else
        git clone "git@github.com:mattchaparro/${repo}.git"
    fi
done
cd nexolu-infra

echo "==> Copiando vhosts de nginx a sites-available"
cp nginx/*.conf /etc/nginx/sites-available/
for conf in nginx/*.conf; do
    name=$(basename "$conf")
    ln -sf "/etc/nginx/sites-available/$name" "/etc/nginx/sites-enabled/$name"
done
nginx -t && systemctl reload nginx

cat <<'EOF'

==> Pausa manual: antes de seguir, confirma que puedes completar esto:

1. deploy/.env de infraestructura (MySQL):
     cp .env.example .env   # y completar MYSQL_ROOT_PASSWORD / MYSQL_APP_PASSWORD

2. El .env real de CADA servicio (copiado de su propio .env.example):
     cd ../nexolu-pos-api        && cp .env.example .env   # completar
     cd ../nexolu-ia-core        && cp .env.example .env   # completar
     cd ../nexolu-comms-api      && cp .env.example .env   # completar
     cd ../nexolu-payments-core  && cp .env.example .env   # completar

   Los hosts internos son los nombres de servicio de docker-compose.yml
   (DB_HOST=mysql, REDIS_HOST=redis, IA_CORE_BASE_URL=http://ia-core:8000,
   etc.) - ver README.md seccion 3 para el detalle completo de cada uno.

3. Certificados TLS (solo si los 4 dominios YA resuelven a esta IP):
     certbot --nginx -d pos-backend.nexolu.co
     certbot --nginx -d ia.nexolu.co
     certbot --nginx -d comms.nexolu.co
     certbot --nginx -d payments.nexolu.co

   certbot instala su propio timer de renovacion automatica (systemctl
   status certbot.timer) - no hace falta cron aparte.

Cuando los .env esten listos, corre:
   docker compose up -d mysql redis
   docker compose exec -T mysql mysql -unexolu -p<MYSQL_APP_PASSWORD> pos_saas < ../nexolu-pos-api/database/legacy-schema/schema.sql
   ../nexolu-pos-api/deploy.sh
   ../nexolu-ia-core/deploy.sh
   ../nexolu-comms-api/deploy.sh
   ../nexolu-payments-core/deploy.sh

Ver README.md para el detalle de cada paso.
EOF
