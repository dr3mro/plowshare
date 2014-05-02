#!/usr/bin/env bash
#
# Retrieve metadata from a download link (sharing site url)
# Copyright (c) 2013-2014 Plowshare team
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

declare -r VERSION='GIT-snapshot'

declare -r EARLY_OPTIONS="
HELP,h,help,,Show help info and exit
HELPFULL,H,longhelp,,Exhaustive help info (with modules command-line options)
GETVERSION,,version,,Output plowprobe version information and exit
ALLMODULES,,modules,,Output available modules (one per line) and exit. Useful for wrappers.
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
GET_MODULE,,get-module,,Retrieve module name and exit. Faster than --printf=%m
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each link). Default string is: \"%F%u%n\".
ENGINES,,engine,t=ENGINE,Use specific engine (add more modules). Available: xfilesharing.
TRY_REDIRECTION,,follow,,If no module is found for link, follow HTTP redirects (curl -L). Default is disabled.
NO_CURLRC,,no-curlrc,,Do not use curlrc config file"


# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD=$PWD
    local TARGET=$1

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR=$TARGET
    fi

    cd -P "$DIR"
    TARGET=$PWD
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Guess if item is a generic URL (a simple link string) or a text file with links.
# $1: single URL or file (containing links)
process_item() {
    local -r ITEM=$1

    if match_remote_url "$ITEM"; then
        strip <<< "$ITEM"
    elif [ -f "$ITEM" ]; then
        if [[ $ITEM =~ (zip|rar|tar|[7gx]z|bz2|mp[234g]|avi|mkv|jpg)$ ]]; then
            log_error "Skip: '$ITEM' seems to be a binary file, not a list of links"
        else
            # Discard empty lines and comments
            sed -ne '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p}' "$ITEM"
        fi
    else
        log_error "Skip: cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage (on stdout)
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowprobe [OPTIONS] [MODULE_OPTIONS] URL|FILE...'
    echo 'Retrieve metadata from file sharing download links.'
    echo
    echo 'Global options:'
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options "$MODULES" PROBE
}

