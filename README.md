# Panel 5G (core Open5GS + gNB ocudu)

Interfaz web (por defecto en PC1, core; puede ir en cualquiera de los dos PCs) para ver el estado de los dos despliegues, editar los `.env` con validación y aplicar los cambios recreando servicios. La interfaz y el código están en catalán, como `core5g.sh`.

## Arquitectura

```
Navegador ──HTTPS + login──► panel5g (Docker, PC del core, IP_core:8443)
                                 │ mTLS (host.docker.internal:9543)
                                 ▼
                agent5g del core ◄──── mTLS, puerto 9544 ──── agent5g de cada radio
                .env de docker_open5gs   (la RADIO abre la      .env de ocudu/docker
                                          conexión y la mantiene)
```
Un **PC con UPF** (`agent5g-upf`) llama al core igual que una radio (ver «UPF separado»).

**La radio llama al core**, igual que la gNodeB llama al AMF: el agente de la radio no escucha ningún
puerto, abre él las conexiones cifradas hacia el puerto 9544 del core y las mantiene. Al core le da igual
la IP de la radio; **la única IP fija es la del core**. Ver «Enlace radio → core» más abajo.

- **Panel** (`panel/`): FastAPI. Login con contraseña scrypt, roles `admin` / `lector`, cookie `Secure`/`HttpOnly`/`SameSite=Strict`, token CSRF, límite de 5 intentos por IP cada 5 min, CSP estricta. El contenedor es de solo lectura, sin capacidades y corre como usuario sin privilegios.
- **Agente** (`agent/agent5g.py`): solo usa la biblioteca estándar de Python y corre como servicio systemd. Solo acepta peticiones del panel (certificado de la CA propia y CN `panel5g`; en la radio, a través del agente del core). Lo único que sabe hacer está en lista blanca: leer logs de contenedores permitidos, leer el `.env` (oculta los secretos), editar claves permitidas (con regex), restaurar copias y hacer `docker compose up -d --no-deps <servicio permitido>`. Hace una copia antes de cada escritura (guarda las 50 últimas) y lleva auditoría en `/var/lib/agent5g/audit.log`.
- **Validación** (`panel/config/schema.yaml`): valores permitidos y reglas cruzadas. SRATE tiene que estar en la lista de la B210, ser ≥ 1.152 × ancho y como máximo 46.08 (23.04 y 20 MHz con 2x2). El ARFCN tiene que caer dentro de la banda y la frecuencia, dentro del rango de la B210. Además avisa si el PLMN del gNB no coincide con el MCC+MNC del core.
- **Mapa de reinicios** (`panel/config/restart_map.yaml`): indica qué servicios hay que recrear para cada clave. El del core está **vacío, pendiente de definir**. Mientras tanto, los servicios se eligen a mano en el panel.

## Instalación

**Un solo instalador, en castellano: `core5g.sh`** (en la raíz del repositorio). Pregunta primero el rol del PC:

```
curl -fsSL https://raw.githubusercontent.com/fernandoepp/5gpanel/main/core5g.sh -o core5g.sh
sudo bash core5g.sh
```

- **Core**: el menú de siempre (red, versión, instalar). El agente y el panel web son el extra «panel5g» de la versión genérica.
- **Radio**: ejecuta `scripts/install_radio.sh` (Docker, ocudu, gNodeB) y pregunta si instala también el agente del panel. Con agente pide el código de emparejamiento.
- **UPF**: ejecuta `scripts/install_upf.sh` y pregunta lo mismo. Sin agente, solo pide la IP del core, y el core se separa a mano (extra «sin UPF»).
- **Desinstalar**: `scripts/desinstala.sh`.

Lo que hace cada pieza por dentro:

1. **Core**: `core5g.sh` (paso 12) llama a `scripts/install_core.sh`, que crea la CA e instala el agente del core
   (puerto 9543 para el panel y 9544 para las radios). Panel: `scripts/install_panel.sh` (ver más abajo).
2. **Cada radio**: en el core `sudo emparella-radio <nombre>` (p. ej. `aula2`) y en la radio
   `sudo bash scripts/install_radio.sh --emparellament codigo.txt` (o pega el código cuando lo pida).
3. **UPF en otro PC (opcional)**: en el core `sudo emparella-upf <nombre>` y en ese PC
   `sudo bash scripts/install_upf.sh` (pega el código). El resto se hace solo.
