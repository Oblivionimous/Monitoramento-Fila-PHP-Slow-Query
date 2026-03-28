#!/bin/bash
# =============================================================================
# monitor_app.sh — Monitor PHP-FPM + Sessions + Log
# Uso: bash monitor_app.sh
# Log: /var/log/glpi_monitor_app.log
#
# Variaveis configuraveis no topo do script:
#   FPM_STATUS   - URL da pagina de status do PHP-FPM
#   SESSION_DIR  - Diretorio de sessoes PHP
#   INTERVAL     - Intervalo de atualizacao em segundos
#   LOG_FILE     - Caminho do arquivo de log
#   LOG_MAX_MB   - Tamanho maximo do log antes da rotacao (em MB)
# =============================================================================

FPM_STATUS="http://127.0.0.1:8000/status"
SESSION_DIR="/var/lib/php/session"
INTERVAL=2
LOG_FILE="/var/log/glpi_monitor_app.log"
LOG_MAX_MB=50

# Cores ANSI
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYA='\033[0;36m'; WHT='\033[1;37m'; RST='\033[0m'

log() {
  local LEVEL="$1"; shift
  local MSG="$*"
  local TS
  TS=$(date '+%d/%m/%Y %H:%M:%S')
  if [ -f "$LOG_FILE" ]; then
    local SIZE_MB
    SIZE_MB=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1)
    if [ "${SIZE_MB:-0}" -ge "$LOG_MAX_MB" ]; then
      mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d_%H%M%S').bak"
    fi
  fi
  echo "[$TS] [$LEVEL] $MSG" >> "$LOG_FILE"
}

