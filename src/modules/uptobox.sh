#!/bin/bash
#
# uptobox.com module
# Copyright (c) 2012-2013 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_UPTOBOX_REGEXP_URL='https\?://\(www\.\)\?uptobox\.com/'

MODULE_UPTOBOX_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_UPTOBOX_DOWNLOAD_RESUME=yes
MODULE_UPTOBOX_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPTOBOX_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPTOBOX_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_UPTOBOX_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPTOBOX_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
uptobox_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME ERR

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL") || return

    # Set-Cookie: login xfss
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    # Try to parse error
    ERR=$(parse_tag_quiet 'class="err"' 'font' <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] || ERR=$(parse_tag_quiet "class='err'" 'div' <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] && log_error "Unexpected remote error: $ERR"

    return $ERR_LOGIN_FAILED
}

# Output a uptobox file download URL
# $1: cookie file (account only)
# $2: uptobox url
# stdout: real file download link
uptobox_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://uptobox.com'
    local PAGE WAIT_TIME CODE PREMIUM FILE_URL
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD FORM_DD

    if [ -n "$AUTH" ]; then
        uptobox_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

        # Distinguish acount type (free or premium)
        PAGE=$(curl -b "$COOKIE_FILE" 'http://www.uptobox.com/?op=my_account') || return

        # Opposite is: 'Upgrade to premium';
        if match 'Renew premium' "$PAGE"; then
            local DIRECT_URL
            PREMIUM=1
            DIRECT_URL=$(curl -I -b "$COOKIE_FILE" "$URL" | grep_http_header_location_quiet)
            if [ -n "$DIRECT_URL" ]; then
                echo "$DIRECT_URL"
                return 0
            fi

            PAGE=$(curl -i -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return
        else
            # Should wait 45s instead of 60s!
            PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return
        fi
    else
        PAGE=$(curl -b 'lang=english' "$URL") || return
    fi

    # The file you were looking for could not be found, sorry for any inconvenience
    if matchi 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Send (post) form
    FORM_HTML=$(grep_form_by_order "$PAGE") || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_METHOD=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")

    # Handle premium downloads
    if [ "$PREMIUM" = '1' ]; then
        FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return

        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
            -d "op=$FORM_OP" \
            -d "id=$FORM_ID" \
            -d "rand=$FORM_RAND" \
            -d 'method_free=' \
            -d 'down_direct=1' \
            -d 'referer=' \
            -d "method_premium=$FORM_METHOD" "$URL") || return

        # Click here to start your download
        FILE_URL=$(parse_attr '/d/' 'href' <<< "$FORM_HTML")
        if match_remote_url "$FILE_URL"; then
            echo "$FILE_URL"
            return 0
        fi
    fi

    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_FNAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -F "op=$FORM_OP" \
        -F "usr_login=$FORM_USR" \
        -F "id=$FORM_ID" \
        -F "fname=$FORM_FNAME" \
        -F 'referer=' \
        -F "method_free=$FORM_METHOD" "$URL") || return

    # Check for enforced download limits
    if match '<p class="err">' "$PAGE"; then
        # You have reached the download-limit: 1024 Mb for last 1 days</p>
        if match 'reached the download.limit' "$PAGE"; then
            echo 3600
            return $ERR_LINK_TEMP_UNAVAILABLE
        # You have to wait X minutes, Y seconds till next download
        elif matchi 'You have to wait' "$PAGE"; then
            local MINS SECS
            MINS=$(parse 'class="err">' \
                '[[:space:]]\([[:digit:]]\+\) minute' <<< "$PAGE") || return
            SECS=$(parse 'class="err">' \
                '[[:space:]]\([[:digit:]]\+\) second' <<< "$PAGE") || return

            echo $(( MINS * 60 + SECS ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi
    fi

    if match 'Enter code below:' "$PAGE"; then
        local CAPTCHA DIGIT XCOORD

        # Funny captcha, this is text (4 digits)!
        # <span style='position:absolute;padding-left:64px;padding-top:3px;'>&#55;</span>
        CAPTCHA=$(parse_tag 'direction:ltr' div | \
            replace_all 'span>' $'span>\n' <<< "$FORM_HTML") || return
        CODE=0
        while read LINE; do
            DIGIT=$(parse 'padding-' '>&#\([[:digit:]]\+\);<' <<< "$LINE") || return
            XCOORD=$(parse 'padding-' '-left:\([[:digit:]]\+\)p' <<< "$LINE") || return

            # Depending x, guess digit rank
            if (( XCOORD < 15 )); then
                (( CODE = CODE + 1000 * (DIGIT-48) ))
            elif (( XCOORD < 30 )); then
                (( CODE = CODE + 100 * (DIGIT-48) ))
            elif (( XCOORD < 50 )); then
                (( CODE = CODE + 10 * (DIGIT-48) ))
            else
                (( CODE = CODE + (DIGIT-48) ))
            fi
        done <<< "$CAPTCHA"
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE") || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_METHOD=$(parse_form_input_by_name 'method_free' <<< "$FORM_HTML") || return
    FORM_DD=$(parse_form_input_by_name 'down_direct' <<< "$FORM_HTML") || return

    WAIT_TIME=$(parse_tag 'Wait.*seconds' 'span' <<< "$FORM_HTML") || return
    wait $((WAIT_TIME + 1)) || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -F "op=$FORM_OP" \
        -F "id=$FORM_ID" \
        -F "rand=$FORM_RAND" \
        ${FORM_USR:+"-F usr_login=$FORM_USR"} \
        -F "referer=$URL" \
        -F "method_free=$FORM_METHOD" \
        -F 'method_premium=' \
        -F "down_direct=$FORM_DD" \
        ${CODE:+"-F code=$CODE"} \
        "$URL") || return

    # <p class="err">Wrong captcha</p>
    if [ -n "$CODE" ] && match 'Wrong captcha' "$PAGE"; then
        return $ERR_CAPTCHA
    fi

    FILE_URL=$(parse_attr 'start your download' 'href' <<< "$PAGE") || return
    echo "$FILE_URL"
    echo "$FORM_FNAME"
}