# Note: Global option $PRINTF_FORMAT is accessed directly.
probe() {
    local -r MODULE=$1
    local -r URL_RAW=$2
    local -r ITEM=$3

    local URL_ENCODED=$(uri_encode <<< "$URL_RAW")
    local FUNCTION=${MODULE}_probe
    local MAP I CHECK_LINK CAPS FILE_NAME FILE_SIZE FILE_HASH FILE_ID

    log_debug "Starting probing ($MODULE): $URL_ENCODED"

    # $PRINTF_FORMAT
    local PCOOKIE=$(create_tempfile)
    local PRESULT=$(create_tempfile)

    # Capabilities:
    # - c: check link (module function return value)
    # - f: filename (can be empty string if not available)
    # - h: filehash (can be empty string if not available)
    # - i: fileid (can be empty string if not available)
    # - s: filesize (in bytes). This can be approximative.
    CHECK_LINK=0

    if test "$PRINTF_FORMAT"; then
        CAPS=c
        for I in f h i s; do
            [[ ${PRINTF_FORMAT,,} = *%$I* ]] && CAPS+=$I
        done
    else
        CAPS=cf
    fi

    $FUNCTION "$PCOOKIE" "$URL_ENCODED" "$CAPS" >"$PRESULT" || CHECK_LINK=$?

    OLD_IFS=$IFS
    IFS=$'\n'
    local -a DATA=($(< "$PRESULT"))
    IFS=$OLD_IFS

    rm -f "$PRESULT" "$PCOOKIE"

    if [[ ${#DATA[@]} -gt 0 ]]; then
        # Get mapping variable (we must keep order)
        MAP=${DATA[${#DATA[@]}-1]}
        unset DATA[${#DATA[@]}-1]
        MAP=${MAP//c}

        for I in "${!DATA[@]}"; do
            case ${MAP:$I:1} in
                f)
                    FILE_NAME=${DATA[$I]}
                    ;;
                h)
                    FILE_HASH=${DATA[$I]}
                    ;;
                i)
                    FILE_ID=${DATA[$I]}
                    ;;
                s)
                    FILE_SIZE=${DATA[$I]}
                    ;;
                *)
                    log_error "plowprobe: unknown capability \`${MAP:$I:1}', ignoring"
                    ;;
            esac
        done
    elif [ $CHECK_LINK -eq 0 ]; then
        log_notice "$FUNCTION returned no data, module probe function might be wrong"
    elif [ $CHECK_LINK -ne $ERR_LINK_DEAD ]; then
        log_debug "$FUNCTION returned no data"
    fi

    # Don't process dead links
    if [ $CHECK_LINK -eq 0 -o \
        $CHECK_LINK -eq $ERR_LINK_TEMP_UNAVAILABLE -o \
        $CHECK_LINK -eq $ERR_LINK_NEED_PERMISSIONS -o \
        $CHECK_LINK -eq $ERR_LINK_PASSWORD_REQUIRED ]; then

        if [ $CHECK_LINK -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
            log_debug "Link active (with password): $URL_ENCODED"
        elif [ $CHECK_LINK -eq $ERR_LINK_NEED_PERMISSIONS ]; then
            log_debug "Link active (with permissions): $URL_ENCODED"
        else
            log_debug "Link active: $URL_ENCODED"
        fi

        DATA=("$MODULE" "$URL_RAW" "$CHECK_LINK" "$FILE_NAME" "$FILE_SIZE" "$FILE_HASH" "$FILE_ID")
        pretty_print DATA[@] "${PRINTF_FORMAT:-%F%u%n}"

    elif [ $CHECK_LINK -eq $ERR_LINK_DEAD ]; then
        log_notice "Link is not alive: $URL_ENCODED"
    else
        log_error "Skip: \`$URL_ENCODED': failed inside ${FUNCTION}() [$CHECK_LINK]"
    fi

    return $CHECK_LINK
}

# Plowprobe printf format
# ---
# Interpreted sequences are:
# %c: probe return status (0, $ERR_LINK_DEAD, ...)
# %f: filename or empty string (if not available)
# %F: alias for "# %f%n" or empty string if %f is empty
# %h: filehash or empty string (if not available)
# %i: fileid, link identifier or empty string (if not available)
# %m: module name
# %s: filesize (in bytes) or empty string (if not available).
#     Note: it's often approximative.
# %u: download url
# and also:
# %n: newline
# %t: tabulation
# %%: raw %
# ---
#
# Check user given format
# $1: format string
pretty_check() {
    # This must be non greedy!
    local S TOKEN
    S=${1//%[cfFhimsunt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi
}

# $1: array[@] (module, dl_url, check_link, file_name, file_size, file_hash, file_id)
# $2: format string
pretty_print() {
    local -a A=("${!1}")
    local FMT=$2
    local -r CR=$'\n'

    test "${FMT#*%%}" != "$FMT" && FMT=$(replace_all '%%' "%raw" <<< "$FMT")

    if test "${FMT#*%F}" != "$FMT"; then
        if [ -z "${A[3]}" ]; then
            FMT=${FMT//%F/}
            [ -z "$FMT" ] && return
        else
            FMT=$(replace_all '%F' "# %f%n" <<< "$FMT")
        fi
    fi

    handle_tokens "$FMT" '%raw,%' '%t,	' "%n,$CR" \
        "%m,${A[0]}" "%u,${A[1]}" "%c,${A[2]}" "%f,${A[3]}" \
        "%s,${A[4]}" "%h,${A[5]}" "%i,${A[6]}"
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

set -e # enable exit checking

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'probe') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Process command-line (plowprobe early options)
eval "$(process_core_options 'plowprobe' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFULL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if test "$ALLMODULES"; then
    for MODULE in $MODULES; do echo "$MODULE"; done
    exit 0
fi

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowprobe' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowprobe options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowprobe' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ $# -lt 1 ]; then
    log_error 'plowprobe: no URL specified!'
    log_error "plowprobe: try \`plowprobe --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

log_report_info
log_report "plowprobe version $VERSION"

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowprobe: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowprobe: using alternate configuration file'
    fi
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

# Engines check
for E in "${ENGINES[@]}"; do
    if [[ $E =~ ^(xfilesharing)$ ]]; then
        if [ ! -f "$LIBDIR/engine/$E.sh" ]; then
            log_error "plowprobe: can't find engine \`$E', sources are missing"
            exit $ERR_BAD_COMMAND_LINE
        fi
    else
        log_error "plowprobe: unknown engine \`$E'"
        exit $ERR_BAD_COMMAND_LINE
    fi
done

MODULE_OPTIONS=

for E in "${ENGINES[@]}"; do
    source "$LIBDIR/engine/$E.sh"
    if ! ${E}_init "$LIBDIR/engine"; then
        log_error "plowprobe: $E engine initialisation error"
        exit $ERR_BAD_COMMAND_LINE
    fi
    MODULE_OPTIONS+=$'\n'$(${E}_get_core_options)
    MODULE_OPTIONS+=$'\n'$(${E}_get_all_modules_options PROBE)
done

if [ -z "$NO_CURLRC" -a -f "$HOME/.curlrc" ]; then
    log_debug 'using local ~/.curlrc'
fi

MODULE_OPTIONS+=$(get_all_modules_options "$MODULES" PROBE)

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowprobe' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowprobe: no URL specified!'
    log_error "plowprobe: try \`plowprobe --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Sanity check
for MOD in $MODULES; do
    if ! declare -f "${MOD}_probe" > /dev/null; then
        log_error "plowprobe: module \`${MOD}_probe' function was not found"
        exit $ERR_BAD_COMMAND_LINE
    fi
done

set_exit_trap

for ITEM in "${COMMAND_LINE_ARGS[@]}"; do

    # Read links from stdin
    if [ "$ITEM" = '-' ]; then
        if [[ -t 0 || -S /dev/stdin ]]; then
            log_notice 'Wait links from stdin...'
        fi
        ITEM=$(create_tempfile '.stdin') || {
           log_error 'Cannot create temporary file';
           continue;
        }
        cat > "$ITEM"
    fi

    OLD_IFS=$IFS
    IFS=$'\n'
    ELEMENTS=( $(process_item "$ITEM") )
    IFS=$OLD_IFS

    for URL in "${ELEMENTS[@]}"; do
        PRETVAL=0

        MODULE=$(get_module "$URL" "$MODULES") || true
        ENGINE=

        if [ -z "$MODULE" ]; then
            if [ "${#ENGINES[@]}" -gt 0 ] && match_remote_url "$URL"; then
                for E in "${ENGINES[@]}"; do
                    PRETVAL=$ERR_NOMODULE
                    if ${E}_probe_module 'plowprobe' "$URL"; then
                        MOD=$(${E}_get_module "$URL")
                        PRETVAL=$?
                        if [ $PRETVAL -eq 0 ]; then
                            log_notice "plowprobe ($E): found matching module \`${MOD#*:}'"
                            MODULE=${MOD/:/_}

                            # Sanity check
                            if declare -f "${MODULE}_probe" > /dev/null; then
                                ENGINE=$E
                                break
                            else
                                log_error "plowprobe: module \`${MODULE}_probe' function was not found"
                                MODULE=
                            fi
                        else
                            log_error "plowprobe ($E): get_module failed ($PRETVAL)"
                        fi
                    fi
                done

            elif match_remote_url "$URL"; then
                if test "$TRY_REDIRECTION"; then
                    # Test for simple HTTP 30X redirection
                    # (disable User-Agent because some proxy can fake it)
                    log_debug 'No module found, try simple redirection'

                    local URL_ENCODED HEADERS URL_TEMP
                    URL_ENCODED=$(uri_encode <<< "$URL")
                    HEADERS=$(curl --user-agent '' -i "$URL_ENCODED") || true
                    URL_TEMP=$(grep_http_header_location_quiet <<< "$HEADERS")

                    if [ -n "$URL_TEMP" ]; then
                        MODULE=$(get_module "$URL_TEMP" "$MODULES") || PRETVAL=$?
                        test "$MODULE" && URL="$URL_TEMP"
                    else
                        match 'https\?://[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}/' \
                            "$URL" && log_notice 'Raw IPv4 address not expected. Provide an URL with a DNS name.'
                        test "$HEADERS" && \
                            log_debug "remote server reply: $(first_line <<< "${HEADERS//$'\r'}")"
                        PRETVAL=$ERR_NOMODULE
                    fi
                else
                    PRETVAL=$ERR_NOMODULE
                fi
            else
                log_debug "Skip: '$URL' (in $ITEM) doesn't seem to be a link"
                PRETVAL=$ERR_NOMODULE
            fi
        fi

        if [ $PRETVAL -ne 0 ]; then
            match_remote_url "$URL" && \
                log_error "Skip: no module for URL ($(basename_url "$URL")/)"

            # Check if plowlist can handle $URL
            if [ -z "$MODULES_LIST" ]; then
                MODULES_LIST=$(grep_list_modules 'list' 'probe') || true
                for MODULE in $MODULES_LIST; do
                    source "$LIBDIR/modules/$MODULE.sh"
                done
            fi
            MODULE=$(get_module "$URL" "$MODULES_LIST") || true
            if [ -n "$MODULE" ]; then
                log_notice "Note: This URL ($MODULE) is supported by plowlist"
            fi

            RETVALS+=($PRETVAL)
        elif test "$GET_MODULE"; then
            RETVALS+=(0)
            echo "$MODULE"
        else
            # Get configuration file module options
            test -z "$NO_PLOWSHARERC" && \
                process_configfile_module_options '[Pp]lowprobe' "$MODULE" PROBE "$EXT_PLOWSHARERC"

            [ -n "$ENGINE" ] && \
                eval "$(process_engine_options "$ENGINE" \
                    "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

            eval "$(process_module_options "$MODULE" PROBE \
                "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

            [ -n "$ENGINE" ] && ${ENGINE}_vars_set
            ${MODULE}_vars_set
            probe "$MODULE" "$URL" "$ITEM" || PRETVAL=$?
            ${MODULE}_vars_unset
            [ -n "$ENGINE" ] && ${ENGINE}_vars_unset

            RETVALS+=($PRETVAL)
        fi
    done
done

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    # Drop success values
    RETVALS=(${RETVALS[@]/#0*} -$ERR_FATAL_MULTIPLE)

    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