monitor_app() {
  local TS HOSTNAME
  TS=$(date '+%d/%m/%Y %H:%M:%S')
  HOSTNAME=$(hostname)

  echo -e "${WHT}════════════════════════════════════════════════════════════════${RST}"
  echo -e "${WHT}  APP MONITOR — $HOSTNAME — $TS${RST}"
  echo -e "${WHT}  Log: $LOG_FILE${RST}"
  echo -e "${WHT}════════════════════════════════════════════════════════════════${RST}"

  # ── PHP-FPM Resumo ────────────────────────────────────────────────────
  echo -e "\n${CYA}── PHP-FPM Pool Status ─────────────────────────────────────────────${RST}"
  FPM_RAW=$(curl -s "$FPM_STATUS" 2>/dev/null)

  if [ -z "$FPM_RAW" ]; then
    echo -e "  ${RED}[!] PHP-FPM status inacessivel em $FPM_STATUS${RST}"
    log "ERROR" "PHP-FPM status inacessivel em $FPM_STATUS"
  else
    ACCEPTED=$(echo "$FPM_RAW"  | grep "accepted conn"        | awk '{print $NF}')
    ACTIVE=$(echo "$FPM_RAW"    | grep "^active processes"    | awk '{print $NF}')
    IDLE=$(echo "$FPM_RAW"      | grep "^idle processes"      | awk '{print $NF}')
    TOTAL=$(echo "$FPM_RAW"     | grep "^total processes"     | awk '{print $NF}')
    QUEUE=$(echo "$FPM_RAW"     | grep "^listen queue:"       | awk '{print $NF}')
    MAX_ACT=$(echo "$FPM_RAW"   | grep "max active processes" | awk '{print $NF}')
    MAX_CHILD=$(echo "$FPM_RAW" | grep "max children reached" | awk '{print $NF}')
    SLOW_REQ=$(echo "$FPM_RAW"  | grep "slow requests"        | awk '{print $NF}')
    UPTIME=$(echo "$FPM_RAW"    | grep "start since"          | awk '{print $NF}')

    [ "${ACTIVE:-0}"    -gt 10 ] 2>/dev/null && ACT_C="${RED}" || \
    { [ "${ACTIVE:-0}" -gt 5  ] 2>/dev/null && ACT_C="${YEL}" || ACT_C="${GRN}"; }
    [ "${QUEUE:-0}"     -gt 0  ] 2>/dev/null && Q_C="${RED}"   || Q_C="${GRN}"
    [ "${MAX_CHILD:-0}" -gt 0  ] 2>/dev/null && MC_C="${YEL}"  || MC_C="${GRN}"

    UPTIME_FMT=$(printf '%dh%02dm%02ds' \
      $((${UPTIME:-0}/3600)) \
      $(( (${UPTIME:-0}%3600)/60 )) \
      $((${UPTIME:-0}%60)))

    echo -e "  Processos : total=${WHT}$TOTAL${RST}  active=${ACT_C}$ACTIVE${RST}  idle=${GRN}$IDLE${RST}"
    echo -e "  Fila      : listen_queue=${Q_C}$QUEUE${RST}  max_active=${WHT}$MAX_ACT${RST}  max_children_reached=${MC_C}$MAX_CHILD${RST}"
    echo -e "  Counters  : accepted_conn=${WHT}$ACCEPTED${RST}  slow_requests=${YEL}$SLOW_REQ${RST}"
    echo -e "  Uptime    : ${WHT}$UPTIME_FMT${RST}"

    log "INFO" "FPM: total=$TOTAL active=$ACTIVE idle=$IDLE queue=$QUEUE accepted=$ACCEPTED slow_req=$SLOW_REQ max_children=$MAX_CHILD"

    [ "${ACTIVE:-0}"    -gt 20 ] && log "WARN" "FPM processos ativos elevados: $ACTIVE"
    [ "${QUEUE:-0}"     -gt 0  ] && log "WARN" "FPM listen queue=$QUEUE — requisicoes represadas"
    [ "${MAX_CHILD:-0}" -gt 0  ] && log "WARN" "FPM max_children_reached=$MAX_CHILD — pool saturou"
    [ "${SLOW_REQ:-0}"  -gt 0  ] && log "WARN" "FPM slow_requests=$SLOW_REQ"
  fi

  # ── PHP-FPM Processos Ativos ──────────────────────────────────────────
  echo -e "\n${CYA}── PHP-FPM Processos Ativos Agora ──────────────────────────────────${RST}"
  FPM_FULL=$(curl -s "${FPM_STATUS}?full" 2>/dev/null)
  FOUND_RUNNING=0

  while IFS= read -r block; do
    [ -z "$block" ] && continue
    PID=$(echo "$block"   | grep "^pid:"               | awk '{print $NF}')
    STATE=$(echo "$block" | grep "^state:"             | awk '{print $NF}')
    URI=$(echo "$block"   | grep "^request URI:"       | awk '{print $NF}')
    DUR=$(echo "$block"   | grep "^request duration:"  | awk '{print $NF}')
    CPU=$(echo "$block"   | grep "^last request cpu:"  | awk '{print $NF}')
    MEM=$(echo "$block"   | grep "^last request memory:" | awk '{printf "%.1f", $NF/1024/1024}')

    if [ "$STATE" = "Running" ] && [ -n "$PID" ]; then
      DUR_MS=$(awk "BEGIN {printf \"%.0f\", ${DUR:-0}/1000}")
      echo -e "  PID ${WHT}$PID${RST} | ${YEL}Running${RST} | ${WHT}$URI${RST} | ${DUR_MS}ms | CPU: $CPU% | Mem: ${MEM}MB"
      log "INFO" "FPM running: pid=$PID uri=$URI duration=${DUR_MS}ms cpu=$CPU% mem=${MEM}MB"

      [ "${DUR_MS:-0}" -gt 5000 ] && log "WARN" "FPM processo lento: pid=$PID uri=$URI duration=${DUR_MS}ms"
      FOUND_RUNNING=1
    fi
  done < <(echo "$FPM_FULL" | awk '
    /^\*{24}/ { if (block) print block "---END---"; block="" }
    { block = block $0 "\n" }
    END { if (block) print block "---END---" }
  ' | awk 'BEGIN{RS="---END---\n"} {print}')

  [ "$FOUND_RUNNING" -eq 0 ] && echo -e "  ${GRN}✓ Nenhum processo em execucao no momento${RST}"

  # ── Top 5 por CPU ─────────────────────────────────────────────────────
  echo -e "\n${CYA}── Top 5 Ultimas Requisicoes (por CPU) ─────────────────────────────${RST}"
  echo "$FPM_FULL" | awk '
    /^\*{24}/ { pid=""; uri=""; cpu=0; mem=0; dur=0 }
    /^pid:/               { pid=$NF }
    /^request URI:/       { uri=$NF }
    /^request duration:/  { dur=$NF }
    /^last request cpu:/  { cpu=$NF+0 }
    /^last request memory:/ {
      mem=$NF/1024/1024
      if (pid && uri && uri != "-")
        printf "%010.2f|%s|%s|%.1f|%.0f\n", cpu, pid, uri, mem, dur/1000
    }
  ' | sort -rn | head -5 | \
  awk -F'|' '{printf "  PID %-6s | %-40s | CPU: %6s%% | Mem: %5.1fMB | Last: %sms\n", $2, $3, $1+0, $4, $5}'

  # ── PHP Sessions ──────────────────────────────────────────────────────
  echo -e "\n${CYA}── PHP Sessions em Disco ───────────────────────────────────────────${RST}"
  SESS_COUNT=$(ls "$SESSION_DIR" 2>/dev/null | wc -l)
  SESS_OLD=$(find "$SESSION_DIR" -type f -amin +30 2>/dev/null | wc -l)
  SESS_SIZE=$(du -sh "$SESSION_DIR" 2>/dev/null | cut -f1)
  SESS_NEW=$(find "$SESSION_DIR" -type f -mmin -2 2>/dev/null | wc -l)

  [ "${SESS_COUNT:-0}" -gt 200 ] 2>/dev/null && SC_C="${RED}" || \
  { [ "${SESS_COUNT:-0}" -gt 50 ] 2>/dev/null && SC_C="${YEL}" || SC_C="${GRN}"; }

  echo -e "  Total: ${SC_C}$SESS_COUNT${RST}  |  Novas (<2min): ${WHT}$SESS_NEW${RST}  |  Ociosas (>30min): ${YEL}$SESS_OLD${RST}  |  Tamanho: ${WHT}$SESS_SIZE${RST}"
  echo -e "  ${RED}⚠ Session Locking ativo — instalar Redis para eliminar este gargalo${RST}"

  log "INFO" "Sessions: total=$SESS_COUNT novas=$SESS_NEW ociosas=$SESS_OLD tamanho=$SESS_SIZE"

  # ── Rodape ────────────────────────────────────────────────────────────
  echo -e "\n${WHT}  Refresh: ${INTERVAL}s | Log: $LOG_FILE | Ctrl+C para sair${RST}"
  echo -e "${WHT}════════════════════════════════════════════════════════════════${RST}"
}

export -f monitor_app log
export FPM_STATUS SESSION_DIR LOG_FILE LOG_MAX_MB
export RED YEL GRN CYA WHT RST

echo "[$(date '+%d/%m/%Y %H:%M:%S')] [INFO] ===== monitor_app.sh iniciado =====" >> "$LOG_FILE"
watch -n $INTERVAL -c "bash -c monitor_app"
