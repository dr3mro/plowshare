#!/usr/bin/env bash
#
# Retrieve list of links from a shared-folder (sharing site) url
# Copyright (c) 2010-2014 Plowshare team
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
GETVERSION,,version,,Output plowlist version information and exit
ALLMODULES,,modules,,Output available modules (one per line) and exit. Useful for wrappers.
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
RECURSE,R,recursive,,Recurse into sub folders
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each link). Default string is: \"%F%u%n\".
NO_MODULE_FALLBACK,,fallback,,If no module is found for link, simply list all URLs contained in page
ENGINE,,engine,s=ENGINE,Use specific engine (add more modules). Available: xfilesharing."


# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD=$PWD
    local TARGET=$1

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR=$PWD
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

# Print usage (on stdout)
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowlist [OPTIONS] [MODULE_OPTIONS] URL...'
    echo 'Retrieve list of links from folders (of file sharing websites).'
    echo
    echo 'Global options:'
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options "$MODULES" LIST
}

# Example: "MODULE_4SHARED_LIST_HAS_SUBFOLDERS=no"
# $1: module name
module_config_has_subfolders() {
    local -u VAR="MODULE_${1}_LIST_HAS_SUBFOLDERS"
    [[ ${!VAR} = [Yy][Ee][Ss] || ${!VAR} = 1 ]]
}

# Plowlist printf format
# ---
# Interpreted sequences are:
# %f: filename (can be an empty string)
# %F: alias for "# %f%n" or empty string if %f is empty
# %u: download url
# %m: module name
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
    S=${1//%[fFumnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi
}

