#!/bin/bash

set -e

if [[ -z "${IMPORT_FROM_REPO}" ]]; then
    echo "::notice title=Skipping::Skipping import"
    exit 0
fi

{
    echo "set base_path ${APT_MIRROR_BASE_PATH:-/tmp/apt-mirror}"
    echo "set run_postmirror 0"
    echo -e "${IMPORT_FROM_REPO}"
} >/tmp/mirror.list
apt-mirror /tmp/mirror.list |& tee /tmp/mirror.log
if grep -q -i failed /tmp/mirror.log; then
    cat /tmp/mirror.log
    if [[ -z "${IMPORT_FROM_REPO_FAILURE_ALLOW}" ]]; then
        exit 1
    fi
fi
mapfile -t packages < <(find /tmp/apt-mirror/mirror -type f -name "${IMPORT_FROM_REPO_PATTERN:-*.deb}")
# shellcheck disable=SC2128
if [ -n "${packages}" ]; then
    # shellcheck disable=SC2048,SC2086
    cp -v ${packages[*]} .
fi
