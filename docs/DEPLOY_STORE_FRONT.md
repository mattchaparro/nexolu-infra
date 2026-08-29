# Deploy de la tienda online (tienda.nexolu.co)

`nexolu-store-front` es la tienda publica: la ve un comprador anonimo que
llega de Google o de un link de WhatsApp. Se sirve igual que `pos-front`
(build estatico, release atomica, nginx del host), pero el visitante es
distinto y eso cambia las prioridades: no tiene sesion, no sabe que es una
SPA y no va a recargar si algo falla.

Un dominio para todas las tiendas, cada comercio en su path:
`tienda.nexolu.co/{slug}`. Un solo certificado, un solo vhost.

## Alta en un droplet nuevo (una sola vez)

Todo esto es manual y **todavia no se hizo en produccion**.

1. **DNS**: registro `A` de `tienda.nexolu.co` al droplet de produccion.

2. **Repo y llave de despliegue.** Cada repo del droplet clona con su
   propia deploy key y su alias de SSH (ver `~/.ssh/config` del droplet:
   `github.com-nexolu-pos-front`, etc.). Para la tienda hace falta lo mismo:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/deploy_nexolu-store-front -N '' -C 'deploy store-front'
   cat >> ~/.ssh/config <<'EOF'

   Host github.com-nexolu-store-front
     HostName github.com
     User git
     IdentityFile ~/.ssh/deploy_nexolu-store-front
     IdentitiesOnly yes
   EOF
   cat ~/.ssh/deploy_nexolu-store-front.pub   # → agregar como deploy key en GitHub
   ```

   Las deploy keys son de **solo lectura** a propósito: desde el droplet no
   se puede pushear (ver la memoria de gotchas de git en droplets).

   ```bash
   cd /opt/nexolu
   git clone git@github.com-nexolu-store-front:mattchaparro/nexolu-store-front.git
   ```

3. **Variables**: `cp .env.example .env` y apuntar `VITE_API_BASE_URL` a
   `https://pos-backend.nexolu.co/api/v1`. Se hornea en el build, asi que
   cambiarla despues exige rebuild.

4. **Primer build**, que ademas crea `current` y `previous`:
   ```bash
   ./deploy.sh
   ```
   La primera corrida avisa que no hay release anterior; es esperable.

5. **nginx**: copiar `nginx/tienda.nexolu.co.conf` a
   `/etc/nginx/sites-available/`, enlazarlo en `sites-enabled/`, y **antes
   de recargar** pedir el certificado:
   ```bash
   certbot --nginx -d tienda.nexolu.co
   nginx -t && systemctl reload nginx
   ```
   El `.conf` del repo ya trae las lineas de SSL con las rutas que certbot
   deja; si se corre certbot primero sobre un vhost sin ellas, las escribe
   igual y queda equivalente.

6. **Verificar**: `curl -I https://tienda.nexolu.co/` debe dar 200 (es la
   landing del repo, no una tienda). Para probar un comercio real hace falta
   un negocio con las **tres** cosas encendidas: el flag `online_store`
   (SuperAdmin), la tienda publicada (`business_store_settings.is_active`) y
   productos con `is_published`.

## Deploys siguientes

Desde el panel (`admin.nexolu.co` → Infra → prod → store-front), o en el
droplet:

```bash
./deploy-menu.sh store-front
```

o directamente `nexolu-store-front/deploy.sh`.

`store-front` está registrado en `nexolu-admin` igual que los demás
servicios (`SERVICE_REPOS`, `SERVICE_DROPLET_ROLE = "pos"`,
`_DEPLOY_SERVICES`), con una diferencia: **no tiene servicio de compose en
ningún ambiente**. Es un build estático servido por el nginx del host, así
que su `.env` solo se lee en tiempo de build — editarlo desde el panel
exige volver a desplegar para que tenga efecto, a diferencia del resto,
donde basta recrear el contenedor. Si el build falla, sale != 0
**sin tocar `current`**: la tienda sigue sirviendo la version anterior.
`./deploy.sh rollback` vuelve a la release previa sin reconstruir.

## Lo que este montaje NO resuelve todavia

- **SEO**: es una SPA sin prerender, asi que Google indexa poco. Aceptado
  para el arranque (el ruteo por path ya lo limita igual); SSR o prerender
  quedan para despues.
- **Imagenes**: se sirven desde el disco `public` de `pos-api`, no desde un
  bucket con CDN. `PRODUCT_IMAGES_DISK` es el unico interruptor para
  moverlas a DO Spaces cuando el bucket exista.
- **Staging**: no hay montaje de la tienda en SG. `deploy-menu.sh` lo omite
  sin fallar si el repo no esta clonado.
