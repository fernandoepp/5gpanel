# Panel 5G (core Open5GS + gNB ocudu)

Interfaz web (por defecto en PC1, core; puede ir en cualquiera de los dos PCs) para ver el estado de los dos despliegues, editar los `.env` con validación y aplicar los cambios recreando servicios. La interfaz y el código están en catalán, como `core5g.sh`.

## Arquitectura

```
Navegador ──HTTPS + login──► panel5g (Docker, PC1, solo IP LAN:8443)
                                 │  sin docker.sock, sin carpetas de los proyectos
                    mTLS ┌───────┴────────┐ mTLS
                         ▼                ▼
       agent5g PC1 (172.17.0.1:9443)      agent5g PC2 (IP_PC2:9443, ufw: solo PC1)
       .env de docker_open5gs             .env de ocudu/docker
```
Para moverlo a PC2, intercambia `listen` de los agentes y las URL de `panel.yaml`. Los certificados sirven para las dos ubicaciones.

- **Panel** (`panel/`): FastAPI. Login con contraseña scrypt, roles `admin` / `lector`, cookie `Secure`/`HttpOnly`/`SameSite=Strict`, token CSRF, límite de 5 intentos por IP cada 5 min, CSP estricta. El contenedor es de solo lectura, sin capacidades y corre como usuario sin privilegios.
- **Agente** (`agent/agent5g.py`): solo usa la biblioteca estándar de Python y corre como servicio systemd. Solo acepta clientes con certificado de la CA propia y CN `panel5g`. Lo único que sabe hacer está en lista blanca: leer logs de contenedores permitidos, leer el `.env` (oculta los secretos), editar claves permitidas (con regex), restaurar copias y hacer `docker compose up -d --no-deps <servicio permitido>`. Hace una copia antes de cada escritura (guarda las 50 últimas) y lleva auditoría en `/var/lib/agent5g/audit.log`.
- **Validación** (`panel/config/schema.yaml`): valores permitidos y reglas cruzadas. SRATE tiene que estar en la lista de la B210, ser ≥ 1.152 × ancho y como máximo 46.08 (23.04 y 20 MHz con 2x2). El ARFCN tiene que caer dentro de la banda y la frecuencia, dentro del rango de la B210. Además avisa si el PLMN del gNB no coincide con el MCC+MNC del core.
- **Mapa de reinicios** (`panel/config/restart_map.yaml`): indica qué servicios hay que recrear para cada clave. El del core está **vacío, pendiente de definir**. Mientras tanto, los servicios se eligen a mano en el panel.

## Instalación

1. **Certificados** (en cualquier PC; guarda `ca/ca.key` fuera de los PCs):
   `./scripts/gen_certs.sh <IP_PC1> <IP_PC2> ./certs-5g`
2. **Agente en PC2 (radio)**: `sudo bash scripts/install_agent.sh radio ./certs-5g/agent-radio <IP_PC1>`
   La primera vez copia `agent5g-radio.json` a `/etc/agent5g/agent5g.json`. Revisa `listen` (IP LAN de PC2) y `project_dir`, y vuelve a ejecutarlo. Con ufw activo, solo PC1 entra al 9443.
3. **Agente en PC1 (core)**: `sudo bash scripts/install_agent.sh core ./certs-5g/agent-core`
   Escucha en 172.17.0.1, así que no se ve desde la LAN. Revisa `project_dir` (`~/core5g/<versión>/docker_open5gs`), `compose_files` y los contenedores.
4. **Panel en PC1**:
   - Genera el hash de la contraseña con `sudo bash scripts/install_panel.sh ./certs-5g/panel <IP_PC1>` (te dice cómo) y pégalo en `panel/config/panel.yaml`.
   - Vuelve a ejecutar el script. El panel queda en `https://<IP_PC1>:8443`.
5. Importa `certs-5g/ca/ca.crt` como CA de confianza en los navegadores del laboratorio.

## Flujo de un cambio

1. En Paràmetres, pulsa **Validar** para ver los errores y avisos.
2. Pulsa **Desar al .env**: el agente hace una copia y escribe el fichero.
3. Los servicios quedan pendientes. Pulsa **Aplicar** para hacer `docker compose up -d --no-deps <servicios>`.

Importante: `docker restart` no relee el `.env`. Por eso el panel siempre **recrea** los servicios.

## Puntos abiertos

