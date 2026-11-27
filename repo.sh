#!/bin/bash

set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# shellcheck disable=SC2153
override="${OVERRIDE}"
reprepro_basedir="reprepro -b ${tmpdir}/.repo/${repo_name}"
reprepro="${reprepro_basedir} -C ${components}"

signing_enabled=""
fingerprints=()
if [[ -n "${SIGNING_KEY}" ]]; then
    signing_enabled="1"
elif [[ -n "${SIGNING_KEY_PASSPHRASE}" ]]; then
    # a passphrase without a key almost certainly means a missing/misnamed secret
    echo "::error title=Missing signing-key::signing-key-passphrase is set but signing-key is empty. Check that the signing-key secret exists and is available to this workflow run."
    exit 1
elif [[ "${ALLOW_UNSIGNED,,}" != "true" ]]; then
    # fail closed: an empty secret (typo, fork PR, Dependabot, ...) must not silently downgrade a signed repo
    echo "::error title=Missing signing-key::signing-key is empty. Provide a signing-key, or set allow-unsigned: true to explicitly publish an unsigned repository."
    exit 1
else
    echo "::warning title=Unsigned repository::No signing-key provided, so the repository will be published unsigned. Without a signature, clients cannot verify that packages are authentic and untampered, and APT will only accept the repo when explicitly marked as trusted (e.g. [trusted=yes]). Providing a signing-key is strongly recommended."
fi

if [[ -n "${signing_enabled}" ]]; then
    # import signing key, create keyring package
    install -d -m 700 ~/.gnupg/
    echo "allow-preset-passphrase" >>~/.gnupg/gpg-agent.conf
    gpg --batch --import <<<"${SIGNING_KEY}" 2>&1 | tee /tmp/gpg.log
    mapfile -t fingerprints < <(grep -o "key [0-9A-Z]*:" /tmp/gpg.log | sort -u | grep -o "[0-9A-Z]*" | tail -n1)
    if [[ "${#fingerprints[@]}" -eq 0 ]]; then
        echo "::error title=Invalid signing-key::Could not import signing-key, see gpg output above."
        exit 1
    fi
    keyring_epoch=0
    keyring_files=()
    for fingerprint in "${fingerprints[@]}"; do
        keygrip="$(gpg --list-secret-keys --with-keygrip "${fingerprint}" | grep -m1 'Keygrip =' | grep -Eo "[0-9A-Z]{40}")"
        if [[ -n "${SIGNING_KEY_PASSPHRASE}" ]]; then
            /usr/lib/gnupg2/gpg-preset-passphrase --verbose --preset --passphrase "${SIGNING_KEY_PASSPHRASE}" "${keygrip}"
        fi
        IFS=':' read -r -a pub < <(gpg --list-keys --with-colons "${fingerprint}" | grep pub --color=never)
        creation_date="${pub[5]}"
        # newest key creation timestamp, used for version and reproducible mtime
        if [[ "${creation_date}" -gt "${keyring_epoch}" ]]; then
            keyring_epoch="${creation_date}"
        fi
        gpg --export "${fingerprint}" >"${keyring_name}-${creation_date}.gpg"
        keyring_files+=("${keyring_name}-${creation_date}.gpg")
    done
    # epoch prefix 1: keeps upgrades working from the former (unix timestamp) versions
    keyring_version="$(date -u -d "@${keyring_epoch}" +%Y-%m-%d)"
    keyring_mtime="$(date -u -d "@${keyring_epoch}" +%Y-%m-%dT%H:%M:%SZ)"

    keyring_contents=""
    for keyring_file in "${keyring_files[@]}"; do
        keyring_contents+="${keyring_contents:+, }{src: ${keyring_file}, dst: /etc/apt/trusted.gpg.d/}"
    done

    # render nfpm config template, only substitute the listed variables
    # shellcheck disable=SC2016
    KEYRING_NAME="${keyring_name}" \
        KEYRING_VERSION="${keyring_version}" \
        KEYRING_MTIME="${keyring_mtime}" \
        KEYRING_CONTENTS="[${keyring_contents}]" \
        MAINTAINER="${maintainer}" \
        REPO_NAME="${repo_name}" \
        HOMEPAGE="${homepage}" \
        envsubst '${KEYRING_NAME} ${KEYRING_VERSION} ${KEYRING_MTIME} ${KEYRING_CONTENTS} ${MAINTAINER} ${REPO_NAME} ${HOMEPAGE}' \
        <"${script_dir}/keyring-nfpm.yaml" >"${tmpdir}/keyring-nfpm.yaml"

    /tmp/nfpm package --config "${tmpdir}/keyring-nfpm.yaml" --packager deb
