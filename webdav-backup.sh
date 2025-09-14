#!/bin/bash
# ==============================================================================
#
#          WebDAV Segmented & Parallel Backup Manager
#
# Author: (Your Name or Pseudonym)
# Version: 1.0.0
# GitHub: (Your GitHub Repository URL)
#
# Description:
#   This script automates the process of backing up a large directory.
#   It creates compressed, segmented archives, uploads them in parallel
#   to a WebDAV server, and enforces a retention policy to manage old backups.
#   Ideal for services with single-file size limits (e.g., 123pan).
#
# ==============================================================================

set -o pipefail # Exit on pipe failures

# --- Configuration Section ---
# Please configure these variables according to your needs.

# 1. Directory to be backed up.
readonly SOURCE_DIR="/opt/mcsmanager/daemon/data/InstanceData/fcbc555412684dd6b2d80e4e61f22914"

# 2. Temporary directory for storing segmented files.
readonly TEMP_DIR="/opt/tmp/webdav_backup_temp"

# 3. Maximum size for each segmented archive file (e.g., "950M", "1G").
readonly SEGMENT_SIZE="950M"

# 4. Full URL of the target WebDAV directory. Must end with a '/'.
readonly WEBDAV_URL="https://webdav.123pan.cn/webdav/nb7/"

# 5. Number of recent backup sets to keep.
readonly RETENTION_COUNT=7

# 6. Files or directories to exclude from the backup, separated by spaces.
readonly EXCLUDES="--exclude='./cache' --exclude='./logs' --exclude='*.log'"

# 7. Number of parallel uploads. Adjust based on your server's CPU and bandwidth.
readonly MAX_PARALLEL_UPLOADS=4

# --- End of Configuration Section ---


# --- Script Core ---

# Global constant for the backup file naming convention.
readonly BACKUP_FILE_PATTERN_BASE="mcsmanager_backup_"

# Function to print log messages with a timestamp.
log() {
    echo "$(date +%Y-%m-%d\ %H:%M:%S) - $1"
}

# Function to handle script exit on error.
error_exit() {
    log "FATAL: $1"
    # Terminate any running background jobs before exiting.
    if [ "$(jobs -p)" ]; then
        log "Terminating active background jobs..."
        kill $(jobs -p) 2>/dev/null
    fi
    # The cleanup function is called automatically by the trap.
    exit 1
}

