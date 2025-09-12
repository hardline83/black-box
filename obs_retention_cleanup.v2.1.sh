#!/bin/bash
set -euo pipefail

# OBS Retention Cleanup Script v2.1

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
RETENTION_DAYS=29
OBS_BASE_PATH="DB"
DRY_RUN=false  # По умолчанию РЕАЛЬНОЕ удаление

# ==================== ФУНКЦИИ ====================
log() {
    local message="$*"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" >&2
}

print_separator() {
    echo "============================================================" >&2
}

check_deps() {
    local missing=()
    for cmd in obsutil date; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"

    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        exit 1
    fi
}

check_s3_connection() {
    log "🔄 Проверка подключения к OBS S3 (bucket: ${OBS_BUCKET})..."
    
    if obsutil ls "obs://${OBS_BUCKET}" -config="$OBS_CONFIG_FILE" >/dev/null 2>&1; then
        log "✅ Подключение к OBS S3 успешно установлено"
        return 0
    else
        log "❌ Ошибка подключения к OBS S3"
        exit 1
    fi
}

is_valid_date() {
    local date_str="$1"
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        date -d "$date_str" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Рекурсивная функция поиска хостовых директорий
find_host_directories() {
    local base_path="$1"
    log "🔍 Поиск хостовых директорий в ${base_path}"
    
    local listing
    if ! listing=$(obsutil ls "obs://${OBS_BUCKET}/${base_path}" -d -config="$OBS_CONFIG_FILE" 2>/dev/null); then
        return
    fi
    
    while IFS= read -r line; do
        if [[ "$line" == *"obs://${OBS_BUCKET}/${base_path}/"* && "$line" != *"obs://${OBS_BUCKET}/${base_path}/" ]]; then
            local dir_name="${line#*obs://${OBS_BUCKET}/${base_path}/}"
            dir_name="${dir_name%/}"
            
            # Пропускаем каталоги с датами на первом уровне
            if [[ ! "$dir_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                log "🏷️ Найдена хостовые директория: ${base_path}/${dir_name}"
                echo "${base_path}/${dir_name}"
            fi
        fi
    done <<< "$listing"
}

# Рекурсивная функция поиска каталогов с датами
find_date_directories() {
    local current_path="$1"
    local cutoff_date="$2"
    local dirs_to_process=()
    
    log "📅 Поиск каталогов с датами в ${current_path}"
    
    # Получаем список подкаталогов в текущем пути
    local listing
    if ! listing=$(obsutil ls "obs://${OBS_BUCKET}/${current_path}" -d -config="$OBS_CONFIG_FILE" 2>/dev/null); then
        return
    fi
    
    # Парсим список каталогов
    while IFS= read -r line; do
        if [[ "$line" == *"obs://${OBS_BUCKET}/${current_path}/"* && "$line" != *"obs://${OBS_BUCKET}/${current_path}/" ]]; then
            local dir_name="${line#*obs://${OBS_BUCKET}/${current_path}/}"
            dir_name="${dir_name%/}"
            
            # Проверяем, является ли имя каталога датой (YYYY-MM-DD)
            if [[ "$dir_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                if [[ "$dir_name" < "$cutoff_date" ]]; then
                    log "🗑️ Найден старый каталог: ${current_path}/${dir_name} (дата: ${dir_name})"
                    echo "${current_path}/${dir_name} ${dir_name}"
                else
                    log "✅ Сохраняем актуальный каталог: ${current_path}/${dir_name} (дата: ${dir_name})"
                fi
            else
                # Если это не дата, добавляем в список для дальнейшей обработки
                dirs_to_process+=("${current_path}/${dir_name}")
            fi
        fi
    done <<< "$listing"
    
    # Рекурсивно обрабатываем подкаталоги
    for subdir in "${dirs_to_process[@]}"; do
        find_date_directories "$subdir" "$cutoff_date"
    done
}

find_date_folders() {
    local base_path="$1"
    local cutoff_date=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)
    
    log "🔍 Рекурсивный поиск каталогов с датами в ${base_path}"
    
    # Находим все хостовые директории
    while IFS= read -r host_path; do
        if [ -n "$host_path" ]; then
            # Для каждой хостовой директории рекурсивно ищем каталоги с датами
            find_date_directories "$host_path" "$cutoff_date"
        fi
    done < <(find_host_directories "$base_path")
}

get_folder_size() {
    local folder_path="$1"
    local total_size_bytes=0
    
    # Получаем информацию о каталоге
    local output=$(obsutil ls "obs://${OBS_BUCKET}/${folder_path}/" -config="$OBS_CONFIG_FILE" 2>/dev/null)
    
    # Ищем строку с общим размером
    if [[ "$output" =~ Total\ size\ of\ prefix\ .*\ is:\ ([0-9.]+)([KMGT]?B) ]]; then
        local size_value="${BASH_REMATCH[1]}"
        local size_unit="${BASH_REMATCH[2]}"
        
        # Конвертируем в байты
        case "$size_unit" in
            "B")   total_size_bytes=$(echo "$size_value" | awk '{printf "%.0f", $1}') ;;
            "KB")  total_size_bytes=$(echo "$size_value * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            "MB")  total_size_bytes=$(echo "$size_value * 1024 * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            "GB")  total_size_bytes=$(echo "$size_value * 1024 * 1024 * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            "TB")  total_size_bytes=$(echo "$size_value * 1024 * 1024 * 1024 * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            *)     total_size_bytes=0 ;;
        esac
    fi
    
    echo "$total_size_bytes"
}

show_deletion_summary() {
    local folders=("$@")
    local total_count=${#folders[@]}
    local total_size=0
    
    if [ $total_count -eq 0 ]; then
        log "✅ Нет старых каталогов для удаления"
        return 1
    fi
    
    echo ""
    echo "📋 НАЙДЕНО КАТАЛОГОВ ДЛЯ УДАЛЕНИЯ: ${total_count}" >&2
    echo "=============================================================================" >&2
    echo "№   | Полный путь каталога                               | Размер" >&2
    echo "=============================================================================" >&2
    
    # Выводим список и считаем общий размер
    for i in "${!folders[@]}"; do
        local folder="${folders[$i]}"
        local folder_size=$(get_folder_size "$folder")
        total_size=$((total_size + folder_size))
        
        # Форматируем размер без запятых (заменяем их на точку для выравнивания)
        local formatted_size=$(numfmt --to=iec "$folder_size" | sed 's/,/./g')
        
        printf "%-3d | %-50s | %10s\n" \
            "$((i+1))" \
            "$folder" \
            "$formatted_size" >&2
    done
    
    echo "=============================================================================" >&2
    # Форматируем общий размер тоже без запятых
    local formatted_total_size=$(numfmt --to=iec "$total_size" | sed 's/,/./g')
    echo "📊 ОБЩИЙ РАЗМЕР: $formatted_total_size" >&2
    echo "📅 Будет удалено: ${total_count} каталогов старше ${RETENTION_DAYS} дней" >&2
    
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log "🔒 DRY-RUN: Удаление не будет выполнено (только предварительный просмотр)"
        return 1
    fi
    
    return 0
}

confirm_deletion() {
    local folders=("$@")
    
    if [ ${#folders[@]} -eq 0 ]; then
        return 1
    fi
    
    echo "" >&2
    
    # Запрос подтверждения только для dry-run режима
    if [[ "$DRY_RUN" == true ]]; then
        return 1
    fi
    
    # В реальном режиме просто показываем информацию и продолжаем
    log "🚀 Начинаю удаление каталогов..."
    return 0
}

delete_folders() {
    local folders=("$@")
    local deleted_count=0
    local total_freed=0
    
    log "\n🗑️ Начало удаления каталогов..."
    
    for folder in "${folders[@]}"; do
        local folder_size=$(get_folder_size "$folder")
        log "🔨 Удаление: ${folder} ($(numfmt --to=iec "$folder_size"))"
        
        if obsutil rm "obs://${OBS_BUCKET}/${folder}/" -config="$OBS_CONFIG_FILE" -f -r >/dev/null 2>&1; then
            ((deleted_count++))
            total_freed=$((total_freed + folder_size))
            log "✅ Удалено: ${folder}"
        else
            log "⚠️ Не удалось удалить: ${folder}"
        fi
    done
    
    echo "$deleted_count $total_freed"
}

clean_empty_directories() {
    if [[ "$DRY_RUN" == true ]]; then
        log "🔒 DRY-RUN: Пропущена очистка пустых директорий"
        return
    fi
    
    log "🧽 Очистка пустых директорий..."
    
    # Сначала очищаем хостовые директории
    while IFS= read -r host_path; do
        if [ -n "$host_path" ]; then
            # Проверяем, есть ли подкаталоги в хостовой директории
            local has_subdirs=$(obsutil ls "obs://${OBS_BUCKET}/${host_path}/" -d -config="$OBS_CONFIG_FILE" 2>/dev/null | \
                               grep -c "obs://${OBS_BUCKET}/${host_path}/")
            
            if [ "$has_subdirs" -eq 0 ]; then
                log "🗑️ Удаление пустой хостовой директории: ${host_path}"
                obsutil rm "obs://${OBS_BUCKET}/${host_path}/" -config="$OBS_CONFIG_FILE" -f -folder >/dev/null 2>&1 || true
            fi
        fi
    done < <(find_host_directories "$OBS_BASE_PATH")
}

show_help() {
    echo "Использование: $0 [OPTIONS]"
    echo "Options:"
    echo "  -b, --bucket      Имя бакета (по умолчанию: black-box)"
    echo "  -d, --path        Базовый путь (по умолчанию: DB)"
    echo "  -r, --retention   Дни удержания (по умолчанию: 29)"
    echo "  -c, --config      Путь к конфигурационному файлу obsutil"
    echo "  -n, --dry-run     Только предварительный просмотр, без удаления"
    echo "  -h, --help        Показать справку"
    echo ""
    echo "Примеры:"
    echo "  $0                # Реальное удаление (по умолчанию)"
    echo "  $0 -n             # Dry-run режим (только предварительный просмотр)"
    echo "  $0 -r 60          # Удалить каталоги старше 60 дней"
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО ОЧИСТКИ СТАРЫХ БЭКАПОВ В OBS ==="
    log "🪣 Бакет: $OBS_BUCKET"
    log "📅 Удержание: $RETENTION_DAYS дней"
    log "📁 Базовый путь: $OBS_BASE_PATH"
    
    if [[ "$DRY_RUN" == true ]]; then
        log "🔒 РЕЖИМ: DRY-RUN (только предварительный просмотр)"
    else
        log "🚀 РЕЖИМ: РЕАЛЬНОЕ УДАЛЕНИЕ"
    fi
    
    log "⏰ Текущая дата: $(date '+%Y-%m-%d')"
    log "📅 Дата отсечения: $(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d')"
    
    check_deps
    check_s3_connection
    
    # Находим все каталоги с датами
    local folders_to_delete=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            read -r path date_str <<< "$line"
            folders_to_delete+=("$path")
        fi
    done < <(find_date_folders "$OBS_BASE_PATH")
    
    # Показываем сводку и проверяем, есть ли что удалять
    if ! show_deletion_summary "${folders_to_delete[@]}"; then
        if [ ${#folders_to_delete[@]} -eq 0 ]; then
            log "ℹ️ Очистка не выполнена (нет каталогов для удаления)"
        fi
        return 0
    fi
    
    # Для реального удаления сразу продолжаем, для dry-run выходим
    if confirm_deletion "${folders_to_delete[@]}"; then
        # Удаляем каталоги
        result=$(delete_folders "${folders_to_delete[@]}")
        read -r deleted_count total_freed <<< "$result"
        
        # Очищаем пустые директории
        clean_empty_directories
        
        log "\n=== ИТОГИ ОЧИСТКИ ==="
        log "🗑️ Удалено каталогов: ${deleted_count}"
        log "💾 Освобождено места: $(numfmt --to=iec "$total_freed")"
        log "✅ Очистка завершена успешно"
    else
        if [[ "$DRY_RUN" == true ]] && [ ${#folders_to_delete[@]} -gt 0 ]; then
            log "\n=== РЕЗУЛЬТАТЫ DRY-RUN ==="
            log "📋 Найдено каталогов для удаления: ${#folders_to_delete[@]}"
            
            # Вычисляем общий размер
            total_size=0
            for folder in "${folders_to_delete[@]}"; do
                folder_size=$(get_folder_size "$folder")
                total_size=$((total_size + folder_size))
            done
            
            log "💾 Общий размер: $(numfmt --to=iec "$total_size")"
            log "🔒 Для реального удаления запустите без опции -n или --dry-run"
        fi
    fi
}

# Обработка аргументов командной строки
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--bucket)
            OBS_BUCKET="$2"
            shift 2
            ;;
        -d|--path)
            OBS_BASE_PATH="$2"
            shift 2
            ;;
        -r|--retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -c|--config)
            OBS_CONFIG_FILE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Запуск основного процесса
if ! main; then
    log "❌ Ошибка при выполнении очистки!"
    exit 1
fi

exit 0