# Scripts sencillos: núcleo y UPF (sin agente ni panel)

Dos scripts independientes que descargan `herlesupreeth/docker_open5gs` y aplican la
configuración del despliegue del TFG. Cada uno abre un menú donde pones las IP y eliges
"INSTALAR". No instalan el agente ni el panel web (para eso está `core5g.sh`).

| Script | En qué PC | Qué pregunta |
|---|---|---|
| `instalar_core.sh` | PC del núcleo | IP de este PC, PLMN (00101), TAC (1), UPF aquí o en otro PC (su IP) |
| `instalar_upf.sh` | PC del UPF separado | IP del núcleo, IP de este PC, si la radio está en este PC |

```bash
curl -fsSLO https://raw.githubusercontent.com/fernandoepp/5gpanel/main/scripts/simples/instalar_core.sh
sudo bash instalar_core.sh

curl -fsSLO https://raw.githubusercontent.com/fernandoepp/5gpanel/main/scripts/simples/instalar_upf.sh
sudo bash instalar_upf.sh
```

Sin menú: `sudo bash instalar_core.sh --ip 192.168.1.100 --upf-remoto 192.168.1.31 --si` y
`sudo bash instalar_upf.sh --core 192.168.1.100 --si` (ver `--help`).

Qué aplican:
- Núcleo: `.env` con MCC/MNC/TAC, `DOCKER_HOST_IP` y `UPF_ADVERTISE_IP` = IP del PC; publica
  38412/sctp (AMF) y 2152/udp (UPF); arregla los `*_init.sh` que no sustituyen MCC/MNC; arranca
  `sa-deploy.yaml` (slice SST 1). Con UPF en otro PC: el SMF publica 8805/udp, se anuncia con la
  IP del PC y apunta al UPF remoto; el `upf` local queda en el perfil `upf_local` (no arranca).
- UPF: red Docker 172.23.0.0/24 (UPF en .8), publica 8805/udp y 2152/udp (el 2152 no si la gNB
  está en el mismo PC), se anuncia al SMF con la IP del PC, subredes de móviles 192.168.100.0/24
  y 192.168.101.0/24 (las del núcleo).

Se instalan en `~/core5g_simple/`. Volver a ejecutarlos es seguro: no se descarga otra vez y la
configuración se vuelve a aplicar desde los originales (`*.orig`).