4. Importa `certs-5g/ca/ca.crt` como CA de confianza en los navegadores del laboratorio.

Volver a ejecutar un instalador **solo instala lo que falta**: lo que ya está no se toca. Para poner la
versión nueva de algo: `sudo bash scripts/desinstala.sh` (o `core5g.sh` → Desinstalar) y luego el
instalador otra vez (ver «Desinstalar y reinstalar»).

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
- Con el enlace radio → core, el cambio de IP de la radio no afecta al panel. Lo único que tiene que ser fijo es la IP del core (resérvala en el router).
- Para la IP del core usa `sudo agent5g` (ver más abajo): también renueva los certificados. `scripts/canviar_xarxa.sh core <IP_radio>` (en el core) y `scripts/canviar_xarxa.sh radio <IP_core>` (en la radio) cambian las IPs viejas por las nuevas en `.env`, `sa-deploy.yaml`, `smf.yaml`, `panel.yaml`, `upf_remot/.env` y el `.env` de ocudu, con copia de cada fichero, y recrean el SMF, el panel, la UPF y la gNB. Con `-n` solo muestra lo que cambiaría.

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

### Selector de espectro
Encima de la frecuencia hay un selector «Espectre»: botones con las bandas de `radio.espectre` en `schema.yaml`
(por defecto n28, n40, n77 y n78, con su rango entre paréntesis) y un dibujo de la banda elegida. Al pinchar
en el dibujo se fija la frecuencia central (limitada para que quepa todo el canal) y se recalculan ARFCN, banda
y SCS como al escribirla. En FDD (n28) se dibuja también la **subida** aparejada (bajada − 55 MHz): no se
configura en ningún sitio, el móvil transmite ahí solo. En TDD se indica que subida y bajada usan la misma
frecuencia. Las bandas FDD de `schema.yaml` llevan ahora `ul_mhz`.

## Pestaña gNodeB

Una card por cada gNB que se conecta al AMF:
- **Estado en vivo del AMF (`/gnb-info`):** qué gNB están conectados ahora, con gNB-ID, nombre, PLMN, TAC y slices. Manda sobre el log y la captura.
- **Log del AMF:** conexiones y cortes SCTP (N2), y avisos de NG Setup como «Cannot find Served TAI».
- **Captura N2 (`GET /gnbs` del agente):** NG Setup Request/Response/Failure. De ahí salen gNB-ID, nombre, PLMN, TAC, slices, Paging DRX, el AMF que lo acepta y la causa si lo rechaza. Se guarda en `/var/lib/agent5g/gnbs.json`, así que sigue apareciendo aunque el anillo de captura ya no lo tenga.
- **UEs:** las fichas de UEs que cuelgan de cada gNB, deducidas de su CellID (gNB-ID + celda).
- **gNB local:** si su IP coincide con `RADIO_IP` del agente de radio, muestra la configuración del `.env` de ocudu y el estado del contenedor. Avisa si lo que anuncia (PLMN/TAC) no coincide con el `.env`, por falta de recrear, o si el gNB-ID está repetido.

La pestaña la ve también el rol `lector`, pero sin los IMSI.

## TAC del core (amf.yaml)
En *Paràmetres > Core*, «Codis d'àrea acceptats (TAC)»: uno o varios separados por comas (`1` o `1,2,7`, uno
por gNodeB si tienen TAC distintos). Al guardar, el agente deja el core preparado para leerlo del `.env`:
- `amf/amf.yaml`: cada `tac:` de la lista `tai` pasa a `tac: [TAC]` (antes podía ser `tac: TAC` o un número escrito a mano).
- `amf/amf_init.sh`: si no tiene el `sed` de `TAC`, se añade justo después del `cp`, entre marcas `# >>> panel5g: TAC`.
- `.env`: `TAC=…` (si no existía, se añade debajo de `MNC`).
Copia de los tres ficheros antes de tocarlos. Queda pendiente recrear `amf` (botón **Aplicar**).
Si el `.env` no tenía `TAC`, el panel muestra el número que había escrito en `amf.yaml`.
La validación avisa si el TAC de algún gNB no está en la lista del core (el AMF lo rechazaría con «Cannot find Served TAI»).

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

## Enlace radio → core (varias radios)
Como la gNodeB con el AMF, **es la radio la que llama al core**:

