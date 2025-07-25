#!/bin/bash
set -euo pipefail
total_time_start=$(date +%s.%N)

# ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ:
# Обязательный аргумент:
# -c <путь>  Полный путь к config.sh
#
# Флаги для пропуска этапов:
# -s  Пропустить создание дампа БД
# -r  Пропустить очистку старых бэкапов
# -t  Проверить подключение к БД и выйти (dry-run)

# ==================== ПАРСИНГ АРГУМЕНТОВ ====================
SKIP_DUMP=false
SKIP_CLEAN=false
DRY_RUN=false
CONFIG_FILE=""

while getopts ":c:srt" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG" ;;
        s) SKIP_DUMP=true ;;
        r) SKIP_CLEAN=true ;;
        t) DRY_RUN=true ;;
        \?) echo "Использование: $0 -c <путь к config.sh> [-s] [-r] [-t]" >&2; exit 1 ;;
    esac
done

# Проверка обязательного аргумента
[ -z "$CONFIG_FILE" ] && { echo "❌ Ошибка: Не указан путь к config.sh" >&2; exit 1; }
[ ! -f "$CONFIG_FILE" ] && { echo "❌ Ошибка: Файл config.sh не найден: $CONFIG_FILE" >&2; exit 1; }

# ==================== ИНИЦИАЛИЗАЦИЯ ====================
SCRIPT_DIR=$(dirname "$(readlink -f "$CONFIG_FILE")")
source "$CONFIG_FILE"

# Глобальные настройки
HOSTNAME=$(hostname)
BACKUP_DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${DB_HOST}_${TIMESTAMP}"

# Настройки логирования
LOG_DIR="/var/log/backups/${DATABASE}/$(date +%Y-%m)"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${BACKUP_NAME}.log"
JSON_LOG="${LOG_DIR}/${BACKUP_NAME}_events.json"
METRICS_LOG="${LOG_DIR}/${BACKUP_NAME}_metrics.json"

# Пути для файлов
TMP_DIR="${SCRIPT_DIR}/tmp"
DUMP_DIR="${SCRIPT_DIR}/dump"
ARCHIVE_DIR="${SCRIPT_DIR}/dump_archive"
SOURCE_DUMP="${DUMP_DIR}/${DATABASE}.bac"
SOURCE="${ARCHIVE_DIR}/${DATABASE}-${BACKUP_DATE}.bac"
ARCHIVE_FILE="${TMP_DIR}/${BACKUP_NAME}.tar.gz"
ENCRYPTED_FILE="${TMP_DIR}/${BACKUP_NAME}.enc"

# Telegram Notifications
TG_BOT_TOKEN="7627195198:AAGD3W0IFbk4Ebn23Zfnd1BkgfTYHy_as5s"
TG_CHAT_ID="-1002682982923"
TG_API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

# ==================== ФУНКЦИИ ====================

# Форматирование длительности с фиксом для дробных чисел
format_duration() {
    local seconds=$1
    LC_NUMERIC="en_US.UTF-8" printf "%.2f" "$seconds" | sed 's/,/./'
}

# Подготовка корректного JSON из ассоциативного массива
prepare_metrics_json() {
    local -n metrics_ref=$1
    echo "{"
    local first=true
    for key in "${!metrics_ref[@]}"; do
        if ! $first; then
            echo ","
        fi
        printf '"%s": ' "$key"
        
        # Автоматическое определение типа значения
        if [[ ${metrics_ref[$key]} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            printf "%s" "${metrics_ref[$key]}"
        elif [[ ${metrics_ref[$key]} == "true" || ${metrics_ref[$key]} == "false" ]]; then
            printf "%s" "${metrics_ref[$key]}"
        else
            printf '"%s"' "${metrics_ref[$key]}"
        fi
        first=false
    done
    echo -e "\n}"
}

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    
    # Текстовый лог
    echo -e "[${timestamp}] ${level^^} ${message}" | tee -a "$LOG_FILE"
    
    # JSON лог для важных событий
    if [[ "$level" == "error" || "$level" == "warning" || "$level" == "info" ]]; then
        jq -n \
            --arg ts "$timestamp" \
            --arg lvl "${level^^}" \
            --arg msg "$message" \
            --arg host "$DB_HOST" \
            --arg db "$DATABASE" \
            '{
                timestamp: $ts,
                level: $lvl,
                db_host: $host,
                db_name: $db,
                message: $msg
            }' >> "$JSON_LOG"
    fi
}

save_metrics() {
    METRICS[end_time]=$(date +%s.%N)
    METRICS[duration]=$(echo "${METRICS[end_time]} - ${METRICS[start_time]}" | bc)
    METRICS[status]="${1:-SUCCESS}"
    
    log "info" "Сохранение метрик выполнения"
    prepare_metrics_json METRICS > "$METRICS_LOG"
    
    # Валидация JSON
    if ! jq -e . "$METRICS_LOG" >/dev/null 2>&1; then
        log "error" "Ошибка формирования JSON метрик"
        mv "$METRICS_LOG" "${METRICS_LOG}.invalid"
        jq -n --arg error "invalid_metrics" '{error: $error}' > "$METRICS_LOG"
    fi
}