- Definir `restart_map.yaml` del core.
- Los patrones de `estat_logs` en `panel.yaml` son heurísticas y hay que contrastarlos con los logs reales.

## Métricas de radio por móvil (gNB ocudu)

La ficha de cada móvil (pestaña Dispositius) muestra, además de lo que dice el core, lo que mide la gNodeB: CQI (calidad del canal que informa el móvil, 0–15), RI (capas MIMO), MCS (modulación) de bajada y subida, velocidad de bajada y subida, bloques repetidos (HARQ/CRC KO), SNR y RSRP de subida, avance temporal (TA) y margen de potencia (PHR). Se refresca cada 3 s. Con el botón «Gràfics» se abre una ventana con gráficos de los últimos 5 minutos (una muestra por segundo) de velocidad, CQI, MCS, bloques repetidos, SNR, RI y RSRP; el historial se acumula por móvil aunque cambie el RNTI, y se pierde al recargar la página.

- **De dónde salen:** ocudu publica cada segundo las métricas del planificador por el control remoto WebSocket (`remote_control.enabled: true`, puerto 8001 por defecto) si `metrics.enable_json: true`. El agente de la radio se suscribe (`{"cmd":"metrics_subscribe"}`) solo mientras alguien mira el panel y las sirve en `GET /radio_ues`. Se puede cambiar la URL con `"gnb_metrics": {"ws": "ws://127.0.0.1:8001"}` en `agent5g.json` (`false` lo desactiva).
- **Qué móvil es cada RNTI:** el gNB solo conoce el RNTI (identificador de radio, cambia en cada conexión). El agente lo cruza con el log del gNB: las líneas `[RRC] ue=19 c-rnti=0x4848` y `[NGAP] ... ue=19 ran_ue=18 amf_ue=19` dan los identificadores NGAP, y el AMF dice qué IMSI tiene cada `amf_ue_ngap_id`. Hace falta `rrc_level` y `ngap_level` a `info` (o `debug`) en la sección `log:` del gNB; `install_radio.sh` ya lo pone. Sin esas líneas solo se asocia cuando hay un único móvil conectado al gNB, y se indica como «deducido».
- **Qué no hay:** RSRP/RSSI de bajada por móvil. El gNB no los mide; lo más parecido es el CQI. El RSRP de subida es relativo (escala digital de la USRP), no dBm.
- Las métricas se piden aparte, después de pintar las fichas: si la radio no responde, las fichas salen igual y la sección «Ràdio» dice por qué no hay datos.

## Estado en vivo del AMF y del SMF (core)

Desde Open5GS v2.7.7, el servidor de métricas del AMF y del SMF (puerto 9091 en docker_open5gs) sirve también `/gnb-info`, `/ue-info` (AMF) y `/pdu-info` (SMF) en JSON. El agente los lee en `GET /estat5g` y el panel los usa como **fuente principal** en las pestañas de UEs y gNodeB: qué gNB hay conectados, qué móviles están registrados o en reposo, en qué gNB y celda están, su IMEISV, el cifrado, y las sesiones PDU con IP, slice, estado (activa / en reposo) y UPF.

- Es el estado que el AMF y el SMF tienen en memoria: no depende de la captura NGAP ni de cuántas líneas de log quedan. Los logs siguen dando el historial (eventos, contadores, causas de rechazo) y la captura, lo que Open5GS no guarda (NG Setup rechazados, IMEISV de móviles rechazados).
- Por defecto usa `AMF_IP` y `SMF_IP` del `.env` y el puerto 9091. Se puede cambiar en `/etc/agent5g/agent5g.json`: `"open5gs_api": {"amf": "http://IP:9091", "smf": "http://IP:9091", "timeout": 3}`.
- Si Open5GS es anterior a v2.7.7 (responde 400/404), el panel lo indica en la línea «Fonts» y sigue con logs y captura. Comprobación rápida desde el core: `curl -s http://172.22.0.10:9091/ue-info`.

## Modelo del móvil por TAC

