cat obs_retention_cleanup.sh 
#!/bin/bash

# OBS Retention Cleanup Script v2.1
# Поддерживает многоуровневую вложенность каталогов

set -euo pipefail

# Конфигурация
BUCKET="black-box"
RETENTION_DAYS=29
BASE_PATH="DB"
CUTOFF_DATE=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)
CURRENT_DATE=$(date +%Y-%m-%d)
LOG_FILE="/var/log/obs_cleanup.log"
DRY_RUN=false

# Цвета для логов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Функция логирования
log() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local message="$1"
    local color="${2:-}"
    
    if [[ -n "$color" ]]; then
        echo -e "${timestamp} ${color}${message}${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${timestamp} ${message}" | tee -a "$LOG_FILE"
    fi
}

# Функция проверки зависимостей
check_dependencies() {
    local deps=("obsutil" "date" "awk")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "❌ Ошибка: $dep не установлен" "$RED"
            exit 1
        fi
    done
    log "✅ Все зависимости доступны" "$GREEN"
}

# Функция проверки подключения к OBS
check_obs_connection() {
    log "🔄 Проверка подключения к OBS S3 (bucket: ${BUCKET})..." "$BLUE"
    if ! obsutil ls "obs://${BUCKET}" -limit=1 &> /dev/null; then
        log "❌ Ошибка подключения к OBS S3" "$RED"
        exit 1
    fi
    log "✅ Подключение к OBS S3 успешно установлено" "$GREEN"
}

# Рекурсивная функция поиска хостовых директорий
find_host_directories() {
    local base_path="$1"
    log "🔍 Поиск хостовых директорий в ${base_path}" "$BLUE"
    
    local listing
    if ! listing=$(obsutil ls "obs://${BUCKET}/${base_path}" -d 2>/dev/null); then
        return
    fi
    
    while IFS= read -r line; do
        if [[ "$line" == *"obs://${BUCKET}/${base_path}/"* && "$line" != *"obs://${BUCKET}/${base_path}/" ]]; then
            local dir_name="${line#*obs://${BUCKET}/${base_path}/}"
            dir_name="${dir_name%/}"
            
            # Пропускаем каталоги с датами на первом уровне
            if [[ ! "$dir_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                log "🏷️  Найдена хостовые директория: ${base_path}/${dir_name}" "$CYAN"
                find_date_directories "${base_path}/${dir_name}"
            fi
        fi
    done <<< "$listing"
}

# Рекурсивная функция поиска каталогов с датами
find_date_directories() {
    local current_path="$1"
    local dirs_to_process=()
    
    log "📅 Поиск каталогов с датами в ${current_path}" "$BLUE"
    
    # Получаем список подкаталогов в текущем пути
    local listing
    if ! listing=$(obsutil ls "obs://${BUCKET}/${current_path}" -d 2>/dev/null); then
        return
    fi
    
    # Парсим список каталогов
    while IFS= read -r line; do
        if [[ "$line" == *"obs://${BUCKET}/${current_path}/"* && "$line" != *"obs://${BUCKET}/${current_path}/" ]]; then
            local dir_name="${line#*obs://${BUCKET}/${current_path}/}"
            dir_name="${dir_name%/}"
            
            # Проверяем, является ли имя каталога датой (YYYY-MM-DD)
            if [[ "$dir_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                if [[ "$dir_name" < "$CUTOFF_DATE" ]]; then
                    log "🗑️ Найден старый каталог: ${current_path}/${dir_name} (дата: ${dir_name})" "$YELLOW"
                    confirm_and_delete_directory "${current_path}/${dir_name}"
                else
                    log "✅ Каталог актуален: ${current_path}/${dir_name} (дата: ${dir_name})" "$GREEN"
                fi
            else
                # Если это не дата, добавляем в список для дальнейшей обработки
                dirs_to_process+=("${current_path}/${dir_name}")
            fi
        fi
    done <<< "$listing"
    
    # Рекурсивно обрабатываем подкаталоги
    for subdir in "${dirs_to_process[@]}"; do
        find_date_directories "$subdir"
    done
}

# Функция подтверждения и удаления каталога
confirm_and_delete_directory() {
    local dir_path="$1"
    
    if [[ "$DRY_RUN" == true ]]; then
        log "🔒 DRY RUN: Пропущено удаление: ${dir_path}" "$YELLOW"
        return
    fi
    
    # Подтверждение удаления
    log "❓ Подтвердите удаление каталога: ${dir_path}" "$RED"
    log "💾 Размер: $(get_directory_size "${dir_path}")" "$YELLOW"
    read -p "🗑️  Удалить каталог? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "🗑️  Удаление: ${dir_path}" "$RED"
        
        if obsutil rm "obs://${BUCKET}/${dir_path}" -r -f &> /dev/null; then
            log "✅ Успешно удалено: ${dir_path}" "$GREEN"
        else
            log "❌ Ошибка при удалении: ${dir_path}" "$RED"
        fi
    else
        log "⏭️  Пропущено удаление: ${dir_path}" "$YELLOW"
    fi
}

# Функция получения размера каталога
get_directory_size() {
    local dir_path="$1"
    local size_info
    
    # Получаем информацию о размере каталога
    if size_info=$(obsutil du "obs://${BUCKET}/${dir_path}" -h 2>/dev/null | head -1); then
        echo "$size_info" | awk '{print $1}'
    else
        echo "неизвестно"
    fi
}

# Функция проверки аргументов командной строки
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN=true
                log "🔒 Режим dry-run активирован" "$YELLOW"
                shift
                ;;
            -b|--bucket)
                BUCKET="$2"
                shift 2
                ;;
            -p|--path)
                BASE_PATH="$2"
                shift 2
                ;;
            -r|--retention)
                RETENTION_DAYS="$2"
                CUTOFF_DATE=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  -d, --dry-run     Режим тестирования без удаления"
                echo "  -b, --bucket      Имя бакета (по умолчанию: black-box)"
                echo "  -p, --path        Базовый путь (по умолчанию: DB)"
                echo "  -r, --retention   Дни удержания (по умолчанию: 30)"
                echo "  -h, --help        Показать справку"
                exit 0
                ;;
            *)
                log "❌ Неизвестный аргумент: $1" "$RED"
                exit 1
                ;;
        esac
    done
}

# Основная функция
main() {
    parse_arguments "$@"
    
    log "=== НАЧАЛО ОЧИСТКИ СТАРЫХ БЭКАПОВ В OBS ==="
    log "🪣 Бакет: ${BUCKET}"
    log "📅 Удержание: ${RETENTION_DAYS} дней"
    log "📁 Базовый путь: ${BASE_PATH}"
    log "⏰ Текущая дата: ${CURRENT_DATE}"
    log "📅 Дата отсечения: ${CUTOFF_DATE}"
    
    check_dependencies
    check_obs_connection
    
    log "🔍 Рекурсивный поиск каталогов с датами в ${BASE_PATH}" "$BLUE"
    
    # Начинаем поиск с базового пути
    find_host_directories "$BASE_PATH"
    
    log "=== ЗАВЕРШЕНИЕ ОЧИСТКИ СТАРЫХ БЭКАПОВ В OBS ==="
}

# Запуск основной функции
main "$@"