send_telegram() {
    local message="$1"
    curl -s -X POST "$TG_API_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" >/dev/null
}

check_dependencies() {
    local required=("tar" "pigz" "openssl" "obsutil" "split" "pg_dump" "psql" "jq")
    local missing=()
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "error" "Отсутствуют зависимости: ${missing[*]}"
        send_telegram "*🚫 Ошибка: Отсутствуют зависимости*: ${missing[*]}"
        exit 1
    fi
    log "info" "Все зависимости доступны"
}

prepare_environment() {
    mkdir -p "$DUMP_DIR" "$ARCHIVE_DIR" "$TMP_DIR"
    log "info" "Инициализированы рабочие директории"
    
    if [ -d "$TMP_DIR" ]; then
        rm -rf "${TMP_DIR:?}/"*
        log "info" "Очищена временная директория: $TMP_DIR"
    fi
}

check_db_connection() {
    local start=$(date +%s.%N)
    log "info" "Проверка подключения к БД ${DATABASE} на ${DB_HOST}"
    
    export PGPASSWORD
    if psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DATABASE" -c "SELECT 1;" >/dev/null 2>>"${LOG_DIR}/db_connection.log"; then
        local duration=$(echo "$(date +%s.%N) - $start" | bc)
        log "info" "Подключение успешно установлено за $(format_duration $duration) сек"
        METRICS[db_connection]="success"
        METRICS[db_connection_duration]=$duration
    else
        log "error" "Ошибка подключения к БД"
        METRICS[db_connection]="failed"
        send_telegram "*🚫 Ошибка подключения к БД*"
        save_metrics "FAILED"
        exit 1
    fi
    unset PGPASSWORD
}

create_db_dump() {
    local start=$(date +%s.%N)
    log "info" "Создание дампа БД ${DATABASE}"
    
    export PGPASSWORD
    if pg_dump -U "$DB_USER" "$DATABASE" -h "$DB_HOST" -p "$DB_PORT" > "$SOURCE_DUMP" 2>>"${LOG_DIR}/pg_dump_error.log"; then
        local duration=$(echo "$(date +%s.%N) - $start" | bc)
        local size=$(du -h "$SOURCE_DUMP" | cut -f1)
        log "info" "Дамп успешно создан за $(format_duration $duration) сек, размер: $size"
        METRICS[dump_size]="$size"
        METRICS[dump_duration]=$duration
    else
        log "error" "Ошибка при создании дампа"
        send_telegram "*🚫 Ошибка создания дампа БД*"
        save_metrics "FAILED"
        exit 1
    fi
    unset PGPASSWORD
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    # Инициализация метрик
    declare -A METRICS=(
        [start_time]=$(date +%s.%N)
        [db_host]="$DB_HOST"
        [db_name]="$DATABASE"
        [backup_server]="$HOSTNAME"
        [config_file]="$CONFIG_FILE"
        [status]="RUNNING"
        [skip_dump]="$SKIP_DUMP"
        [skip_clean]="$SKIP_CLEAN"
        [dry_run]="$DRY_RUN"
    )

    trap 'log "error" "Скрипт прерван"; save_metrics "FAILED"; exit 1' INT TERM
    
    log "info" "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log "info" "Хост БД: $DB_HOST"
    log "info" "База данных: $DATABASE"
    log "info" "Сервер резервного копирования: $HOSTNAME"
    
    # Проверка окружения
    check_dependencies
    prepare_environment
    
    # Проверка подключения
    if ! $SKIP_DUMP || $DRY_RUN; then
        check_db_connection
        if $DRY_RUN; then
            log "info" "Dry-run завершен успешно"
            save_metrics "DRY_RUN"
            send_telegram "✅ *Dry-run проверка завершена*
*Хост БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Статус:* Подключение успешно"
            exit 0
        fi
    fi
    
    # Создание дампа
    if ! $SKIP_DUMP; then
        create_db_dump
    else
        log "info" "Пропуск создания дампа (по запросу пользователя)"
        METRICS[skip_dump]="true"
    fi
    
    # [Остальные этапы резервного копирования...]
    
    save_metrics "SUCCESS"
    log "info" "=== РЕЗЕРВНОЕ КОПИРОВАНИЕ УСПЕШНО ЗАВЕРШЕНО ==="
    
    send_telegram "✅ *Резервное копирование завершено*
*Хост БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Статус:* Успешно
*Длительность:* $(format_duration ${METRICS[duration]}) сек"
}

# Запуск
main "$@"