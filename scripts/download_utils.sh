#!/usr/bin/env bash
#
#  Copyright (c) 2025 Sameer Al Sahab
#  Licensed under the MIT License. See LICENSE file for details.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#


FW_DIR="${ASTROROM}/firmware"
FW_BASE="${FW_DIR}/downloaded"


# Validate prerequisites for firmware download
_VALIDATE_DOWNLOAD_PREREQUISITES() {
    local errors=()
    
    # Check if Node.js is installed
    if ! command -v node >/dev/null 2>&1; then
        errors+=("Node.js is not installed or not in PATH")
    fi
    
    # Check if samfirm.js exists
    if [[ ! -f "$BIN/samfirm/samfirm.js" ]]; then
        errors+=("samfirm.js not found at $BIN/samfirm/samfirm.js")
    fi
    
    # Check if samfirm.js is readable
    if [[ -f "$BIN/samfirm/samfirm.js" ]] && [[ ! -r "$BIN/samfirm/samfirm.js" ]]; then
        errors+=("samfirm.js exists but is not readable")
    fi
    
    # Report all errors if any
    if [[ ${#errors[@]} -gt 0 ]]; then
        LOG_WARN "Prerequisites validation failed:"
        for err in "${errors[@]}"; do
            echo "  - $err"
        done
        return 1
    fi
    
    return 0
}

# Analyze samfirm error output and provide helpful suggestions
_ANALYZE_SAMFIRM_ERROR() {
    local error_log="$1"
    local suggestions=()
    
    if [[ ! -f "$error_log" ]]; then
        return
    fi
    
    local error_content
    error_content=$(cat "$error_log" 2>/dev/null)
    
    # Analyze common error patterns
    if echo "$error_content" | grep -qi "ENOTFOUND\|ECONNREFUSED\|ETIMEDOUT\|EAI_AGAIN"; then
        suggestions+=("Network connectivity issues - check your internet connection")
    fi
    
    if echo "$error_content" | grep -qi "getaddrinfo\|DNS"; then
        suggestions+=("DNS resolution failed - check your DNS settings")
    fi
    
    if echo "$error_content" | grep -qi "404\|not found"; then
        suggestions+=("Invalid model/region combination - verify MODEL and CSC values")
    fi
    
    if echo "$error_content" | grep -qi "503\|502\|500"; then
        suggestions+=("Samsung server temporarily unavailable - try again later")
    fi
    
    if echo "$error_content" | grep -qi "rate limit\|too many requests"; then
        suggestions+=("Rate limiting from Samsung servers - wait before retrying")
    fi
    
    if echo "$error_content" | grep -qi "Cannot read property\|TypeError\|undefined"; then
        suggestions+=("samfirm.js internal error - check if node_modules are installed")
    fi
    
    if echo "$error_content" | grep -qi "EACCES\|permission denied"; then
        suggestions+=("Permission denied - check file/directory permissions")
    fi
    
    # Display suggestions if any were found
    if [[ ${#suggestions[@]} -gt 0 ]]; then
        LOG_WARN "Possible causes:"
        for suggestion in "${suggestions[@]}"; do
            echo "  - $suggestion"
        done
    fi
}


DOWNLOAD_FW() {
    local target_fw="${1:-}"
    local tmp_dir="${FW_BASE}/tmp_download"


    _CHECK_NETWORK_CONNECTION && LOG_INFO "Internet connection [OK]" || LOG_WARN "Cannot connect to internet."

    [[ -z "$MODEL$EXTRA_MODEL$STOCK_MODEL" ]] && ERROR_EXIT "No firmware configs found."

    mkdir -p "$FW_BASE"
    declare -A processed_models

    for cfg in \
      "MAIN|$MODEL|$CSC|$IMEI" \
      "EXTRA|$EXTRA_MODEL|$EXTRA_CSC|${EXTRA_IMEI:-$IMEI}" \
      "STOCK|$STOCK_MODEL|$STOCK_CSC|$STOCK_IMEI"
    do
        IFS="|" read -r prefix mod reg imei <<< "$cfg"

        [[ -z "$mod" || -z "$reg" ]] && continue


        if [[ -n "$target_fw" && "${prefix,,}" != "${target_fw,,}" ]]; then
            continue
        fi

        [[ -v "processed_models[$mod]" ]] && continue
        processed_models["$mod"]=1

        FETCH_FW "$prefix" "$mod" "$reg" "$imei" "$FW_BASE" "$tmp_dir"
    done

    rm -rf "$tmp_dir"
}


FETCH_FW() {
    local prefix="$1" mod="$2" reg="$3" imei="$4" base="$5" tmp="$6"
    local target="${base}/${mod}_${reg}"
    local meta="${target}/firmware.info"
    local fw_out="${tmp}/${mod}_${reg}"
    LOG_INFO "Checking $prefix Firmware for $mod ($reg)..."


    local has_local_fw=false
    if [[ -d "$target" ]]; then

        if ls "$target"/AP_*.tar.md5 >/dev/null 2>&1; then
            local ap_file=$(ls "$target"/AP_*.tar.md5 2>/dev/null | head -1)
            if [[ -f "$ap_file" && $(stat -f%z "$ap_file" 2>/dev/null || stat -c%s "$ap_file" 2>/dev/null) -gt 1024 ]]; then
                has_local_fw=true


            fi
        fi
    fi

    # Fetch latest firmware version from server
    local xml ver_full ver_simple android_ver
    xml=$(curl -s -A "Dalvik/2.1.0" "https://fota-cloud-dn.ospserver.net/firmware/${reg}/${mod}/version.xml" 2>/dev/null)

    if echo "$xml" | grep -q '<latest'; then
        android_ver=$(echo "$xml" | grep -oP '<latest o="\K\d+' | head -1)
        ver_simple=$(echo "$xml" | grep -oP '<latest o="\d+">\K[^<]+' | head -1)
        ver_full="${android_ver}_${ver_simple}"
    fi


    if [[ -z "$ver_full" ]]; then
        if [[ "$has_local_fw" == true ]]; then
            LOG_INFO "Cannot connect to the internet. Using existing local firmware."
            return 0
        fi
        ERROR_EXIT "No internet connection and existing firmware found for $mod ($reg)"
    fi

    LOG_INFO "Latest version: $ver_simple (Android $android_ver)"


    local current=""
    [[ -f "$meta" ]] && current=$(<"$meta")

    if [[ "$current" == "$ver_full" && "$has_local_fw" == true ]]; then
        LOG_END "$prefix firmware is up to date/latest ($ver_simple)"
        return 0
    fi


    local prompt
    if [[ "$has_local_fw" == true ]]; then
        local local_ver="unknown"
        [[ -n "$current" ]] && local_ver=$(echo "$current" | cut -d'_' -f2-)
        prompt="Newer firmware available. Current: $local_ver. Download update?"
    else
        prompt="No existing firmware found for $prefix. Download $ver_simple?"
    fi

    CONFIRM_ACTION "$prompt" "true" || {
        [[ "$has_local_fw" == true ]] && return 0 || ERROR_EXIT "Cannot proceed further without firmware for $prefix"
    }

    mkdir -p "$target"
    
    # Validate prerequisites before attempting download
    LOG_INFO "Validating download prerequisites..."
    if ! _VALIDATE_DOWNLOAD_PREREQUISITES; then
        ERROR_EXIT "Prerequisites validation failed. Cannot proceed with firmware download."
    fi
    
LOG_INFO "Downloading firmware $ver_simple..."
LOG_INFO "Request details: Model=$mod, Region=$reg, IMEI=$imei"

# Retry configuration - use environment variables or defaults
MAX_RETRIES="${FIRMWARE_DOWNLOAD_MAX_RETRIES:-3}"
RETRY_DELAY="${FIRMWARE_DOWNLOAD_RETRY_DELAY:-30}"
RETRY_COUNT=0
DOWNLOAD_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    LOG_INFO "Firmware download attempt $((RETRY_COUNT + 1))/$MAX_RETRIES for $mod ($reg)..."
    
    # Clean up and prepare temporary directory
    rm -rf "$tmp" && mkdir -p "$tmp"
    
    # Create temporary log file for capturing samfirm output
    local samfirm_log
    samfirm_log=$(mktemp "/tmp/samfirm_${mod}_${reg}_XXXX.log")
    
    # Build and log the exact command
    local samfirm_cmd="$BIN/samfirm/samfirm.js -m $mod -r $reg -i $imei"
    LOG_INFO "Executing: $samfirm_cmd"
    
    # Execute samfirm with output capture
    local exit_code=0
    (
      cd "$tmp" 
      node "$BIN/samfirm/samfirm.js" -m "$mod" -r "$reg" -i "$imei" 2>&1 | tee "$samfirm_log"
    ) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        DOWNLOAD_SUCCESS=true
        LOG_INFO "Download successful on attempt $((RETRY_COUNT + 1))"
        # Clean up log file on success
        rm -f "$samfirm_log"
        break
    else
        LOG_WARN "samfirm.js failed with exit code $exit_code"
        
        # Display error output if available
        if [[ -f "$samfirm_log" && -s "$samfirm_log" ]]; then
            local log_size
            log_size=$(wc -l < "$samfirm_log" 2>/dev/null || echo "0")
            
            if [[ $log_size -gt 0 ]]; then
                LOG_WARN "samfirm.js output (last 30 lines):"
                echo "----------------------------------------"
                tail -n 30 "$samfirm_log" | sed 's/^/  /'
                echo "----------------------------------------"
                
                # Analyze errors and provide suggestions
                _ANALYZE_SAMFIRM_ERROR "$samfirm_log"
            else
                LOG_WARN "No output captured from samfirm.js"
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            # Exponential backoff: 30s, 60s, 120s (if using default RETRY_DELAY=30)
            WAIT_TIME=$((RETRY_DELAY * (2 ** (RETRY_COUNT - 1))))
            LOG_WARN "Retrying in ${WAIT_TIME}s... (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
            # Clean up failed download before retry
            rm -rf "$tmp"
            sleep $WAIT_TIME
        fi
        
        # Clean up log file before retry or final failure
        rm -f "$samfirm_log"
    fi
done

if [[ "$DOWNLOAD_SUCCESS" != true ]]; then
    LOG_WARN "All download attempts failed for $mod ($reg)"
    LOG_WARN "Command that was attempted: node $BIN/samfirm/samfirm.js -m $mod -r $reg -i $imei"
    ERROR_EXIT "Failed to download the firmware for $mod ($reg) after $MAX_RETRIES attempts. Check the error messages above for details."
fi

    local new_ap=$(ls "$fw_out"/AP_*.tar.md5 2>/dev/null | head -1)
    if [[ -z "$new_ap" ]]; then
        ERROR_EXIT "Download completed but AP file not found in $fw_out"
    fi
    
    # Log file information
    if [[ -f "$new_ap" ]]; then
        local file_size
        file_size=$(stat -f%z "$new_ap" 2>/dev/null || stat -c%s "$new_ap" 2>/dev/null)
        local file_size_mb=$((file_size / 1024 / 1024))
        LOG_INFO "Downloaded AP file: $(basename "$new_ap") (${file_size_mb}MB)"
        
        # Calculate and log MD5 checksum if md5sum is available
        if command -v md5sum >/dev/null 2>&1; then
            local md5hash
            md5hash=$(md5sum "$new_ap" | awk '{print $1}')
            LOG_INFO "MD5 checksum: $md5hash"
        fi
    fi

    if ! _VALIDATE_AP_FILE "$new_ap"; then
        ERROR_EXIT "Downloaded AP file is corrupted or invalid"
    fi

    rm -rf "$target" && mkdir -p "$target"
 
    mv "$fw_out"/* "$target"/ 2>/dev/null
        echo "$ver_full" > "$meta"


        local fs_var="${prefix}_WORKDIR"
        local fs_path="${!fs_var}"
        if [[ -n "$fs_path" && -d "$fs_path" ]]; then
            LOG_INFO "Cleaning previous filesystem directory: $fs_path"
            rm -rf "$fs_path" "$WORKSPACE"
        fi

        LOG_END "Successfully downloaded $prefix firmware ($ver_simple)"
}


_CHECK_NETWORK_CONNECTION() {
    curl -s \
        --connect-timeout 0.5 \
        --max-time 1 \
        https://clients3.google.com/generate_204 \
        >/dev/null
}

_VALIDATE_AP_FILE() {
    local ap_file="$1"

    [[ ! -f "$ap_file" ]] && return 1


    if ! tar -tf "$ap_file" >/dev/null 2>&1; then
        LOG_WARN "File is not a valid tar archive $ap_file"
        return 1
    fi


    local lz4_files
    lz4_files=$(tar -tf "$ap_file" | grep '\.lz4$' 2>/dev/null)

    if [[ -z "$lz4_files" ]]; then
        LOG "No .lz4 payloads found in $ap_file to validate."
        return 1
    fi


    while read -r img; do

        if ! tar -xf "$ap_file" "$img" -O 2>/dev/null | lz4 -t >/dev/null 2>&1; then
            LOG_WARN "Corrupted LZ4 payload found: $img in $ap_file"
            return 1
        fi
    done < <(tar -tf "$ap_file" | grep '\.lz4$')

    return 0
}


#
# Usage:
#DLOAD out <link>
#DLOAD out <link> <file_to_rename>
#DLOAD out <link> -unzip
#DLOAD <partition> <rel_path> <link>
#DLOAD <partition> <rel_path> <link> <file_to_rename>
#DLOAD <partition> <rel_path> <link> -unzip
#

DLOAD() {
    local target="$1" path url opt1 opt2 final_path tmpfile

    if [[ "$target" == "out" ]]; then
        path="$OUTDIR"
        url="$2"
        opt1="$3"
        shift 2
    else
        local base; base=$(GET_PARTITION_PATH "$target" 2>/dev/null)
        [[ -z "$base" ]] && { echo "[-] Target $target failed"; return 1; }
        path="${base}/$2"
        url="$3"
        opt1="$4"
        opt2="$5"
        shift 3
    fi

    mkdir -p "$path"
    tmpfile=$(mktemp "${path}/dl.XXXX")


    LOG "Downloading: $(basename "$url")"

    if ! curl -LSs -o "$tmpfile" "$url"; then
        ERROR_EXIT "Failed to fetch from $url"
        rm -f "$tmpfile"
        return 1
    fi


    if [[ "$opt1" == "-unzip" || "$opt2" == "-unzip" ]]; then
        unzip -qo "$tmpfile" -d "$path" && rm -f "$tmpfile"
    else
        local name; [[ -n "$opt1" && "$opt1" != "-unzip" ]] && name="$opt1" || name=$(basename "$url" | cut -d'?' -f1)
        mv "$tmpfile" "${path}/${name}"
    fi

}
