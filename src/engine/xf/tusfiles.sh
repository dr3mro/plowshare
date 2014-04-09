#!/bin/bash
#
# tusfiles callbacks
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

xfilesharing:tusfiles_ls_parse_links() {
    local PAGE=$1
    local LINKS

    LINKS=$(parse_all_attr_quiet '^<TD align=left><a href="' 'href' <<< "$PAGE")

    echo "$LINKS"
}

xfilesharing:tusfiles_ls_parse_names() {
    local PAGE=$1
    local NAMES

    NAMES=$(parse_all_quiet '<TD align=left><a href="' '<img[^>]*>\([^<]\+\)' <<< "$PAGE")

    echo "$NAMES"
}

xfilesharing:tusfiles_ls_parse_folders() {
    local PAGE=$1
    local FOLDERS

    FOLDERS=$(parse_all_attr_quiet '<TD width="95%"><a' 'href' <<< "$PAGE") || return

    echo "$FOLDERS"
}
