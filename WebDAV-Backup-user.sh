#!/bin/bash

# ==============================================================================
# 配置区域 - 请根据你的实际情况修改以下参数
#SOURCE_DIR="/opt/mcsmanager/daemon/data/" 备份目录
#TEMP_DIR="/opt/tmp/webdav_backup_temp" 压缩分开大小的临时目录，如果非正常终止需要手动清理
#SEGMENT_SIZE="950M" 压缩的分块大小
#WEBDAV_URL="https://webdav.cn/webdav/" webdav地址
#WEBDAV_USER="user"  webdab账号
#WEBDAV_PASS="passd" webdav密码
#RETENTION_COUNT=7 保留文件份数
#EXCLUDES="--exclude='./cache' --exclude='./logs' --exclude='*.log'" 排除文件
#MAX_PARALLEL_UPLOADS=2  并行上传数量
# ==============================================================================
SOURCE_DIR="/opt/mcsmanager/daemon/data/"
TEMP_DIR="/opt/tmp/webdav_backup_temp"
SEGMENT_SIZE="950M"
WEBDAV_URL="https://webdav.cn/webdav/"
WEBDAV_USER="user"
WEBDAV_PASS="passd"
RETENTION_COUNT=7
EXCLUDES="--exclude='./cache' --exclude='./logs' --exclude='*.log'"
MAX_PARALLEL_UPLOADS=2
# ==============================================================================
# 脚本核心逻辑 - 通常无需修改
# ==============================================================================

log() { echo "$(date +%Y-%m-%d\ %H:%M:%S) - $1"; }

error_exit() {
    log "错误: $1"
    if [ $(jobs -p | wc -l) -gt 0 ]; then log "检测到仍在运行的后台任务，正在终止..."; kill $(jobs -p) 2>/dev/null; fi
    cleanup
    exit 1
}