fi

if [ -d "${scan_dir}/.repo" ]; then
    cp -rv "${scan_dir}/.repo" "${tmpdir}"/
else
    # add repo config template if none exists
    mkdir -p "${tmpdir}/.repo/${repo_name}/conf"
    (
        echo "Origin: ${origin}"
        echo "Suite: ${suite}"
        echo "Label: ${label}"
        echo "Codename: ${codename}"
        echo "Components: ${components}"
        echo "Architectures: ${architectures}"
        if [[ -n "${signing_enabled}" ]]; then
            echo "SignWith: ${fingerprints[*]}"
        fi
        echo "Limit: ${limit}"
    ) >>"${tmpdir}/.repo/${repo_name}/conf/distributions"
    if [[ -n "${override}" ]]; then
        echo "DebOverride: ${override##*/}" >>"${tmpdir}/.repo/${repo_name}/conf/distributions"
        cp -v "${override}" "${tmpdir}/.repo/${repo_name}/conf/${override##*/}"
    fi
fi

# reprepro accepts conf/distributions as a file or as a directory of *.conf files
conf_dir="${tmpdir}/.repo/${repo_name}/conf"
if [[ -d "${conf_dir}/distributions" ]]; then
    mapfile -t dist_confs < <(find "${conf_dir}/distributions" -maxdepth 1 -type f -name '*.conf' | sort)
else
    dist_confs=("${conf_dir}/distributions")
fi

for dist_conf in "${dist_confs[@]}"; do
    if ! grep -q "^Components:.*${components}" "${dist_conf}"; then
        sed -i "s,^Components: \(.*\),Components: \1 ${components}, " "${dist_conf}"
    fi
done

