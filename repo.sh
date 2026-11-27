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
# packages imported from the published repo (import.sh), may be empty
import_dir="${IMPORT_DIR:-}"
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
    gpg --batch --import <<<"${SIGNING_KEY}" 2>&1 | tee "${tmpdir}/gpg.log"
    mapfile -t fingerprints < <(grep -o "key [0-9A-Z]*:" "${tmpdir}/gpg.log" | sort -u | grep -o "[0-9A-Z]*" | tail -n1)
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
        # newest self-signature (key/uid/subkey binding, revocation) timestamp: changes whenever the exported key
        # changes (e.g. extended expiry, new uid or subkey), so the keyring version gets bumped
        key_id="${pub[4]}"
        key_timestamp="$(gpg --list-sigs --with-colons "${fingerprint}" | awk -F: -v id="${key_id}" '($1 == "sig" || $1 == "rev") && $5 == id && $6 > max { max = $6 } END { print max + 0 }')"
        if [[ "${key_timestamp}" -lt "${creation_date}" ]]; then
            key_timestamp="${creation_date}"
        fi
        # newest timestamp of all keys, used for version and reproducible mtime
        if [[ "${key_timestamp}" -gt "${keyring_epoch}" ]]; then
            keyring_epoch="${key_timestamp}"
        fi
        # file name keeps the creation date, so updated keys replace the installed file
        gpg --export "${fingerprint}" >"${keyring_name}-${creation_date}.gpg"
        keyring_files+=("${keyring_name}-${creation_date}.gpg")
    done
    # epoch prefix 1: keeps upgrades working from the former (unix timestamp) versions
    # date of the newest self-signature (or creation date)
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

# an existing reprepro db (e.g. .repo from a cache) may reference pool files which are missing: remove exactly
# the entries referencing them (in every codename), so packages still available get re-added below and the
# repo never lists files clients can't download
if [[ -d "${tmpdir}/.repo/${repo_name}/db" ]]; then
    pool_base="${tmpdir}/.repo/${repo_name}/"
    $reprepro_basedir -v checkpool fast 2>&1 | tee "${tmpdir}/checkpool.log"
    if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        printf "\e[0;36mStarting repo cache cleanup ...\e[0m\n"
        mapfile -t missing_files < <(sed -n "s|^Missing file '\(.*\)'!\$|\1|p" "${tmpdir}/checkpool.log")
        missing_filekeys=()
        for missing_file in "${missing_files[@]}"; do
            missing_filekeys+=("${missing_file#"${pool_base}"}")
        done
        mapfile -t cleanup_codenames < <(sed -n 's/^[Cc][Oo][Dd][Ee][Nn][Aa][Mm][Ee]:[[:space:]]*//p' "${dist_confs[@]}" | sort -u)
        for cleanup_codename in "${cleanup_codenames[@]}"; do
            # entries referencing a missing file as "<arch>|<package>|<version>|<filekey>". list format: one line
            # per entry, source packages continue with the remaining lines of their multi-line Files field
            # shellcheck disable=SC2016
            mapfile -t cleanup_entries < <(
                $reprepro_basedir --list-format '@@|${$architecture}|${Package}|${Version}|${Filename}|${Directory}|${Files}\n' \
                    listmatched "${cleanup_codename}" '*' |
                    awk -v missing="$(printf '%s\n' "${missing_filekeys[@]}")" '
                        function report(filekey) {
                            if (filekey in is_missing) print arch "|" package "|" version "|" filekey
                        }
                        BEGIN {
                            n = split(missing, list, "\n")
                            for (i = 1; i <= n; i++) if (list[i] != "") is_missing[list[i]] = 1
                        }
                        /^@@\|/ {
                            split($0, field, "|")
                            arch = field[2]; package = field[3]; version = field[4]; directory = field[6]
                            report(field[5])
                            files_line = field[7]
                        }
                        !/^@@\|/ { files_line = $0 }
                        # Files lines: "<md5> <size> <name>", relative to Directory
                        arch == "source" && split(files_line, file, " ") == 3 { report(directory "/" file[3]) }
                    ' | sort -t'|' -k1,3 -u
            )
            for cleanup_entry in "${cleanup_entries[@]}"; do
                IFS='|' read -r cleanup_arch cleanup_package cleanup_version cleanup_filekey <<<"${cleanup_entry}"
                echo "::warning title=Missing pool file::Removing ${cleanup_package} ${cleanup_version} (${cleanup_arch}) from ${cleanup_codename}, as ${cleanup_filekey} is missing in the pool."
                if [[ "${cleanup_arch}" == "source" ]]; then
                    # shellcheck disable=SC2016
                    $reprepro_basedir -v removefilter "${cleanup_codename}" \
                        '$Architecture (== source), Package (== '"${cleanup_package}"'), $Version (== '"${cleanup_version}"')'
                else
                    # only this file, e.g. other architectures of the same package stay
                    $reprepro_basedir -v removefilter "${cleanup_codename}" "Filename (== ${cleanup_filekey})"
                fi
            done
        done
    fi