1. El agente de la radio (`"core": "IP_core"`, `"core_port": 9544` en `/etc/agent5g/agent5g.json`, sin
   `listen`) abre 3 conexiones TLS hacia el agente del core y las deja abiertas, esperando.
2. Cada lado comprueba al otro por el certificado: la radio presenta el suyo (firmado por la CA, CN
   `agent-radio-<nombre>`, con uso «cliente») y solo acepta un core con CN `agent-core`. No se mira la IP
   de nadie: si el DHCP cambia la IP de la radio, sigue funcionando.
3. Cuando el panel quiere hablar con una radio, se lo pide al agente del core (`GET /radios`,
   `/radio/<nombre>/<petición de siempre>`). El core escribe la petición en una de esas conexiones; la radio
   la contesta con la misma lista blanca de siempre, cierra esa conexión y abre otra.
4. **Reconexión sola**: si el core no está (arranque, red que llega tarde, cable, reinicio del core), la
   radio lo reintenta cada 2 s, luego cada vez más espaciado hasta cada 30 s, sin límite. Las conexiones en
   espera se renuevan cada minuto, así que un corte se nota en menos de un minuto.
5. El panel pregunta al core cada 10 s qué radios hay. Una radio aparece sola al conectarse (con el
   `"name"` de su `agent5g.json`, o «Ràdio <nombre>») y desaparece unos 20 s después de irse.

Varias radios = varios códigos de emparejamiento con nombres distintos. Puertos: solo hay que poder llegar
**de la radio al core, puerto 9544/tcp**; la radio no abre ningún puerto (con ufw en el core:
`sudo ufw allow 9544/tcp`). `panel.yaml` ya no lleva radios.

**Pasar una radio ya instalada** (p. ej. server2core5G) al enlace nuevo:
1. Core: `sudo bash scripts/actualitzar.sh` (agente con el puerto 9544, `emparella-radio` nuevo; comenta la
   radio fija de `panel.yaml`, con copia).
2. Core: `sudo emparella-radio <nombre>` → código (lleva la IP del core).
3. Radio: `sudo bash scripts/enllaca_radio.sh codigo.txt`. Solo cambia el agente, sus certificados y
   `listen`/`core` de `agent5g.json` (con copia); no toca el gNB ni su `.env`.

Los códigos de emparejamiento anteriores no sirven (el certificado no tenía uso «cliente» y no llevaban la IP
del core): hay que generarlos de nuevo. La búsqueda por la red del sistema anterior (`descobriment`) queda
desactivada por defecto; solo sirve para radios antiguas que aún escuchan (`descobriment: {actiu: true}`).

## UPF separado (pestaña UPF)
El UPF (por donde pasan los datos de los móviles) puede ir dentro del core o en otro PC. Igual que la radio,
**el PC del UPF llama al core** y al core le da igual su IP:

1. Core: `sudo emparella-upf <nombre>` (p. ej. `upf1`) → código con `ca.crt`, el certificado del UPF
   (CN `agent-upf-<nombre>`) y la IP:puerto del core (9544). Se guarda en `certs-5g/emparellament-upf-<nombre>.txt`.
2. PC del UPF: `sudo bash scripts/install_upf.sh` y pega el código. Instala Docker, la imagen
   `docker_open5gs` (si no está: la construye, o `--imatge fichero.tar`, o `--imatge-de usuario@IP_core` por
   ssh), crea `/opt/upf5g` (compose, `.env`, `upf/` con `advertise: UPF_HOST_IP`) y el servicio
   `agent5g-upf` (independiente del agente de la radio: pueden estar en el mismo PC).
3. Cuando el agente del UPF llama, el core:
   - le pasa lo que necesita de su `.env` (subredes de los móviles, `MAX_NUM_UE`, interfaces, `PCSCF_IP`) y
     las dos IP sacadas de la propia conexión: **`SMF_IP` = IP del core que ve el UPF** y
     **`UPF_HOST_IP` = IP del UPF que ve el core**. El agente del UPF las escribe en su `.env` y (re)crea el
     contenedor `upf` solo si algo ha cambiado;
   - si el **modo automático** está activo (por defecto) y el core usa su propio UPF (o el elegido ya no
     está), **lo selecciona**: `smf/smf.yaml` → `pfcp: server: advertise <IP core>` y `client: upf: <IP del UPF>`;
     compose → `upf` con `profiles: ["upf_local"]` (no arranca) y `8805:8805/udp` publicado en el `smf`
     (líneas marcadas `# panel5g: UPF separat`, copia antes de cada cambio); quita el `upf` local y recrea el `smf`;
   - si el UPF elegido cambia de IP (DHCP), al volver a llamar se aplica la IP nueva sola.