# Function to clean up the temporary directory.
cleanup() {
    log "Cleaning up temporary directory: $TEMP_DIR"
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Set a trap to ensure cleanup runs on script exit (normal or error).
trap cleanup EXIT

# Checks for required command-line tools.
check_dependencies() {
    log "Checking for required tools..."
    for cmd in tar split curl basename; do
        if ! command -v "$cmd" &> /dev/null; then
            error_exit "Required command '$cmd' is not installed."
        fi
    done
    log "All required tools are present."
}

# Validates the configuration variables.
validate_config() {
    log "Validating configuration..."
    if [ ! -d "$SOURCE_DIR" ]; then
        error_exit "Source directory '$SOURCE_DIR' does not exist."
    fi
    if [[ "${WEBDAV_URL: -1}" != "/" ]]; then
        error_exit "WEBDAV_URL must end with a forward slash ('/')."
    fi
    # Security: Check for credentials in environment variables.
    if [ -z "$WEBDAV_USER" ] || [ -z "$WEBDAV_PASS" ]; then
        error_exit "WEBDAV_USER and WEBDAV_PASS environment variables are not set. Please set them before running the script."
    fi
    log "Configuration validated."
}

# Function to perform the backup retention policy.
perform_retention() {
    log "Executing retention policy (keeping last $RETENTION_COUNT backups)..."
    local all_remote_files_raw
    all_remote_files_raw=$(curl -s -k -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H "Depth: 1" "$WEBDAV_URL")
    if [ -z "$all_remote_files_raw" ]; then log "Warning: Could not retrieve file list from WebDAV."; return; fi
    
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

    if [ ${#all_remote_filenames[@]} -eq 0 ]; then log "No existing backups found matching the pattern. Skipping cleanup."; return 0; fi
    
    declare -A backup_sets
    for file in "${all_remote_filenames[@]}"; do
        if [[ "$file" =~ ^(${BACKUP_FILE_PATTERN_BASE}[0-9]{14}) ]]; then backup_sets["${BASH_REMATCH[1]}"]=1; fi
    done
    
    local sorted_prefixes=(); for prefix in "${!backup_sets[@]}"; do sorted_prefixes+=("$prefix"); done
    IFS=$'\n' sorted_prefixes=($(sort <<<"${sorted_prefixes[*]}")); unset IFS
    
    local num_sets=${#sorted_prefixes[@]}
    log "Found $num_sets existing backup sets on WebDAV."
    
    if [ "$num_sets" -le "$RETENTION_COUNT" ]; then log "Number of backups does not exceed retention limit. No cleanup needed."; return 0; fi
    
    local sets_to_delete_count=$((num_sets - RETENTION_COUNT))
    log "Will delete the oldest $sets_to_delete_count backup set(s)."
    
    for ((i=0; i<sets_to_delete_count; i++)); do
        local prefix_to_delete="${sorted_prefixes[i]}"
        log "Deleting backup set: $prefix_to_delete"
        for file in "${all_remote_filenames[@]}"; do
            if [[ "$file" == "${prefix_to_delete}"* ]]; then
                log "  Deleting file: ${WEBDAV_URL}${file}"
                curl -s -k -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "${WEBDAV_URL}${file}"
            fi
        done
    done
    log "Retention policy execution finished."
}

# Main execution block of the script.
main() {
    log "=================================================="
    log "      WebDAV Backup Manager - Task Started"
    log "=================================================="

    check_dependencies
    validate_config

    # Create temporary directory.
    mkdir -p "$TEMP_DIR" || error_exit "Could not create temporary directory '$TEMP_DIR'."

    # Create timestamped backup name.
    local backup_prefix="${BACKUP_FILE_PATTERN_BASE}$(date +%Y%m%d%H%M%S)"
    local full_backup_name="${backup_prefix}.tar.gz"

    log "Starting compression and segmentation of '$SOURCE_DIR'..."
    tar -czf - ${EXCLUDES} -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")" | \
        split -b "$SEGMENT_SIZE" - "$TEMP_DIR/$full_backup_name.part_"
    
    if ! ls "$TEMP_DIR/$full_backup_name.part_"* &> /dev/null; then
        error_exit "No segmented files were created. Compression might have failed."
    fi
    log "Compression and segmentation completed successfully."

    local segment_files=("$TEMP_DIR/$full_backup_name.part_"*)
    log "Starting parallel upload of ${#segment_files[@]} file segments..."
    
    local failure_flag_file="${TEMP_DIR}/upload_failed"
    rm -f "$failure_flag_file"

    # Background upload task function.
    upload_task() {
        local file_to_upload="$1"
        local remote_name
        remote_name=$(basename "$file_to_upload")
        local curl_error
        curl_error=$(curl -k -s -S --show-error -u "$WEBDAV_USER:$WEBDAV_PASS" --upload-file "$file_to_upload" "${WEBDAV_URL}${remote_name}" 2>&1)
        if [ $? -ne 0 ]; then
            log "Upload FAILED ($remote_name): $curl_error"
            touch "$failure_flag_file"
        fi
    }

    # Parallel job management loop.
    for segment_file in "${segment_files[@]}"; do
        while [[ $(jobs -p | wc -l) -ge $MAX_PARALLEL_UPLOADS ]]; do
            sleep 1
        done
        upload_task "$segment_file" &
        local pid=$!
        log "Upload STARTED (PID: $pid): $(basename "$segment_file")"
    done

    log "All upload tasks dispatched. Waiting for completion..."
    wait

    if [ -f "$failure_flag_file" ]; then
        error_exit "One or more file uploads failed. Please check the logs above."
    else
        log "All file segments uploaded successfully."
        perform_retention
    fi

    log "=================================================="
    log "         WebDAV Backup Manager - Task Finished"
    log "=================================================="
}

# Run the main function.
main "$@"
