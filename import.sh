#!/bin/bash

set -e

# packages imported from the published repo, read by repo.sh (same default there)
import_dir="${IMPORT_DIR:-${RUNNER_TEMP:-/tmp}/apt-repo-action-import}"
# start clean, so a previous run of the action in the same job doesn't leak its packages
rm -rf "${import_dir}"

if [[ -z "${IMPORT_FROM_REPO}" ]]; then
    echo "::notice title=Skipping::Skipping import"
    exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# fresh per run by default, so packages mirrored by a previous run aren't imported again
apt_mirror_base_path="${APT_MIRROR_BASE_PATH:-${tmpdir}/apt-mirror}"
{
    echo "set base_path ${apt_mirror_base_path}"
    echo "set run_postmirror 0"
    echo -e "${IMPORT_FROM_REPO}"
} >"${tmpdir}/mirror.list"
apt-mirror "${tmpdir}/mirror.list" |& tee "${tmpdir}/mirror.log"
if grep -E -q -i 'failed|0 bytes will be downloaded' "${tmpdir}/mirror.log"; then
    cat "${tmpdir}/mirror.log"
    if [[ -z "${IMPORT_FROM_REPO_FAILURE_ALLOW}" ]]; then
        exit 1
    fi
fi
mapfile -t packages < <(find "${apt_mirror_base_path}/mirror" -type f -regex "${IMPORT_FROM_REPO_REGEX:-^.*\.deb}")
if [[ "${#packages[@]}" -gt 0 ]]; then
    # separate dir: repo.sh treats these as already published and keeps them over rebuilt files
    mkdir -p "${import_dir}"
    cp -v "${packages[@]}" "${import_dir}"/
fi