fi
mkdir -p "${scan_dir}/build-${codename}-dummy-dir-for-find-to-succeed"

# add packages
# already published (imported) packages first: they win over rebuilt files with the same name, version and arch
packages=()
find_prune=()
if [[ -n "${import_dir}" && -d "${import_dir}" ]]; then
    mapfile -t packages < <(find "${import_dir}" -type f -regex '^.*\.\(deb\|dsc\)' | sort)
    # don't scan the import dir twice if it is inside the scan dir
    find_prune=(-path "$(realpath "${import_dir}")" -prune -o)
fi
published_count="${#packages[@]}"
mapfile -t -O "${#packages[@]}" packages < <(find "$(realpath "${scan_dir}")" "${find_prune[@]}" -type f -regex '^.*\.\(deb\|dsc\)' -print | sort)

includedebs=()
includedscs=()
# name_version_arch -> sha256 / file / published flag of the first file seen
declare -A package_sha256 package_file package_published

for index in "${!packages[@]}"; do
    package="${packages[${index}]}"
    published=""
    if [[ "${index}" -lt "${published_count}" ]]; then
        published="1"
    fi
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
    printf "\e[1;36m[%s %s] Checking for package %s %s (%s) ...\e[0m " "${codename}" "${components}" "${package_name}" "${package_version}" "${package_arch}"
    # same name, version and arch must never be published with different content (clients get hash sum mismatches).
    # without epoch: it isn't part of the pool file name, so 1.0 and 1:1.0 collide in the pool
    package_key="${package_name}_${package_version#*:}_${package_arch}"
    sha256="$(sha256sum <"${package}" | cut -d' ' -f1)"
    if [[ -n "${package_sha256[${package_key}]+x}" ]]; then
        if [[ "${package_sha256[${package_key}]}" == "${sha256}" ]]; then
            printf "\e[0;32mOK\e[0m (identical to %s)\n" "${package_file[${package_key}]}"
        elif [[ -n "${package_published[${package_key}]}" ]]; then
            printf "\e[0;33mKeeping published file\e[0m\n"
            echo "::warning title=Package already published::${package} (${package_name} ${package_version} ${package_arch}) differs from the published ${package_file[${package_key}]} (sha256 ${sha256} != ${package_sha256[${package_key}]}). Keeping the published file, bump the version to publish the new one."
        else
            # e.g. non-reproducible builds of the same package in multiple jobs, first one (sorted by path) wins
            printf "\e[0;33mKeeping first file\e[0m\n"
            echo "::warning title=Conflicting package files::${package} (${package_name} ${package_version} ${package_arch}) differs from ${package_file[${package_key}]} (sha256 ${sha256} != ${package_sha256[${package_key}]}). Keeping ${package_file[${package_key}]}."
        fi
        continue
    fi
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
    if [ -d "${tmpdir}/.repo/${repo_name}/db" ]; then
        # already in the repo db (e.g. .repo from a cache): published, "<arch>|<sha256>" (sha256 empty for sources)
        # shellcheck disable=SC2016
        db_entry="$($reprepro --list-format '${$architecture}|${SHA256}\n' listfilter "${codename}" "${filter}" | head -n1)"
        if [[ -n "${db_entry}" ]]; then
            db_sha256="${db_entry#*|}"
            package_sha256["${package_key}"]="${db_sha256:-${sha256}}"
            package_file["${package_key}"]="repo db"
            package_published["${package_key}"]="1"
            if [[ -n "${db_sha256}" && "${db_sha256}" != "${sha256}" ]]; then
                printf "\e[0;33mKeeping published file\e[0m\n"
                echo "::warning title=Package already published::${package} (${package_name} ${package_version} ${package_arch}) differs from the published one in the repo db (sha256 ${sha256} != ${db_sha256}). Keeping the published file, bump the version to publish the new one."
            else
                printf "\e[0;32mOK\e[0m (in repo db)\n"
            fi
            continue
        fi
    fi
    package_sha256["${package_key}"]="${sha256}"
    package_file["${package_key}"]="${package}"
    package_published["${package_key}"]="${published}"
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