4. Solo un UPF activo a la vez: los demás que llamen quedan conectados con el contenedor parado.
   Tras reiniciar el core, el UPF elegido tiene 30 s para volver a llamar antes de que se elija otro.

Pestaña **UPF** del panel: dónde está el UPF, asociación PFCP del SMF, interruptor «Fer servir sol el UPF que
truqui al core», «Torna a ajuntar el UPF al core» (deshace todo, arranca el `upf` del core, para el remoto y
apaga el modo automático para que no se vuelva a separar solo), «Fes servir aquest UPF» para cada PC conectado,
y «UPF sin agente» por IP (montaje a mano). Monitorización **por HTTP**: métricas del servidor de Open5GS
del UPF (`http://UPF_IP:9091/metrics`: sesiones, paquetes y bytes GTP de N3, peticiones N4), contadores de
`ogstun` dentro del contenedor, logs (`docker logs upf` y `log/upf.log` en Registres) y el estado de cada
PC en Estat. Con la gNB en el mismo PC (se detecta), el 2152 no se publica y la gNB llega al UPF por el puente
de Docker (`UPF_ADVERTISE_IP` = IP del contenedor); si no, se publica `2152/udp` y se anuncia la IP del PC.
Con una VPN de túnel completo como ruta por defecto se añade `ip rule from <red del UPF> lookup main`.

Agente del core: `GET /upf`, `POST /upf {accio: separa|ajunta|auto}`, `GET /upfs`, `/upf/<nombre>/<petición>`.
Agente del UPF: `POST /upf_configura`, `GET /upf_estat`, `GET /upf_metriques`. Si `core5g.sh` se ejecuta con
el extra «sense UPF», sigue funcionando: ajuntar desde el panel también quita sus marcas `# core5g: sense UPF`.

## Idioma del panel (ES / EN / CAT)
Arriba a la derecha hay un selector **ES · EN · CAT**. Se recuerda en el navegador (`localStorage`), y la primera
vez se elige por el idioma del navegador (castellano si no es catalán ni inglés). El panel está escrito en catalán;
`static/i18n.js` traduce lo que se muestra (textos, *tooltips* y confirmaciones) con el diccionario
`panel/i18n/dict.py`. Lo que no está en el diccionario se ve en catalán: sobre todo, algunos mensajes que vienen
de los agentes. Para añadir textos: edita `panel/i18n/dict.py` y ejecuta `python3 scripts/i18n_genera.py`.

## Cambiar la IP del core: `sudo agent5g`
La IP del core **no se cambia desde el navegador**. En Parámetros, `DOCKER_HOST_IP` y `UPF_ADVERTISE_IP` son
de solo lectura y, al pasar el ratón por encima, avisan de que se cambian por terminal. Esto se debe a que la
IP afecta a la vez a los certificados, al panel y a todo el core.

En el core, `sudo agent5g` abre un menú:
1. **Ver la configuración**: IP, carpetas y certificados, con su SAN y su caducidad.
2. **Cambiar la IP del core**. Si la IP nueva todavía no es de este PC y la IP fija viene de
   `/etc/netplan/90-core5g.yaml`, ofrece cambiarla también. Después hace lo siguiente:
   - en `.env`, cambia `DOCKER_HOST_IP` y también `UPF_ADVERTISE_IP` si era la misma IP;
   - en `smf.yaml`, cambia `advertise` si el UPF está separado;
   - actualiza `/etc/agent5g/core_ip` y `/etc/core5g.conf`;
   - renueva el certificado del agente y el web del panel con la **misma CA**;
   - regenera los códigos de emparejamiento con la IP nueva;
   - reinicia todo el core, el panel (`https://<IP nueva>:8443`) y el agente.

   Antes de tocar cada fichero guarda una copia.
3. **Renovar los certificados** con la misma IP.

