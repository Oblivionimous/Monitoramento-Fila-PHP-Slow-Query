#!/bin/bash
# =============================================================================
# monitor_db.sh — Monitor MySQL em Tempo Real + Log
# Uso: bash monitor_db.sh
# Pre-requisito: ~/.my.cnf com user e password configurados
# Log: /var/log/glpi_monitor_db.log
#
# Variaveis configuraveis no topo do script:
#   INTERVAL     - Intervalo de atualizacao em segundos
#   LOG_FILE     - Caminho do arquivo de log
#   LOG_MAX_MB   - Tamanho maximo do log antes da rotacao (em MB)
# =============================================================================

INTERVAL=2
LOG_FILE="/var/log/glpi_monitor_db.log"
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

monitor_db() {
  local TS HOSTNAME
  TS=$(date '+%d/%m/%Y %H:%M:%S')
  HOSTNAME=$(hostname)

  echo -e "${WHT}════════════════════════════════════════════════════════════════${RST}"
  echo -e "${WHT}  DB MONITOR — $HOSTNAME — $TS${RST}"
  echo -e "${WHT}  Log: $LOG_FILE${RST}"
  echo -e "${WHT}════════════════════════════════════════════════════════════════${RST}"

  # ── Processlist (sem Sleep, sem event_scheduler) ──────────────────────
  echo -e "\n${CYA}── Queries em Execucao ─────────────────────────────────────────────${RST}"
  PROC=$(mysql 2>/dev/null -e "
    SELECT
      id,
      user,
      SUBSTRING_INDEX(host, ':', 1) AS host,
      IFNULL(db, '-') AS db,
      time AS secs,
      state,
      LEFT(IFNULL(info, '-'), 65) AS query
    FROM information_schema.processlist
    WHERE command != 'Sleep'
      AND user != 'event_scheduler'
      AND id != CONNECTION_ID()
    ORDER BY time DESC;
  ")

  if [ -z "$PROC" ]; then
    echo -e "  ${GRN}✓ Nenhuma query ativa no momento${RST}"
  else
    echo "$PROC" | sed 's/^/  /'
    while IFS=$'\t' read -r id user host db secs state query; do
      [ "$id" = "id" ] && continue
      [ -z "$id" ] && continue
      log "INFO" "QUERY: id=$id user=$user host=$host db=$db secs=$secs state=$state query=$(echo "$query" | cut -c1-80)"
    done <<< "$PROC"
  fi

  # ── Queries lentas agora (>2s, sem event_scheduler) ───────────────────
  echo -e "\n${CYA}── Queries Lentas Agora (>2s) ──────────────────────────────────────${RST}"
  SLOW_NOW=$(mysql 2>/dev/null -e "
    SELECT
      id,
      user,
      time AS secs,
      state,
      LEFT(IFNULL(info, '-'), 70) AS query
    FROM information_schema.processlist
    WHERE command != 'Sleep'
      AND user != 'event_scheduler'
      AND time > 2
      AND id != CONNECTION_ID()
    ORDER BY time DESC;
  ")

  if [ -z "$SLOW_NOW" ]; then
    echo -e "  ${GRN}✓ Nenhuma query acima de 2s${RST}"
  else
    echo -e "  ${RED}⚠ Queries lentas detectadas:${RST}"
    echo "$SLOW_NOW" | sed 's/^/  /'
    while IFS=$'\t' read -r id user secs state query; do
      [ "$id" = "id" ] && continue
      [ -z "$id" ] && continue
      log "WARN" "SLOW QUERY: id=$id user=$user secs=${secs}s state=$state query=$(echo "$query" | cut -c1-100)"
    done <<< "$SLOW_NOW"
  fi

  # ── InnoDB Locks ──────────────────────────────────────────────────────
  echo -e "\n${CYA}── InnoDB Locks Ativos ─────────────────────────────────────────────${RST}"
  LOCKS=$(mysql 2>/dev/null -e "
    SELECT
      r.trx_id            AS waiting_trx,
      r.trx_mysql_thread_id AS waiting_thread,
      LEFT(r.trx_query, 50) AS waiting_query,
      b.trx_id            AS blocking_trx,
      b.trx_mysql_thread_id AS blocking_thread,
      LEFT(b.trx_query, 50) AS blocking_query
    FROM information_schema.innodb_lock_waits w
    INNER JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
    INNER JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id;
  " 2>/dev/null)

  if [ -z "$LOCKS" ]; then
    echo -e "  ${GRN}✓ Sem locks ativos${RST}"
  else
    echo -e "  ${RED}⚠ Locks detectados:${RST}"
    echo "$LOCKS" | sed 's/^/  /'
    log "WARN" "INNODB LOCK WAIT detectado: $LOCKS"
  fi

  # ── Status Global ─────────────────────────────────────────────────────
  echo -e "\n${CYA}── Status Global MySQL ─────────────────────────────────────────────${RST}"
  STATUS=$(mysql 2>/dev/null -e "
    SHOW GLOBAL STATUS WHERE variable_name IN (
      'Threads_running',
      'Threads_connected',
      'Slow_queries',
      'Innodb_row_lock_waits',
      'Innodb_row_lock_time_avg',
      'Innodb_buffer_pool_read_requests',
      'Innodb_buffer_pool_reads',
      'Com_select',
      'Com_insert',
      'Com_update',
      'Com_delete',
      'Questions'
    );
  ")

  if [ -n "$STATUS" ]; then
    T_RUN=$(echo "$STATUS"  | grep "Threads_running"             | awk '{print $2}')
    T_CON=$(echo "$STATUS"  | grep "Threads_connected"           | awk '{print $2}')
    SLOW_Q=$(echo "$STATUS" | grep "Slow_queries"                | awk '{print $2}')
    LK_W=$(echo "$STATUS"   | grep "Innodb_row_lock_waits"       | awk '{print $2}')
    LK_T=$(echo "$STATUS"   | grep "Innodb_row_lock_time_avg"    | awk '{print $2}')
    BP_REQ=$(echo "$STATUS" | grep "Innodb_buffer_pool_read_requests" | awk '{print $2}')
    BP_RD=$(echo "$STATUS"  | grep "Innodb_buffer_pool_reads$"   | awk '{print $2}')
    SEL=$(echo "$STATUS"    | grep "Com_select"                  | awk '{print $2}')
    INS=$(echo "$STATUS"    | grep "Com_insert"                  | awk '{print $2}')
    UPD=$(echo "$STATUS"    | grep "Com_update"                  | awk '{print $2}')
    DEL=$(echo "$STATUS"    | grep "Com_delete"                  | awk '{print $2}')
    QST=$(echo "$STATUS"    | grep "Questions"                   | awk '{print $2}')

    if [ -n "$BP_REQ" ] && [ -n "$BP_RD" ] && [ "${BP_REQ:-0}" -gt 0 ] 2>/dev/null; then
      HIT=$(awk -v req="$BP_REQ" -v rd="$BP_RD" 'BEGIN {printf "%.2f", (1 - rd/req)*100}')
      awk -v h="$HIT" 'BEGIN {exit (h+0 < 95) ? 0 : 1}' && HIT_C="${RED}" || HIT_C="${GRN}"
      HIT_STR="${HIT_C}${HIT}%${RST}"
    else
      HIT_STR="${YEL}calculando...${RST}"
      HIT="0"
    fi

    [ "${T_RUN:-0}"  -gt 10 ] 2>/dev/null && TR_C="${RED}"  || TR_C="${GRN}"
    [ "${SLOW_Q:-0}" -gt 50000 ] 2>/dev/null && SQ_C="${RED}" || \
    { [ "${SLOW_Q:-0}" -gt 1000 ] 2>/dev/null && SQ_C="${YEL}" || SQ_C="${GRN}"; }
    [ "${LK_W:-0}"   -gt 0  ] 2>/dev/null && LK_C="${RED}"  || LK_C="${GRN}"

    echo -e "  Threads  : running=${TR_C}$T_RUN${RST}  connected=${WHT}$T_CON${RST}"
    echo -e "  Slow queries acumuladas : ${SQ_C}$SLOW_Q${RST}  |  Row lock waits: ${LK_C}$LK_W${RST}  |  Lock time avg: ${WHT}${LK_T}ms${RST}"
    echo -e "  Buffer pool hit rate    : $HIT_STR"
    echo -e "  DML      : SELECT=${WHT}$SEL${RST}  INSERT=${WHT}$INS${RST}  UPDATE=${WHT}$UPD${RST}  DELETE=${WHT}$DEL${RST}"
    echo -e "  Questions total         : ${WHT}$QST${RST}"

    log "INFO" "MySQL: threads_running=$T_RUN connected=$T_CON slow_queries=$SLOW_Q lock_waits=$LK_W bp_hit=${HIT}% questions=$QST"

    [ "${T_RUN:-0}"  -gt 10  ] && log "WARN" "MySQL threads_running elevado: $T_RUN"
    [ "${LK_W:-0}"   -gt 0   ] && log "WARN" "MySQL row_lock_waits: $LK_W"
    awk -v h="${HIT:-0}" 'BEGIN {exit (h+0 < 90) ? 0 : 1}' 2>/dev/null && \
      [ "${BP_REQ:-0}" -gt 0 ] && log "WARN" "MySQL buffer pool hit rate baixo: ${HIT}%"
  else
    echo -e "  ${RED}[!] Sem acesso ao MySQL — verifique ~/.my.cnf${RST}"
    log "ERROR" "Sem acesso ao MySQL"
  fi

  # ── Replicacao ────────────────────────────────────────────────────────
  echo -e "\n${CYA}── Replicacao (Master Status) ──────────────────────────────────────${RST}"
  REPL=$(mysql 2>/dev/null -e "SHOW MASTER STATUS\G" | grep -E "File|Position|Executed_Gtid")
  if [ -n "$REPL" ]; then
    echo "$REPL" | sed 's/^/  /'
    BINLOG_FILE=$(echo "$REPL" | grep File     | awk '{print $NF}')
    BINLOG_POS=$(echo "$REPL"  | grep Position | awk '{print $NF}')
    log "INFO" "Replicacao: binlog=$BINLOG_FILE position=$BINLOG_POS"
  else
    echo -e "  ${YEL}Sem dados de replicacao${RST}"
  fi

  # ── Rodape ────────────────────────────────────────────────────────────
  echo -e "\n${WHT}  Refresh: ${INTERVAL}s | Log: $LOG_FILE | Ctrl+C para sair${RST}"
  echo -e "${WHT}════════════════════════════════════════════════════════════════${RST}"
}

export -f monitor_db log
export LOG_FILE LOG_MAX_MB
export RED YEL GRN CYA WHT RST

echo "[$(date '+%d/%m/%Y %H:%M:%S')] [INFO] ===== monitor_db.sh iniciado =====" >> "$LOG_FILE"
watch -n $INTERVAL -c "bash -c monitor_db"