cleanup() {
    log "正在清理临时目录: $TEMP_DIR"
    if [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
}

trap cleanup EXIT

BACKUP_FILE_PATTERN_BASE="mcsmanager_backup_"

perform_retention() {
    log "开始执行备份保留策略 (保留最近 $RETENTION_COUNT 份备份)..."
    local all_remote_files_raw
    all_remote_files_raw=$(curl -s -k -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H "Depth: 1" "$WEBDAV_URL")
    if [ -z "$all_remote_files_raw" ]; then log "无法从 WebDAV 获取文件列表。"; return; fi
    
    # --- 【核心修正 & 调试】 ---
    log "--- DEBUG START: WebDAV 服务器原始返回 ---"
    log "$all_remote_files_raw"
    log "--- DEBUG END: WebDAV 服务器原始返回 ---"

    # 【已重写】采用更健壮的解析方式
    local all_hrefs
    all_hrefs=$(echo "$all_remote_files_raw" | grep -o '<D:href>[^<]*</D:href>' | sed 's/<D:href>//g; s/<\/D:href>//g')

    local all_remote_filenames=()
    while IFS= read -r href_path; do
        if [ -n "$href_path" ]; then
            local filename
            filename=$(basename "$href_path")
            if [[ "$filename" =~ ^${BACKUP_FILE_PATTERN_BASE}[0-9]{14}\.tar\.gz\.part_[a-z]{2,}$ ]]; then
                all_remote_filenames+=("$filename")
            fi
        fi
    done <<< "$all_hrefs"
    
    log "--- DEBUG START: 脚本解析出的备份文件列表 ---"
    # 将数组转换成一个长字符串打印，方便查看
    printf "  - %s\n" "${all_remote_filenames[@]}"
    log "--- DEBUG END: 脚本解析出的备份文件列表 ---"
    # ---------------------------

    if [ ${#all_remote_filenames[@]} -eq 0 ]; then log "WebDAV上未找到符合模式的备份文件。"; return 0; fi
    
    declare -A backup_sets
    for file in "${all_remote_filenames[@]}"; do
        if [[ "$file" =~ ^(${BACKUP_FILE_PATTERN_BASE}[0-9]{14}) ]]; then backup_sets["${BASH_REMATCH[1]}"]=1; fi
    done
    
    local sorted_prefixes=(); for prefix in "${!backup_sets[@]}"; do sorted_prefixes+=("$prefix"); done
    IFS=$'\n' sorted_prefixes=($(sort <<<"${sorted_prefixes[*]}")); unset IFS
    
    local num_sets=${#sorted_prefixes[@]}
    log "当前WebDAV上检测到 $num_sets 份独立备份。"
    
    if [ "$num_sets" -le "$RETENTION_COUNT" ]; then log "备份数量未超过限制，无需删除。"; return 0; fi
    
    local sets_to_delete_count=$((num_sets - RETENTION_COUNT))
    log "需要删除最旧的 $sets_to_delete_count 份备份。"
    
    for ((i=0; i<sets_to_delete_count; i++)); do
        local prefix_to_delete="${sorted_prefixes[i]}"
        log "正在删除备份集: $prefix_to_delete"
        for file in "${all_remote_filenames[@]}"; do
            if [[ "$file" == "${prefix_to_delete}"* ]]; then
                log "  删除文件: ${WEBDAV_URL}${file}"
                curl -s -k -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "${WEBDAV_URL}${file}"
            fi
        done
    done
    log "备份保留策略执行完毕。"
}

# --- 主流程 ---
log "=================================================="
log "WebDAV 分段备份任务开始 (最终修正版 v3 - 带调试)"
if [[ "${WEBDAV_URL: -1}" != "/" ]]; then WEBDAV_URL="${WEBDAV_URL}/"; fi
log "源目录: $SOURCE_DIR"; log "临时目录: $TEMP_DIR"; log "WebDAV URL: $WEBDAV_URL"; log "最大并行上传数: $MAX_PARALLEL_UPLOADS"
log "=================================================="

for cmd in tar split curl basename; do if ! command -v "$cmd" &> /dev/null; then error_exit "$cmd 命令未找到。"; fi; done
if [ ! -d "$SOURCE_DIR" ]; then error_exit "源目录 $SOURCE_DIR 不存在。"; fi
mkdir -p "$TEMP_DIR" || error_exit "无法创建临时目录 $TEMP_DIR。"

BACKUP_PREFIX="${BACKUP_FILE_PATTERN_BASE}$(date +%Y%m%d%H%M%S)"
FULL_BACKUP_NAME="${BACKUP_PREFIX}.tar.gz"

log "开始压缩和分段文件..."
tar -czf - $EXCLUDES -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")" | split -b "$SEGMENT_SIZE" - "$TEMP_DIR/$FULL_BACKUP_NAME.part_" || error_exit "压缩或分段失败。"
if ! ls "$TEMP_DIR/$FULL_BACKUP_NAME.part_"* 1> /dev/null 2>&1; then error_exit "压缩后未生成任何分段文件。"; fi
log "文件已成功分段到临时目录 $TEMP_DIR。"

SEGMENT_FILES=("$TEMP_DIR/$FULL_BACKUP_NAME.part_"*)
log "开始并行上传分段文件到 WebDAV..."
FAILURE_FLAG_FILE="${TEMP_DIR}/upload_failed"
rm -f "$FAILURE_FLAG_FILE"

upload_task() {
    local file_to_upload="$1"
    local remote_name=$(basename "$file_to_upload")
    local curl_error=$(curl -k -s -S --show-error -u "$WEBDAV_USER:$WEBDAV_PASS" --upload-file "$file_to_upload" "${WEBDAV_URL}${remote_name}" 2>&1)
    if [ $? -ne 0 ]; then log "上传失败 ($remote_name): $curl_error"; touch "$FAILURE_FLAG_FILE"; fi
}

for segment_file in "${SEGMENT_FILES[@]}"; do
    while [[ $(jobs -p | wc -l) -ge $MAX_PARALLEL_UPLOADS ]]; do sleep 1; done
    upload_task "$segment_file" &
    pid=$!
    log "开始上传 (PID: $pid): $(basename "$segment_file")"
done

log "所有上传任务已启动，等待剩余任务完成..."
wait

if [ -f "$FAILURE_FLAG_FILE" ]; then
    error_exit "部分或所有文件上传失败，请检查上面的日志。"
else
    log "所有分段文件已成功上传到 WebDAV。"
    perform_retention
fi

log "WebDAV 分段备份任务完成。"
log "=================================================="
