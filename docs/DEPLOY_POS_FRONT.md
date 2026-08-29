# Deploy de `nexolu-pos-front` en producción

Cómo se despliega el SPA de Vue en `nexolu-pos-prod` (`new-pos.nexolu.co`),
por qué está armado así, y qué hacer cuando algo sale mal.

Para el patrón de **staging (SG)**, que es completamente distinto (dev server
de Vite en contenedor), ver [`STAGING_SG.md`](STAGING_SG.md). `deploy-menu.sh`
detecta solo cuál de los dos aplica según el droplet — no hace falta saberlo
al invocarlo.

## 1. El incidente que originó este diseño (2026-08-28)

La versión anterior de `nexolu-pos-front/deploy.sh` hacía, sobre el host:

```bash
git pull origin main
npm install
npm run build       # vue-tsc -b && vite build
```

A las 19:16 se hizo `git pull` de `0fa1af0` ("productos con variaciones").
`npm install` terminó 19:21:52. El build arrancó y a las **19:23:21**
empezó `Under memory pressure, flushing caches` en el journal. A las
**19:30:12** el kernel dejó de loguear: el droplet quedó colgado.

`nexolu-pos-prod` tiene **2 GB de RAM**, tenía **swap 0**, y ningún
contenedor tenía límite de memoria. Sin swap el kernel no alcanzó a matar a
`node` de forma ordenada: entró en thrashing y se colgó la máquina entera —
sin SSH, sin HTTP, sin MySQL. Respondía al ping (eso lo maneja el
hipervisor) y aceptaba el SYN de TCP, pero **ningún servicio contestaba**,
lo que hace el diagnóstico confuso: parece un problema de red, es memoria.

Impacto real: los negocios ya migrados (`business_migrations.status =
completed`) están **bloqueados en legacy y redirigidos por middleware** a
`new-pos.nexolu.co`. Con el droplet caído no tienen a dónde ir — no pueden
facturar. Estuvieron ~9 minutos afuera, hasta un power-cycle desde la API de
DigitalOcean (única vía: no había SSH).

Segundo problema, independiente del cuelgue: el build escribía **dentro de
`dist/`**, que es exactamente el directorio que nginx servía. Durante el
minuto y medio de build, cualquiera que entrara recibía una app rota. Y como
el build nunca terminó, `dist/` quedó con el contenido de las 13:51 mientras
`nexolu-pos-api` ya estaba en el commit nuevo: **front y back
desincronizados** sin que nada lo avisara.

## 2. Cómo funciona ahora

```
/opt/nexolu/nexolu-pos-front/
├── releases/
│   ├── 20260828-201530/     <- builds completos, inmutables
│   ├── 20260828-194412/
│   └── 20260827-101233/
├── current   -> releases/20260828-201530     (symlink; nginx sirve esto)
└── previous  -> releases/20260828-194412     (symlink; fallback de assets)
```

`deploy.sh` hace:

1. `git pull origin main`.
2. **Build dentro de un contenedor efímero** (`node:22-alpine`) con tope de
   memoria duro. El host ya no necesita `node` ni `npm`.
3. Mueve `dist/` a `releases/<timestamp>/`.
4. Cambia el symlink `current` de golpe (`mv -T`, que es un `rename(2)`
   atómico — no `ln -sfn`, que borra y recrea dejando una ventana sin
   destino).
5. Deja `previous` apuntando a la release que estaba sirviéndose.
6. Borra releases viejas, conservando las últimas 3 (`RETENER`).

### Por qué el build va en contenedor y no en el host

El punto **no** es empaquetar la app — lo que se sirve siguen siendo
archivos estáticos del host, servidos por el nginx que ya termina TLS para
todos los vhosts. El punto es el **cgroup**: con `--memory` el kernel mata
solo al proceso de build si se pasa, y el resto del droplet (MySQL, pos-api,
redis, nginx) ni se entera. Un build que se desmadra pasa de "se cae
producción" a "el deploy falla y hay que revisarlo".