El modelo sale de los 8 primeros dígitos del IMEI (TAC). Primero se mira `config/tac.csv` (los móviles del laboratorio, manda siempre) y después la base de datos pública [MoazEb/tac-database](https://github.com/MoazEb/tac-database) (licencia MIT, ~276.000 TAC), que va en `panel/app/data/tac_full.csv.gz`. Al construir la imagen se convierte a SQLite (`python -m app.tacdb build`), así no ocupa memoria del contenedor (256 MB). Para actualizarla: descarga `tac_full.csv` del repositorio, comprímela con `gzip -9` en `panel/app/data/` y vuelve a ejecutar `scripts/actualitzar.sh`.

## Cambio de red

- Los agentes se identifican por el certificado (firmado por nuestra CA y con CN `agent-core` o `agent-radio*`), no por la IP: si la IP cambia no hace falta volver a emitir certificados.
- El agente de radio con `"listen": "auto"` escucha en la IP de la LAN que tenga en cada momento y se reinicia solo si el DHCP la cambia. Si la IP configurada ya no existe, usa la actual en lugar de reiniciarse en bucle.
- El panel busca radios también en la /24 de su propia IP (`PANEL_IP`).
- `scripts/canviar_xarxa.sh core <IP_radio>` (en el core) y `scripts/canviar_xarxa.sh radio <IP_core>` (en la radio) cambian las IPs viejas por las nuevas en `.env`, `sa-deploy.yaml`, `smf.yaml`, `panel.yaml`, `upf_remot/.env` y el `.env` de ocudu, con copia de cada fichero, y recrean el SMF, el panel, la UPF y la gNB. Con `-n` solo muestra lo que cambiaría.

## Modelo del móvil por el tráfico (opcional, core)

`agent/ua_capture.py` + `ua-capture.service` escuchan N3 (GTP-U, UDP 2152) con `tshark` y guardan **solo** IP del UE + `User-Agent` HTTP + hora en `/var/lib/agent5g/ua.json` (máx. 300 entradas; nada de URLs, hosts ni contenido, nada de pcap a disco). El panel cruza la IP con la que el SMF dio a cada IMSI en ese momento y pone en la ficha el modelo (p. ej. `SM-S911B`) y el sistema (`Android 14`).

- Solo funciona con HTTP sin TLS. Hoy casi todo va por HTTPS: si no sale, abre en el móvil una web `http://` (p. ej. `http://neverssl.com`).
- El model del TAC (`config/tac.csv`) tiene prioridad; el del tráfico se usa si el TAC no está.
- Un móvil 5G no tiene MAC hacia el core (la sesión PDU es IP pura): las MAC de las capturas son del gNB y del core.

Instalar/actualizar en el core: `sudo bash scripts/actualitzar.sh` (copias de seguridad en `/var/lib/agent5g/bak-*`).

## Frecuencia central → ARFCN, banda y SCS (radio)

En *Paràmetres > Ràdio* hay un campo «Freqüència central (MHz)» que no se guarda en el `.env`. El servidor (`app/radio.py`, TS 38.104) calcula `DL_ARFCN` con el raster global y lo ajusta al raster de canal de la banda. Propone `BAND` según la frecuencia y `SCS` según la banda, y sube `SRATE` si el ancho no cabe.

- Bandas solapadas (n78/n77/n48, n1/n65/n66, n7/n41): se propone la primera de `radio.prioritat` en `schema.yaml` (n78, n1, n7…). El desplegable solo deja elegir entre las que contienen la frecuencia.
- SCS por defecto: 15 kHz en FDD, 30 kHz en TDD. Es editable entre las que admite la banda. Al cambiar de banda vuelve a ser automática.
- Al validar y guardar se comprueba que el canal entero (frecuencia ± ancho/2) cabe en la banda, la SCS de la banda, el ancho mínimo (n77/n78 10 MHz, n79 40 MHz) y que 5 MHz solo vaya con 15 kHz. Si el ARFCN no cae en el raster de la banda, sale un aviso.

## Pestaña gNodeB

Una card por cada gNB que se conecta al AMF:
- **Estado en vivo del AMF (`/gnb-info`):** qué gNB están conectados ahora, con gNB-ID, nombre, PLMN, TAC y slices. Manda sobre el log y la captura.
- **Log del AMF:** conexiones y cortes SCTP (N2), y avisos de NG Setup como «Cannot find Served TAI».
- **Captura N2 (`GET /gnbs` del agente):** NG Setup Request/Response/Failure. De ahí salen gNB-ID, nombre, PLMN, TAC, slices, Paging DRX, el AMF que lo acepta y la causa si lo rechaza. Se guarda en `/var/lib/agent5g/gnbs.json`, así que sigue apareciendo aunque el anillo de captura ya no lo tenga.
- **UEs:** las fichas de UEs que cuelgan de cada gNB, deducidas de su CellID (gNB-ID + celda).
- **gNB local:** si su IP coincide con `RADIO_IP` del agente de radio, muestra la configuración del `.env` de ocudu y el estado del contenedor. Avisa si lo que anuncia (PLMN/TAC) no coincide con el `.env`, por falta de recrear, o si el gNB-ID está repetido.

La pestaña la ve también el rol `lector`, pero sin los IMSI.

## Patrón TDD (radio, ocudu)

En *Paràmetres > Ràdio*, la tarjeta «Patró TDD» activa o desactiva el patrón del capítulo 7.
- **Activar:** añade al `.env` las 5 variables (`PERIOD_TDD`, `DL_SLOTS`, `DL_SYMBOLS`, `UL_SLOTS`, `UL_SYMBOLS`) y al `docker-compose.yml`, dentro de `cell_cfg`, el bloque `tdd_ul_dl_cfg` entre las marcas `# >>> panel5g` y `# <<< panel5g`.
- **Desactivar:** quita las variables y el bloque. Así ocudu vuelve a su patrón por defecte.
- **Copias:** guarda una de los dos ficheros antes de tocarlos.
- **Valores por defecto de ocudu** (`du_high_config.h`, `tdd_ul_dl_pattern_unit_config`): periodo de 10 slots, 6 slots DL, 8 símbolos DL, 3 slots UL y 0 símbolos UL.
- **Comprobaciones:**
  - que la banda sea TDD;
  - que la periodicidad sea 3GPP según la SCS (con 30 kHz: 2, 4, 5, 6, 8, 10 o 20 slots);
  - que haya como mínimo 1 slot DL y 1 slot UL;
  - que DL+UL no supere el periodo;
  - que el slot especial deje al menos 1 símbolo de guarda.
- **Instalación:** en la radio hay que actualizar el agente con `sudo bash scripts/actualitzar_agent_radio.sh`, y en el core el panel con `scripts/actualitzar.sh`.

## Varios PLMN (opción avanzada, con interruptor)

En *Paràmetres*, la tarjeta «Diversos PLMN» empieza bloqueada. Para desbloquearla, un admin tiene que marcar «Entenc què modifica» y pulsar «Desbloquejar». Lo hace como en el capítulo 7, con bloques entre marcas `# >>> panel5g: multi-PLMN` y guardando copia de cada fichero:

- **Core** (`docker_open5gs`):
  - `amf/amf.yaml`: duplica la primera entrada de `guami` (con `set: 2`), de `tai` y de `plmn_support`, usando `MCC_2`/`MNC_2`.
  - `nrf/nrf.yaml`: añade una entrada a `serving`.
  - `amf_init.sh` y `nrf_init.sh`: añaden el `sed` de `MCC_2`/`MNC_2` justo después del `cp`, **antes** del `sed` genérico de `MCC`/`MNC`. Si fuera después, esos `sed` convertirían `MCC_2` en `214_2`.
  - `.env`: añade `MCC_2`/`MNC_2`. El PLMN principal sigue siendo `MCC`+`MNC`, no `MCC_1`/`MNC_1` como en el capítulo, porque el resto de NF ya usan `MCC`/`MNC`.
  - Para aplicarlo hay que recrear `amf` y `nrf`.
- **Radio** (ocudu): en el `docker-compose.yml` añade `PLMN_2` a `plmn_list` (`supported_tracking_areas`) y `additional_plmns: "${PLMN_2}"` a `cell_cfg`. `PLMN_2` va al `.env`. Para aplicarlo hay que recrear `gnb`.
- **Desactivar** quita los bloques y las variables que añadió el panel. Una variable que ya estaba en el `.env` antes de activar (como `PLMN_2`) se queda.

## Subscriptores (sustituye la WebUI) y VoIP

Pestaña **Subscriptors** (solo admin), core:

- Lista, alta, edición y baja de abonados de Open5GS en MongoDB vía `docker exec -i mongo mongosh`. Los datos van por stdin en EJSON canónico: los enteros quedan como int32 y el `sqn` como int64, igual que la WebUI (si no, Open5GS los ignora sin avisar).
- K/OPc/OP nunca salen del core: el panel solo ve si existen. Al editar, en blanco = se conservan. Se guardan con el formato de la WebUI (`XXXXXXXX XXXXXXXX ...`).
- Al editar se conservan los campos que el panel no toca (`pcc_rule`, `lbo_roaming_allowed`, `smf`, `_id`, `imeisv`...).
- Importación CSV `imsi,k,opc[,msisdn]` con los slices/DNN de un abonado plantilla.

**VoIP (IMS)**: la sección aparece sola si el contenedor `pyhss` está en marcha (versión VoIP del core). Interfaz: abonado (IMSI) + número. Por dentro, en este orden:

1. Lee de MongoDB K/OPc/AMF del abonado (tiene que existir en 5G).
2. Comprueba que el número está libre en PyHSS (`ims_subscriber.msisdn` es UNIQUE) y en MongoDB.
3. Crea los APN `internet` e `ims` en PyHSS si faltan (usa los más antiguos si están repetidos).
4. MongoDB: añade el DNN `ims` al slice por defecto (IPv4, 5QI 5, ARP 1, 3850/1530 kbps y las reglas PCC 5QI 1 y 2 de 128/512 kbps, como tus abonados 1001/1002) y pone el número como primer MSISDN.
5. PyHSS por su API REST (`http://PYHSS_IP:8080`, la de docker_open5gs): AuC con las mismas K/OPc/AMF que Open5GS, subscriber (APN por defecto internet, `apn_list` internet+ims) e IMS subscriber (`msisdn_list`, `default_ifc.xml`, S-CSCF `sip:scscf.<dominio IMS>:6060`). El dominio sale de MCC/MNC del contenedor pyhss, igual que en `pyhss_init.sh`.
6. Si algo falla, deshace lo creado y restaura el documento de MongoDB. Al final vuelve a leerlo todo y verifica.

Es idempotente: «Repara» vuelve a ejecutar los pasos y solo cambia lo que no cuadra. Cambiar las K/OPc en Subscriptors las sincroniza en PyHSS. Borrar un abonado 5G borra también su VoIP.

Fallos de PyHSS 1.0.x que tiene en cuenta (comprobados con la copia real):

- un GET que no encuentra nada devuelve `null` (con 200 o 400), no un 404;
- los errores incluyen la SQL con Ki/OPc, así que el panel nunca los reenvía tal cual;
- la WebUI guarda las claves con espacios y PyHSS sin espacios: se comparan normalizadas.

La pestaña avisa si las claves de PyHSS y de Open5GS no coinciden (el 5G registra pero el REGISTER IMS falla), si falta el DNN ims o el APN ims, o si el IMSI no es del PLMN del core IMS.

## Interfaz (v15)
Barra lateral, tema claro/oscuro (botón abajo a la izquierda; se recuerda en el navegador y, si no se elige,
sigue al sistema) y fondo con esquemas 5G (`static/fons5g-*.svg`). Las etiquetas ya no muestran los nombres de
las variables del `.env`; los mensajes de validación sustituyen el nombre interno por la etiqueta.
Las opciones avanzadas (patrón TDD, segundo PLMN) son interruptores Activado/Desactivado + Desa.
Un UE registrado en CM-IDLE se muestra como «Connectat (en repòs)», en verde.

## Varias radios (descubrimiento)
El panel busca agentes cada 2 min. Por defecto en la /24 de cada agente de `panel.yaml` con IP de LAN
(con la config actual: 192.168.2.0/24) y en el puerto de la radio (9543). Solo añade un equipo si
presenta un certificado firmado por la CA del panel, emitido para esa IP, y acepta el certificado
cliente del panel. Si deja de responder 3 búsquedas seguidas, desaparece. Opcional en `panel.yaml`:
```yaml
descobriment:
  actiu: true
  xarxes: ["192.168.2.0/24", "10.240.4.0/24"]   # como mucho /22 cada una
  port: 9543
  interval_s: 120
```
Radio nueva: en el core, `sudo emparella-radio <IP_radio>` imprime el **código de emparejamiento**
(ver más abajo) y en la radio `install_radio.sh` lo pide. Se puede poner `"name": "Ràdio aula 2"` en
`/etc/agent5g/agent5g.json` de la radio.

## Servicio VoIP activable
Abonats i VoIP → «Servei de telefonia» → Activado. El agente del core, en segundo plano:
1. Si faltan, baja `docker_kamailio`, `docker_pyhss` y `docker_mysql` de ghcr.io/herlesupreeth (como dice
   el README de docker_open5gs) y las etiqueta; `dns` y `rtpengine` las construye compose.
2. `docker compose -f sa-vonr-deploy.yaml up -d --no-deps --build dns mysql rtpengine pyhss icscf scscf pcscf smsc`
   (mismo proyecto y `.env`; los contenedores del core 5G no se tocan).
3. Espera a la API de PyHSS y da de alta VoIP a todos los abonados que tienen número de teléfono.
Desactivar = `docker compose stop` de esos servicios (los datos de MySQL se conservan).
Requisitos: el `project_dir` del core debe tener `sa-vonr-deploy.yaml` y las carpetas IMS (versión normal+ip).
Desde v15, guardar un abonado con número (VoIP activo) lo da de alta en IMS solo; quitarle el número lo da de
baja. Un número no puede repetirse entre abonados.

## Instalación en el core: solo el agente (sin preguntas)
`sudo bash scripts/install_core.sh <carpeta docker_open5gs> <compose> <IP_LAN> [carpeta_certs]`
Lo llama `core5g.sh` (paso 12) tras levantar el núcleo. Crea la CA si no existe (`/root/certs-5g`, modo
`gen_certs.sh --core`, que deja también los certificados del panel en `certs-5g/panel/`), instala tshark y
**solo el agente del core** (mTLS en `0.0.0.0:9543`, captura NGAP/SBI, User-Agent, VoIP activable) con su
`agent5g.json` generado del compose real. **No instala el panel** (eso es `scripts/install_panel.sh`, aparte).
Al final imprime el código de emparejamiento de cada radio: `CORE5G_RADIOS="IP1 IP2"` o, con terminal, lo
pregunta. Repetirlo es seguro: no cambia certificados existentes.
`core5g.sh` descarga este repositorio de `CORE5G_PANELL_REPO` (o usa `--panell carpeta|tar.gz`; `--sense-panell` lo omite).

### Código de emparejamiento
`sudo emparella-radio <IP_radio>` (en el core, donde está la CA) emite el certificado de esa radio y
imprime un bloque `-----BEGIN 5GPANEL EMPARELLAMENT <IP>----- … -----END 5GPANEL EMPARELLAMENT-----`:
base64 de un tar.gz con `ca.crt`, `agent-radio.crt` y `agent-radio.key`. **Nunca lleva `ca.key`**, pero sí
la clave privada del agente de esa radio: no lo publiques. Se guarda también en
`/root/certs-5g/emparellament-<IP>.txt` por si prefieres copiarlo con scp.

## Instalación de la radio (guía de despliegue, apartado de la parte radio)
`sudo bash scripts/install_radio.sh [--core IP] [--radio IP] [--emparellament fichero] [--ocudu DIR] [--sense-build] [--sense-agent]`
1. git, curl y Docker (get.docker.com), usuario al grupo docker.
2. `git clone https://gitlab.com/ocudu/ocudu.git` en `~/ocudu` (si ya está, no toca el código).
3. `docker/docker-compose.yml` unificado (Anexo A): un solo servicio `gnb`, `network_mode: host`, toda la
   configuración dentro parametrizada con el `.env` (el original queda en `docker-compose.yml.orig`).
4. `docker/.env` con el bloque del Anexo B delante; el resto del `.env` se conserva. Valores: los que ya
   tenga el `.env` > variables de entorno (`PLMN=… TAC=…`) > los de la guía.
5. Imágenes UHD de la B210 (`uhd_images_downloader`).
6. `docker compose -f docker/docker-compose.yml build` (~40 min la primera vez) y `up -d`.
7. Agente de la radio (mTLS en `<IP_radio>:9543`) con los certificados del código de emparejamiento.

El código se valida **antes** de la parte lenta (que sea de esa IP y de la misma CA).
Diferencias con la guía para que el panel pueda gestionarla: `PLMN_1` en vez de `PLMN`, antenas
parametrizadas (`RX_ANTENA`/`TX_ANTENA`, 1 por defecto) y el gNB arranca en segundo plano (`docker logs -f ocudu_gnb`).
Si ufw está activo no se toca: el script indica la regla para abrir el 9543 a la /24.

## Siempre en marcha
`agent5g`, `ngap-capture` y `ua-capture` son servicios systemd habilitados con `Restart=always`,
`RestartSec=3` y sin límite de reintentos (`StartLimitIntervalSec=0`): arrancan solos al encender el PC,
vuelven si se caen o se reinicia Docker, y no dependen del panel (si el panel se reinicia, los agentes siguen).
