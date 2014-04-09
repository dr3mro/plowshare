#!/bin/bash
#
# thefile callbacks
# Copyright (c) 2013 Plowshare team
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

xfilesharing:thefile_pr_parse_file_name() {
    local -r PAGE=$1
    local FILE_NAME

    FILE_EXT=$(parse_quiet '<title>Download ' '<title>Download .* \([^[:space:]]\+\)<' <<< "$PAGE")
    FILE_NAME=$(parse_quiet '<title>Download ' '<title>Download \(.*\)<' <<< "$PAGE")

    FILE_NAME="${FILE_NAME// /_}"
    [ -n "$FILE_EXT" ] && FILE_NAME="${FILE_NAME/%_${FILE_EXT}/.${FILE_EXT}}"

    echo "$FILE_NAME"
}

xfilesharing:thefile_pr_parse_file_size() {
    return 0
}