Se descartó meter el front en un contenedor con su propio nginx: obligaría a
proxy-pasar archivos estáticos o a mover la terminación TLS, más piezas
móviles sin resolver ninguno de los dos problemas reales.

Variables de entorno para ajustar el build (todas con default en el script):

| Variable | Default | Qué es |
|---|---|---|
| `MEM_LIMIT` | `1200m` | RAM real del contenedor de build |
| `MEM_SWAP_LIMIT` | `2400m` | RAM + swap (Docker lo define así; **no** es swap adicional) |
| `NODE_HEAP_MB` | `1024` | `--max-old-space-size` de V8, por debajo de `MEM_LIMIT` |
| `NODE_IMAGE` | `node:22-alpine` | Imagen de build |
| `RETENER` | `3` | Releases a conservar |

`MEM_SWAP_LIMIT > MEM_LIMIT` es deliberado: un build pesado desborda a swap
(lento, pero termina) en vez de morir. `vue-tsc -b` es la parte cara del
`npm run build`, bastante más que Vite.

### Por qué el cliente ya no se ve afectado

Dos mecanismos, ambos en [`nginx/new-pos.nexolu.co.conf`](../nginx/new-pos.nexolu.co.conf):

- **Cambio atómico**: nginx resuelve `root` en cada request. El cliente ve
  la versión vieja o la nueva, nunca un directorio a medio escribir. No hace
  falta `nginx -s reload`.
- **Fallback de assets a `previous`**: un cliente con la pestaña ya abierta
  tiene el `index.html` viejo en memoria y va a pedir chunks con hashes que
  en `current` ya no existen. Sin fallback esa pestaña se rompe hasta
  recargar. Con `try_files $uri @release_anterior`, sigue funcionando.
- `index.html` se sirve con `no-store`; los assets (hasheados, inmutables)
  con `max-age=31536000, immutable`.

**Por eso no hace falta ni ventana nocturna ni banner de mantenimiento.** Un
deploy es invisible para quien está usando la app.

## 3. Uso

```bash
cd /opt/nexolu/nexolu-infra && ./deploy-menu.sh pos-front
```

o directo:

```bash
/opt/nexolu/nexolu-pos-front/deploy.sh
```

Otros comandos:

```bash
/opt/nexolu/nexolu-pos-front/deploy.sh status     # qué release está activa
/opt/nexolu/nexolu-pos-front/deploy.sh rollback   # volver a la anterior, sin rebuild
```

`rollback` es instantáneo: solo mueve symlinks, no reconstruye nada.

## 4. Swap: obligatorio en todos los droplets

`bootstrap.sh` ahora crea un swapfile de 2 GB con `vm.swappiness=10`. En un
droplet que ya existe:

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' >> /etc/sysctl.conf
```

El swap no está para "tener más RAM" — está para que un pico se convierta en
lentitud o en un proceso muerto, en vez de en un cuelgue duro sin SSH.

## 5. Si algo falla

| Síntoma | Qué pasó | Qué hacer |
|---|---|---|
| `deploy.sh` corta en el build | El contenedor se pasó de `MEM_LIMIT` (exit 137 = OOM) | `current` **no se tocó**, el sitio sigue arriba. Subir `MEM_LIMIT`/`NODE_HEAP_MB` o revisar qué creció en el bundle |
| La app nueva anda mal | Bug del release | `./deploy.sh rollback` |
| El droplet no responde a nada pero pinguea | Memoria agotada, sin SSH | Power-cycle desde la API/panel de DigitalOcean; después revisar `journalctl -k -b -1` |
| Front y API desincronizados | Un deploy quedó a medias | `deploy.sh status` para ver la release activa; comparar con el `git log -1` de `nexolu-pos-api` |

Un `deploy.sh` que falla **nunca** deja el sitio caído: `current` solo se
mueve cuando ya existe una release completa y verificada.