# $1: format string
# $2: module name
pretty_print() {
    local FMT=$1
    local -r CR=$'\n'
    local URL NAME

    test "${FMT#*%%}" != "$FMT" && FMT=$(replace_all '%%' "%raw" <<< "$FMT")

    # Pair every two lines
    while IFS= read -r URL; do
        IFS= read -r NAME

        if test "${FMT#*%F}" != "$FMT"; then
            if [ -z "$NAME" ]; then
                FMT=${FMT//%F/}
                [ -z "$FMT" ] && continue
            else
                FMT=$(replace_all '%F' "# %f%n" <<< "$FMT")
            fi
        fi

        handle_tokens "$FMT" '%raw,%' '%t,	' "%n,$CR" \
            "%m,$2" "%u,$URL" "%f,$NAME"
    done
}

# Fake list module function. See --fallback switch.
# $1: some web url
# $2: recurse subfolders (ignored here)
# stdout: list of links
module_null_list() {
    local -r BASE_URL=$(basename_url "$1" | replace '/www.' '/')
    local PAGE LINKS URL RE

    PAGE=$(curl -L "$1" | break_html_lines_alt) || return
    LINKS=$(parse_all_attr_quiet 'https\?://' 'href\|src' <<< "$PAGE")

    # If domain has simply 'domain.tld' format, then also exlcude subdomains
    if [[ $BASE_URL =~ \..*\. ]]; then
        log_debug "exclude links from '${BASE_URL##*/}' domain"
        RE="^[Hh][Tt][Tt][Pp][Ss]?:${BASE_URL#*:}"
    else
        log_debug "exclude links from '*.${BASE_URL##*/}' domain"
        RE="^[Hh][Tt][Tt][Pp][Ss]?://(www\.)?${BASE_URL##*/}"
    fi

    while IFS= read -r URL; do
        [[ $URL =~ $RE ]] && continue
        echo "$URL"
        echo
    done <<< "$LINKS"
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

set -e # enable exit checking

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'list') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Process command-line (plowlist early options)
eval "$(process_core_options 'plowlist' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFULL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if test "$ALLMODULES"; then
    for MODULE in $MODULES; do echo "$MODULE"; done
    exit 0
fi

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowlist' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowlist options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowlist' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ $# -lt 1 ]; then
    log_error 'plowlist: no folder URL specified!'
    log_error "plowlist: try \`plowlist --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowlist: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowlist: using alternate configuration file'
    fi
fi

if [ -n "$ENGINE" ]; then
    if [ "$ENGINE" = 'xfilesharing' ]; then
        source "$LIBDIR/engine/$ENGINE.sh"
        log_notice "plowlist: initialising $ENGINE engine"
        if ! ${ENGINE}_init "$LIBDIR/engine"; then
            log_error "$ENGINE initialisation error"
            exit $ERR_FATAL
        fi
    else
        log_error "Error: unknown engine name: $ENGINE"
        exit $ERR_FATAL
    fi
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

# Print chosen options
[ -n "$RECURSE" ] && log_debug 'plowlist: --recursive selected'

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" LIST)

if [ -n "$ENGINE" ]; then
    MODULE_OPTIONS=$MODULE_OPTIONS$'\n'$(${ENGINE}_get_all_modules_options LIST)
fi

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowlist' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowlist: no folder URL specified!'
    log_error "plowlist: try \`plowlist --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Sanity check
for MOD in $MODULES; do
    if ! declare -f "${MOD}_list" > /dev/null; then
        log_error "plowlist: module \`${MOD}_list' function was not found"
        exit $ERR_BAD_COMMAND_LINE
    fi
done

set_exit_trap

for URL in "${COMMAND_LINE_ARGS[@]}"; do
    LRETVAL=0

    MODULE=$(get_module "$URL" "$MODULES") || LRETVAL=$?

    if [ $LRETVAL -ne 0 ] && [ -n "$ENGINE" ] && match_remote_url "$URL"; then
        LRETVAL=0
        if ${ENGINE}_probe_module 'plowlist' "$URL"; then
            MODULE=$(${ENGINE}_get_module "$URL") || LRETVAL=$?
        else
            LRETVAL=$ERR_NOMODULE
        fi
    fi

    if [ $LRETVAL -ne 0 ]; then
        if ! match_remote_url "$URL"; then
            if [[ -f "$URL" && "${URL##*.}" = [Dd][Ll][Cc] ]]; then
                log_error "Skip: .dlc container not handled ($URL)"
            else
                log_error "Skip: not an URL ($URL)"
            fi
            RETVALS=(${RETVALS[@]} $LRETVAL)
            continue
        elif test "$NO_MODULE_FALLBACK"; then
            log_notice 'No module found, list URLs in page as requested'
            MODULE='module_null'
            LRETVAL=0
        else
            log_error "Skip: no module for URL ($(basename_url "$URL")/)"
            RETVALS=(${RETVALS[@]} $LRETVAL)
            continue
        fi
    fi

    # Get configuration file module options
    test -z "$NO_PLOWSHARERC" && \
        process_configfile_module_options '[Pp]lowlist' "$MODULE" LIST "$EXT_PLOWSHARERC"

    if [ -n "$ENGINE" ]; then
        eval "$(process_module_options "${MODULE//:/_}" LIST \
            "${COMMAND_LINE_MODULE_OPTS[@]}")" || true
    else
        eval "$(process_module_options "$MODULE" LIST \
            "${COMMAND_LINE_MODULE_OPTS[@]}")" || true
    fi

    FUNCTION=${MODULE}_list
    log_notice "Retrieving list ($MODULE): $URL"

    if ! module_config_has_subfolders "$MODULE" && test -n "$RECURSE"; then
        log_notice 'recursive flag has no sense here, ignoring'
    fi

    if [ -n "$ENGINE" ]; then
        ${MODULE//:/_}_vars_set
    else
        ${MODULE}_vars_set
    fi
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$URL" "$RECURSE" | \
        pretty_print "${PRINTF_FORMAT:-%F%u%n}" "$MODULE" || LRETVAL=$?
    if [ -n "$ENGINE" ]; then
        ${MODULE//:/_}_vars_unset
    else
        ${MODULE}_vars_unset
    fi

    if [ $LRETVAL -eq 0 ]; then
        : # everything went fine
    elif [ $LRETVAL -eq $ERR_LINK_DEAD ]; then
        log_error 'Non existing or empty folder'
        [ -z "$RECURSE" -a -z "$NO_MODULE_FALLBACK" ] && \
            module_config_has_subfolders "$MODULE" && \
            log_notice 'Try adding -R/--recursive option to look into sub folders'
    elif [ $LRETVAL -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
        log_error 'You must provide a valid password'
    elif [ $LRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
        log_error 'Links are temporarily unavailable. Maybe uploads are still being processed'
    else
        log_error "Failed inside ${FUNCTION}() [$LRETVAL]"
    fi
    RETVALS=(${RETVALS[@]} $LRETVAL)
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
