#!/bin/bash -e
#
# Upload a file to file sharing servers
# Copyright (c) 2010 Arnau Sanchez
#
# Output URL to standard output.
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


VERSION="SVN-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowup version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
LIMIT_RATE,r:,limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface,IFACE,Force IFACE interface
NAME_PREFIX,,name-prefix:,STRING,Prepend argument to each destination filename
NAME_SUFFIX,,name-suffix:,STRING,Append argument to each destination filename
"


# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD="$PWD"
    TARGET="$1"

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR="$PWD"
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR="$TARGET"
    fi

    cd -P "$DIR"
    TARGET="$PWD"
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Print usage
usage() {
    echo "Usage: plowup [OPTIONS] MODULE [MODULE_OPTIONS] FILE[:DESTNAME]..."
    echo
    echo "  Upload file(s) to a file-sharing site."
    echo "  Available modules:" $(echo "$MODULES" | tr '\n' ' ')
    echo
    echo "Global options:"
    echo
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "UPLOAD"
}

# Check if module name is contained in list
#
# $1: module name list (one per line)
# $2: module name
# $?: zero for found, non zero otherwie
# stdout: lowercase module name (if found)
module_exist() {
    N=$(echo "$2" | lowercase)
    while read MODULE; do
        if test "$N" = "$MODULE"; then
            echo "$N"
            return 0
        fi
    done <<< "$1"
    return 1
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_config_modules 'upload') || exit $?
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

MODULE_OPTIONS=$(get_modules_options "$MODULES" UPLOAD)
eval "$(process_options "plowshare" "$OPTIONS$MODULE_OPTIONS" "$@")"

# Verify verbose level
if [ -n "$QUIET" ]; then
    VERBOSE=0
elif [ -n "$VERBOSE" ]; then
    [ "$VERBOSE" -gt "4" ] && VERBOSE=4
else
    VERBOSE=2
fi

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
test $# -ge 1 || { usage; exit $ERR_FATAL; }
set_exit_trap

# Check requested module
MODULE=$(module_exist "$MODULES" "$1") || {
    log_error "unsupported module ($1)"
    exit $ERR_NOMODULE
}

FUNCTION=${MODULE}_upload

shift 1

RETVALS=()
UPCOOKIE=$(create_tempfile)

for FILE in "$@"; do

    # Check for remote upload
    if match "^https\?://" "$FILE"; then
        LOCALFILE="$FILE"
        DESTFILE=""
    else
        # non greedy parsing
        IFS=":" read LOCALFILE DESTFILE <<< "$FILE"

        if [ ! -f "$LOCALFILE" ]; then
            log_notice "Cannot find file: $LOCALFILE"
            continue
        fi

        if [ -d "$LOCALFILE" ]; then
            log_notice "Skipping directory: $LOCALFILE"
            continue
        fi
    fi

    test "$NAME_PREFIX" && DESTFILE="${NAME_PREFIX}${DESTFILE:-$LOCALFILE}"
    test "$NAME_SUFFIX" && DESTFILE="${DESTFILE:-$LOCALFILE}${NAME_SUFFIX}"

    log_notice "Starting upload ($MODULE): $LOCALFILE"
    test "$DESTFILE" && log_notice "Destination file: $DESTFILE"

    : > "$UPCOOKIE"
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$UPCOOKIE" "$LOCALFILE" "$DESTFILE" || \
        RETVALS=(${RETVALS[@]} "$?")
done

rm -f "$UPCOOKIE"

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