En cada radio o PC con UPF, `sudo agent5g` → *Cambiar la IP del core*. Actualiza `"core"` en
`agent5g.json` y, en la radio, `CORE_IP` del `.env` de ocudu (y recrea la gNB). Después reinicia el agente.
**No hace falta volver a emparejar**, porque el certificado de la radio sigue valiendo con la misma CA.
`desinstala.sh` quita también el comando `agent5g`.

**Actualizar desde GitHub**: en cualquier PC (core, radio o UPF), `sudo agent5g` → *Actualizar desde GitHub*
descarga la última versión de `main` y la instala, con copia en `/var/lib/agent5g*/bak-…`. En el core ejecuta
`actualitzar.sh` (agente, herramientas de emparejamiento, menú y panel web si está en ese PC). En la radio y el
UPF copia el agente y el menú, y reinicia el servicio; si no arranca, vuelve a la versión anterior. No toca el
core 5G, la gNB, los certificados ni la configuración. Muestra la versión instalada y la nueva. Para otra rama:
`sudo AGENT5G_BRANCA=<rama> agent5g`.

## Desinstalar y reinstalar
`sudo bash scripts/desinstala.sh` (o `core5g.sh` → 5) muestra qué hay instalado en ese PC y quita lo que
elijas: **agente del core** (agent5g, capturas, `emparella-*`), **panel web** (contenedor e imagen),
**agente de la radio** o **UPF separado** (agent5g-upf, contenedor `upf`, red `upf5g`). Sin preguntas:
`--core --panell --radio --upf --tot -y`. Nunca toca el core 5G, el gNB, los abonados ni la CA (los
emparejamientos siguen valiendo). Guarda `panel.yaml` en `/var/lib/panel5g/` y el certificado de la radio/UPF
en `/var/lib/agent5g*/emparellament/`, así que al reinstalar **no hace falta volver a pegar el código**.
`--purga` borra también esas copias y `/var/lib/agent5g*`.

Después, los instaladores solo instalan lo que falta: `core5g.sh` → Instal·lar (si el agente y el panel ya
están no los toca), `install_radio.sh` (si el agente ya está, no pide código ni lo toca), `install_upf.sh`
(si ya está, no hace nada). `--forcar` reinstala igualmente. Para actualizar el core sin desinstalar sigue
existiendo `scripts/actualitzar.sh`.

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
Al final imprime el código de emparejamiento de cada radio: `CORE5G_RADIOS="aula1 aula2"` (nombres) o,
con terminal, lo pregunta. Guarda la IP del core en `/etc/agent5g/core_ip` para los códigos. Repetirlo es seguro: no cambia certificados existentes.
`core5g.sh` descarga este repositorio de `CORE5G_PANELL_REPO` (o usa `--panell carpeta|tar.gz`; `--sense-panell` lo omite).

### Código de emparejamiento
`sudo emparella-radio <nombre>` (en el core, donde está la CA) emite el certificado de esa radio y
imprime un bloque `-----BEGIN 5GPANEL EMPARELLAMENT <nombre>----- … -----END 5GPANEL EMPARELLAMENT-----`:
base64 de un tar.gz con `ca.crt`, `agent-radio.crt`, `agent-radio.key` y `core` (IP:puerto del core al que
debe llamar; `CORE5G_CORE_IP=…` para otra). **No hace falta la IP de la radio.** **Nunca lleva `ca.key`**,
pero sí la clave privada del agente de esa radio: no lo publiques. Se guarda también en
`/root/certs-5g/emparellament-<nombre>.txt` por si prefieres copiarlo con scp.

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
7. Agente de la radio con los certificados del código: **llama al core** (IP:puerto del código) y no escucha ningún puerto.

El código se valida **antes** de la parte lenta (misma CA, certificado nuevo con uso «cliente», IP del core).
`--core` es opcional: por defecto se usa la IP del core del código.
Diferencias con la guía para que el panel pueda gestionarla: `PLMN_1` en vez de `PLMN`, antenas
parametrizadas (`RX_ANTENA`/`TX_ANTENA`, 1 por defecto) y el gNB arranca en segundo plano (`docker logs -f ocudu_gnb`).

## Siempre en marcha
`agent5g`, `ngap-capture` y `ua-capture` son servicios systemd habilitados con `Restart=always`,
`RestartSec=3` y sin límite de reintentos (`StartLimitIntervalSec=0`): arrancan solos al encender el PC,
vuelven si se caen o se reinicia Docker, y no dependen del panel (si el panel se reinicia, los agentes siguen).
