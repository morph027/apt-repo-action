#!/bin/bash

set -e

if [[ -z "${IMPORT_FROM_REPO}" ]]; then
    echo "::notice title=Skipping::Skipping import"
    exit 0
fi

(
    echo "set base_path /tmp/apt-mirror"
    echo "set run_postmirror 0"
    echo -e "${IMPORT_FROM_REPO}"
) > /tmp/mirror.list
apt-mirror /tmp/mirror.list
mapfile -t packages < <(find /tmp/apt-mirror/mirror -type f -name '*.deb')
# shellcheck disable=SC2048,SC2086
cp -v ${packages[*]} .
