# Respaldos del droplet del POS

`scripts/respaldo-bases.sh`, instalado como `/usr/local/bin/respaldo-bases.sh`,
corre todos los días a las 03:00 (cron de root, hora de Bogotá).

| Qué | Dónde | Cuánto tiempo |
|---|---|---|
| Volcado de cada base (`<base>.sql.gz`) + `sistema.tar.gz` + `SHA256SUMS` | `/opt/respaldos/db/<fecha>/` en el droplet | 14 días |
| La misma carpeta, cifrada | Spaces `nexolu-storage`, `pos/pos-backups/<fecha>.tar.enc` (privado) | 30 días |
| Volcado de `pos_saas` antes de cada deploy de la API | `/opt/respaldos/pre-deploy/` | últimos 7 |

`sistema.tar.gz` lleva lo que no está en git: los `.env` de `/opt/nexolu` y
`/var/www`, `/etc/nginx`, `/etc/letsencrypt`, `/etc/cron.d`, `/usr/local/bin`,
`/root/.ssh`, el storage del Spa, los sitios de `/var/www` sin git y, de los
repos con git, el commit en que estaba cada uno (`meta/git-*.head`), sus
cambios sin commit (`meta/git-*.patch`) y sus archivos nuevos. También el
crontab de root y la lista de contenedores.

**Aviso:** el monitor de Sentry Crons `respaldo-diario-droplet-pos` (proyecto
nexolu-pos-api) espera un "ok" cada día a las 03:00 con 30 minutos de margen.
Si el script falla o no corre, Sentry abre un issue. Log en
`/var/log/respaldo-bases.log`.

## La clave de cifrado

Vive en `/root/.respaldo-clave` (solo root) y **una copia en el gestor de
contraseñas de Alejandro**. Sin esa clave la copia de Spaces no sirve: si se
pierde el droplet, es lo único que permite abrirla. No va en git ni en chats.

## Restaurar

Siempre sobre una base o carpeta **temporal**, nunca encima de producción.

1. Descargar `pos/pos-backups/<fecha>.tar.enc` desde el panel de Spaces (o
   tomar `/opt/respaldos/db/<fecha>/` si el droplet sigue vivo).
2. Descifrar y abrir (pide la clave; con `-pass file:` si se tiene en archivo):

   ```bash
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in <fecha>.tar.enc | tar -xf -
   cd <fecha> && sha256sum -c SHA256SUMS
   ```

3. Una base, en una base temporal (el dump trae `CREATE DATABASE`/`USE`, así
   que se cambia el nombre al vuelo):

   ```bash
   gunzip -c pos_saas.sql.gz \
     | sed -e 's/^CREATE DATABASE .*`pos_saas`/CREATE DATABASE `pos_saas_restaurada`/' \
           -e 's/^USE `pos_saas`/USE `pos_saas_restaurada`/' \
     | mysql -uroot -p
   ```

4. Archivos del sistema: `tar -xzf sistema.tar.gz -C /tmp/sistema` y copiar a
   mano lo que haga falta.
