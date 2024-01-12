#!/bin/bash

set -e

tmpdir="$(mktemp -d)"
repodir="$(mktemp -d)"

set -u
# shellcheck disable=SC2153
repo_name="${REPO_NAME}"
set +u
scan_dir="${SCAN_DIR:-${PWD}}"
keyring_name="${KEYRING_NAME:-${repo_name}}-keyring"
origin="${ORIGIN:-${repo_name}}"
suite="${SUITE:-${repo_name}}"
label="${LABEL:-${repo_name}}"
codename="${CODENAME:-${repo_name}}"
components="${COMPONENTS:-main}"
architectures="${ARCHITECTURES:-amd64}"
limit="${LIMIT:-0}"
maintainer="${MAINTAINER:-apt-repo-action@${GITHUB_REPOSITORY_OWNER}}"
homepage="${HOMEPAGE:-${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}}"
reprepro_basedir="reprepro -b ${tmpdir}/.repo/${repo_name}"
reprepro="${reprepro_basedir} -C ${components}"

gpg --import <<<"${SIGNING_KEY}" 2>&1 | tee /tmp/gpg.log
mapfile -t fingerprints < <(grep -o "key [0-9A-Z]*:" /tmp/gpg.log | sort -u | grep -o "[0-9A-Z]*" | tail -n1)
keyring_version=0
keyring_files=()
for fingerprint in "${fingerprints[@]}"; do
    IFS=':' read -r -a pub < <(gpg --list-keys --with-colons "${fingerprint}" | grep pub --color=never)
    creation_date="${pub[5]}"
    keyring_version=$(("${keyring_version}" + "${creation_date}"))
    gpg --export "${fingerprint}" >"${keyring_name}-${creation_date}.gpg"
    keyring_files+=("${keyring_name}-${creation_date}.gpg")
done

cat >"${tmpdir}/keyring-nfpm.yaml" <<EOF
name: ${keyring_name}
arch: all
version: ${keyring_version}
version_schema: none
maintainer: ${maintainer}
description: ${repo_name} keyring
homepage: ${homepage}
contents:
EOF

for keyring_file in "${keyring_files[@]}"; do
    cat >>"${tmpdir}/keyring-nfpm.yaml" <<EOF
  - src: ${keyring_file}
    dst: /etc/apt/trusted.gpg.d/
EOF
done

/tmp/nfpm package --config "${tmpdir}/keyring-nfpm.yaml" --packager deb

mkdir -p "${tmpdir}/.repo/${repo_name}/conf"
(
    echo "Origin: ${origin}"
    echo "Suite: ${suite}"
    echo "Label: ${label}"
    echo "Codename: ${codename}"
    echo "Components: ${components}"
    echo "Architectures: ${architectures}"
    echo "SignWith: ${fingerprints[*]}"
    echo "Limit: ${limit}"
    echo ""
) >>"${tmpdir}/.repo/${repo_name}/conf/distributions"

if ! grep -q "^Components:.*${components}" "${tmpdir}/.repo/${repo_name}/conf/distributions"; then
    sed -i "s,^Components: \(.*\),Components: \1 ${components}, " "${tmpdir}/.repo/${repo_name}/conf/distributions"
fi

# export key for curl, configure reprepro (sign w/ multiple keys)
test -f "${tmpdir}/.repo/gpg.key" || gpg --export --armor "${fingerprints[@]}" >"${tmpdir}/.repo/gpg.key"
sed -i 's,##SIGNING_KEY_ID##,'"${fingerprints[*]}"',' "${tmpdir}/.repo/${repo_name}/conf/distributions"
mkdir -p "${scan_dir}/build-${codename}-dummy-dir-for-find-to-succeed"

# add packages
mapfile -t packages < <(find "${scan_dir}" -type f -name "*.deb")

# shellcheck disable=SC2128
if [ -n "${packages}" ]; then
    $reprepro \
        -vvv \
        includedeb \
        "${codename}" \
        "${packages[@]}"
fi

if ! $reprepro_basedir -v checkpool fast |& tee /tmp/missing; then
    printf "\e[0;36mStarting repo cache cleanup ...\e[0m\n"
    mapfile -t missingfiles < <(grep "Missing file" /tmp/log | grep --color=never -o "/.*\.deb")
    for missingfile in "${missingfiles[@]}"; do
        missingfile="${missingfile##*/}"
        name="$(cut -d'_' -f 1 <<<"${missingfile}")"
        version="$(cut -d'_' -f 2 <<<"${missingfile}")"
        echo "cleanup missing file ${missingfile} from repo"
        $reprepro \
            -v \
            remove \
            "${codename}" \
            "${name}=${version}"
    done
fi

cp -rv "${tmpdir}/.repo/${repo_name}"/{dists,pool} "${tmpdir}"/.repo/gpg.key "${repodir}"/

# See https://github.com/actions/upload-pages-artifact#example-permissions-fix-for-linux
chmod -c -R +rX "${repodir}"

echo "dir=${repodir}" >>"${GITHUB_OUTPUT}"
echo "keyring=${keyring_name}" >>"${GITHUB_OUTPUT}"