# Upload a file to uptobox.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
uptobox_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://uptobox.com'

    local PAGE URL UPLOAD_ID USER_TYPE DL_URL DEL_URL
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_TMP_SRV FORM_BUTTON FORM_SESS
    local FORM_FN FORM_ST FORM_OP

    if [ -n "$AUTH" ]; then
        uptobox_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$BASE_URL") || return

    # "anon", "reg", "prem"
    USER_TYPE=$(parse 'var utype' "='\([^']*\)" <<< "$PAGE") || return
    log_debug "User type: '$USER_TYPE'"

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$PAGE") || return
    FORM_TMP_SRV=$(parse_form_input_by_name 'srv_tmp_url' <<< "$PAGE") || return
    FORM_BUTTON=$(parse_form_input_by_name 'submit_btn' <<< "$PAGE") || return
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$PAGE")

    # xupload.js
    UPLOAD_ID=$(random dec 12) || return
    PAGE=$(curl_with_log \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_1=@$FILE;type=application/octet-stream;filename=$DESTFILE" \
        -F 'tos=1' \
        -F "submit_btn=$FORM_BUTTON" \
        "${FORM_ACTION%%\?*}?X-Progress-ID=${UPLOAD_ID}&upload_id=${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=${FORM_UTYPE}" | break_html_lines) || return


    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_FN=$(parse_tag "name='fn'" textarea <<< "$PAGE") || return
    FORM_ST=$(parse_tag "name='st'" textarea <<< "$PAGE") || return
    FORM_OP=$(parse_tag "name='op'" textarea <<< "$PAGE") || return

    if [ "$FORM_ST" = 'OK' ]; then
        PAGE=$(curl -b 'lang=english' -d "fn=$FORM_FN" -d "st=$FORM_ST" \
            -d "op=$FORM_OP" "$FORM_ACTION") || return

        # Parse and output download + delete link
        parse_attr 'Download File' 'value' <<< "$PAGE" || return
        parse_attr 'killcode' 'value' <<< "$PAGE" || return
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uptobox url
# $3: requested capability list
# stdout: 1 capability per line
uptobox_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=english' "$URL") || return

    # The file you were looking for could not be found, sorry for any inconvenience
    if matchi 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_form_input_by_name 'fname' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse 'class="para_title"' \
            '[[:space:]](\([^)]\+\)') && translate_size "$FILE_SIZE" && \
            REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}