# export key, configure reprepro (sign w/ multiple keys)
if [[ -n "${signing_enabled}" ]]; then
    test -f "${tmpdir}/.repo/gpg.key" || gpg --export --armor "${fingerprints[@]}" >"${tmpdir}/.repo/gpg.key"
    for dist_conf in "${dist_confs[@]}"; do
        sed -i 's,##SIGNING_KEY_ID##,'"${fingerprints[*]}"',' "${dist_conf}"
        # add SignWith to every distribution stanza lacking one (e.g. config created by a previous unsigned run)
        # field names are case-insensitive for reprepro, stanzas are separated by blank lines
        awk -v signwith="SignWith: ${fingerprints[*]}" '
            function flush() {
                for (i = 1; i <= n; i++) print buf[i]
                if (fields && !has_signwith) print signwith
                n = 0; fields = 0; has_signwith = 0
            }
            /^[[:space:]]*$/ { flush(); print; next }
            {
                buf[++n] = $0
                if ($0 !~ /^[[:space:]#]/) fields = 1
                if (tolower($0) ~ /^signwith:/) has_signwith = 1
            }
            END { flush() }
        ' "${dist_conf}" >"${dist_conf}.new"
        if ! cmp -s "${dist_conf}" "${dist_conf}.new"; then
            echo "::notice title=SignWith added::Added missing SignWith to ${dist_conf##*/.repo/}, the repository will be signed from now on."
        fi
        mv "${dist_conf}.new" "${dist_conf}"
    done
else
    # no key to sign with: drop SignWith from existing config (case-insensitive, like reprepro) and stale public key
    for dist_conf in "${dist_confs[@]}"; do
        if grep -qi '^signwith:' "${dist_conf}"; then
            echo "::warning title=SignWith removed::Removed SignWith from ${dist_conf##*/.repo/} because no signing-key was provided."
            sed -i '/^signwith:/Id' "${dist_conf}"
        fi
    done
    rm -f "${tmpdir}/.repo/gpg.key"
fi
mkdir -p "${scan_dir}/build-${codename}-dummy-dir-for-find-to-succeed"

# add packages
mapfile -t packages < <(find "${scan_dir}" -type f -regex '^.*\.\(deb\|dsc\)')

includedebs=()
includedscs=()

for package in "${packages[@]}"; do
    if [ "${package##*.}" == "dsc" ]; then
        package_name="${package##*/}"
        package_name="${package_name%%_*}"
        package_version="$(grep '^Version:' "${package}" | cut -d' ' -f2)"
        package_arch="source"
    else
        package_name="$(dpkg -f "${package}" Package)"
        package_version="$(dpkg -f "${package}" Version)"
        package_arch="$(dpkg -f "${package}" Architecture)"
    fi
    if [[ -z "${signing_enabled}" && "${package_name}" == "${keyring_name}" ]]; then
        # e.g. mirrored via import-from-repo-url from a previously signed repo
        printf "\e[0;33mSkipping keyring package %s (repository is unsigned)\e[0m\n" "${package##*/}"
        continue
    fi
    printf "\e[1;36m[%s %s] Checking for package %s %s (%s) in current repo cache ...\e[0m " "${codename}" "${components}" "${package_name}" "${package_version}" "${package_arch}"
    case "${package_arch}" in
    "all")
        # shellcheck disable=SC2016
        filter='Package (=='"${package_name}"'), $Version (=='"${package_version}"')'
        ;;
    *)
        # shellcheck disable=SC2016
        filter='Package (=='"${package_name}"'), $Version (=='"${package_version}"'), $Architecture (=='"${package_arch}"')'
        ;;
    esac
    if [ -d "${CI_PROJECT_DIR}/.repo/${repo_name}/db" ]; then
        if $reprepro listfilter "${codename}" "${filter}" | grep -q '.*'; then
            printf "\e[0;32mOK\e[0m\n"
            continue
        fi
    fi
    if grep -q "${package##*/}" <<<"${includedebs[@]}"; then
        printf "\e[0;32mOK\e[0m\n"
        continue
    fi
    printf "\e\033[0;38;5;166mAdding\e[0m\n"
    if [ "${package##*.}" == "dsc" ]; then
        includedscs+=("${package}")
    else
        includedebs+=("${package}")
    fi
done

# shellcheck disable=SC2128
if [ -n "${includedebs}" ]; then
    $reprepro \
        -vvv \
        includedeb \
        "${codename}" \
        "${includedebs[@]}"
fi
for includedsc in "${includedscs[@]}"; do
    $reprepro \
        -vvv \
        includedsc \
        "${codename}" \
        "${includedsc}"
done

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

if [[ -z "${signing_enabled}" ]]; then
    # drop keyring package left over from a previously signed repo
    if $reprepro_basedir listfilter "${codename}" "Package (== ${keyring_name})" | grep -q '.*'; then
        echo "::warning title=Keyring package removed::Removed ${keyring_name} from the repository because it is unsigned."
        $reprepro_basedir -v remove "${codename}" "${keyring_name}"
    fi
fi

# always (re-)export, so a changed SignWith (signed <-> unsigned) is applied even if no packages changed.
# reprepro writes InRelease/Release.gpg when signing and deletes stale ones otherwise.
$reprepro_basedir -v export

cp -rv "${tmpdir}/.repo/${repo_name}"/{dists,pool} "${repodir}"/
if [[ -n "${signing_enabled}" ]]; then
    cp -v "${tmpdir}/.repo/gpg.key" "${repodir}"/
fi

# See https://github.com/actions/upload-pages-artifact#example-permissions-fix-for-linux
chmod -c -R +rX "${repodir}"

echo "dir=${repodir}" >>"${GITHUB_OUTPUT}"
# empty if unsigned
echo "keyring=${signing_enabled:+${keyring_name}}" >>"${GITHUB_OUTPUT}"
