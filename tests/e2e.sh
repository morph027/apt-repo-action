#!/bin/bash
#
# End-to-end test for import.sh and repo.sh.
#
# 1. publish:   build a signed repository from scratch
# 2. republish: serve the published repository via HTTP and rebuild it with import-from-repo-url,
#               while the workspace contains rebuilt packages with the same name, version and arch
#
# Then check that no published package changed its content (clients would get hash sum mismatches),
# new packages got added and the repository signature is valid.
#
# Requirements: reprepro, apt-mirror, envsubst, gpg, python3, curl, dpkg-deb and nfpm at /tmp/nfpm
# (hard-coded in repo.sh). Needs root or sudo for the HTTP server on port 80, as apt-mirror can't
# mirror URLs with a port.
#
# Usage: tests/e2e.sh   (set KEEP_WORKDIR=1 to keep the temporary files for debugging)

set -Eeuo pipefail
shopt -s inherit_errexit
trap 'printf "ERROR: line %s: %s\n" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION_DIR
readonly NFPM=/tmp/nfpm
readonly HTTP_URL=http://localhost/
readonly REPO_NAME=e2e
readonly KEYRING_NAME="${REPO_NAME}-keyring"
readonly ARCHITECTURES="amd64 arm64 source"

workdir=""
http_pid=""
signing_key=""
# set by run_action
repo_dir=""
failures=0
sudo=()

# --- helpers ----------------------------------------------------------------------------------------

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

group() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::group::%s\n' "$*"
    else
        printf '\n===== %s\n' "$*"
    fi
}

endgroup() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::endgroup::\n'
    fi
}

# print a log file indented and prefixed, so workflow commands of the tested scripts (::warning:: etc.)
# aren't turned into annotations of the test run (the runner ignores leading whitespace)
show_log() {
    sed 's/\x1b\[[0-9;]*m//g; s/^/    | /' "$1"
}

cleanup() {
    local home
    stop_http_server
    if [[ -n "${workdir}" ]]; then
        for home in "${workdir}"/home-* "${workdir}/keygen"; do
            if [[ -d "${home}" ]]; then
                GNUPGHOME="${home}/.gnupg" gpgconf --kill gpg-agent 2>/dev/null || true
                GNUPGHOME="${home}" gpgconf --kill gpg-agent 2>/dev/null || true
            fi
        done
        if [[ -n "${KEEP_WORKDIR:-}" ]]; then
            log "Keeping ${workdir}"
            return
        fi
        rm -rf "${workdir}"
    fi
}

check_requirements() {
    local tool
    for tool in reprepro apt-mirror wget envsubst gpg gpgconf python3 curl dpkg-deb sha256sum zcat; do
        command -v "${tool}" >/dev/null || die "${tool} not found"
    done
    [[ -x "${NFPM}" ]] || die "nfpm not found at ${NFPM}"
    if [[ "${EUID}" -ne 0 ]]; then
        command -v sudo >/dev/null || die "root or sudo required for the HTTP server on port 80"
        sudo=(sudo)
    fi
}

# --- assertions -------------------------------------------------------------------------------------

pass() {
    log "PASS  $1"
}

fail() {
    log "FAIL  $1"
    failures=$((failures + 1))
}

# assert_eq <description> <expected> <actual>, an empty expected value fails (e.g. missing package)
assert_eq() {
    if [[ -z "$2" ]]; then
        fail "$1 (expected value is empty)"
    elif [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$2', got '$3')"
    fi
}

# assert_log <description> <log file> <extended regex>, colors are stripped before matching
assert_log() {
    if sed 's/\x1b\[[0-9;]*m//g' "$2" | grep -qE -- "$3"; then
        pass "$1"
    else
        fail "$1 (/$3/ not found in ${2##*/})"
    fi
}

# --- fixtures ---------------------------------------------------------------------------------------

# build_package <name> <version> <content> <output dir> [arch, default all]
# same arguments build a byte-identical package (fixed mtime), different content a different one
build_package() {
    local name="$1" version="$2" content="$3" out_dir="$4" arch="${5:-all}"
    local build_dir
    build_dir="$(mktemp -d -p "${workdir}")"
    printf '%s\n' "${content}" >"${build_dir}/content.txt"
    cat >"${build_dir}/nfpm.yaml" <<EOF
name: ${name}
arch: ${arch}
version: ${version}
version_schema: none
maintainer: e2e <e2e@example.com>
description: e2e test package
mtime: 2022-09-26T10:55:22Z
contents:
  - src: ${build_dir}/content.txt
    dst: /usr/share/${name}/content.txt
EOF
    mkdir -p "${out_dir}"
    "${NFPM}" package --config "${build_dir}/nfpm.yaml" --packager deb --target "${out_dir}/" >/dev/null
    rm -rf "${build_dir}"
}

# reproducible tar.gz of <dir>: tar_gz <dir> <output file>
tar_gz() {
    tar -C "$1" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | gzip -n >"$2"
}

# build_source <name> <version (with revision)> <content> <output dir>
# minimal 3.0 (quilt) source package (.dsc, orig and debian tarball), byte-identical for the same arguments
build_source() {
    local name="$1" version="$2" content="$3" out_dir="$4"
    local upstream="${version%-*}" build_dir file
    local -a files
    build_dir="$(mktemp -d -p "${workdir}")"
    mkdir -p "${build_dir}/orig" "${build_dir}/debian" "${out_dir}"
    printf '%s\n' "${content}" >"${build_dir}/orig/content.txt"
    printf '%s\n' "${version}" >"${build_dir}/debian/version"
    tar_gz "${build_dir}/orig" "${out_dir}/${name}_${upstream}.orig.tar.gz"
    tar_gz "${build_dir}/debian" "${out_dir}/${name}_${version}.debian.tar.gz"
    files=("${name}_${upstream}.orig.tar.gz" "${name}_${version}.debian.tar.gz")
    {
        printf 'Format: 3.0 (quilt)\nSource: %s\nBinary: %s\nArchitecture: any\nVersion: %s\n' "${name}" "${name}" "${version}"
        printf 'Maintainer: e2e <e2e@example.com>\nFiles:\n'
        for file in "${files[@]}"; do
            printf ' %s %s %s\n' "$(md5sum <"${out_dir}/${file}" | cut -d' ' -f1)" "$(stat -c %s "${out_dir}/${file}")" "${file}"
        done
        printf 'Checksums-Sha256:\n'
        for file in "${files[@]}"; do
            printf ' %s %s %s\n' "$(file_sha256 "${out_dir}/${file}")" "$(stat -c %s "${out_dir}/${file}")" "${file}"
        done
    } >"${out_dir}/${name}_${version}.dsc"
    rm -rf "${build_dir}"
}

# prints an armored private key without passphrase
generate_signing_key() {
    local gnupghome="${workdir}/keygen"
    install -d -m 700 "${gnupghome}"
    GNUPGHOME="${gnupghome}" gpg --quiet --batch --passphrase '' \
        --quick-gen-key "e2e <e2e@example.com>" rsa3072 sign 1y
    GNUPGHOME="${gnupghome}" gpg --batch --armor --export-secret-keys
}

start_http_server() {
    local dir="$1" attempt
    "${sudo[@]}" python3 -m http.server 80 --bind 127.0.0.1 --directory "${dir}" \
        >"${workdir}/http.log" 2>&1 &
    http_pid="$!"
    for attempt in {1..20}; do
        # ps instead of kill -0: the server may run as root via sudo
        if ! ps -p "${http_pid}" >/dev/null; then
            break
        fi
        if curl -fsS -o /dev/null "${HTTP_URL}dists/${REPO_NAME}/Release" 2>/dev/null; then
            return
        fi
        sleep 0.5
    done
    cat "${workdir}/http.log" >&2
    die "HTTP server did not start (${attempt} attempts)"
}

stop_http_server() {
    if [[ -n "${http_pid}" ]]; then
        "${sudo[@]}" kill "${http_pid}" 2>/dev/null || true
        wait "${http_pid}" 2>/dev/null || true
        http_pid=""
    fi
}

# run_action <name> <import-from-repo-url or empty> [import-from-repo-regex]
# runs import.sh and repo.sh like action.yml does, in a clean environment and workspace <workdir>/ws/<name>,
# sets repo_dir to the created repository
run_action() {
    local name="$1" import_from_repo="$2" import_regex="${3:-}"
    local workspace="${workdir}/ws/${name}" home="${workdir}/home-${name}" tmp="${workdir}/tmp-${name}"
    local output="${workdir}/${name}.output" log_file="${workdir}/${name}.log"
    local -a env=(
        PATH="${PATH}"
        HOME="${home}"
        # repo.sh's mktemp dirs, cleaned up with the workdir
        TMPDIR="${tmp}"
        GITHUB_OUTPUT="${output}"
        GITHUB_REPOSITORY_OWNER=e2e
        GITHUB_SERVER_URL=https://github.com
        GITHUB_REPOSITORY=e2e/apt-repo-action
        IMPORT_DIR="${workdir}/import-${name}"
        APT_MIRROR_BASE_PATH="${workdir}/apt-mirror-${name}"
        IMPORT_FROM_REPO="${import_from_repo}"
        IMPORT_FROM_REPO_REGEX="${import_regex}"
        REPO_NAME="${REPO_NAME}"
        CODENAME="${REPO_NAME}"
        COMPONENTS=main
        ARCHITECTURES="${ARCHITECTURES}"
        SECTION=misc
        PRIORITY=optional
        SIGNING_KEY="${signing_key}"
        ALLOW_UNSIGNED=false
    )
    install -d -m 700 "${home}" "${tmp}"
    : >"${output}"
    if ! (cd "${workspace}" && env -i "${env[@]}" "${ACTION_DIR}/import.sh" &&
        env -i "${env[@]}" "${ACTION_DIR}/repo.sh") >"${log_file}" 2>&1; then
        show_log "${log_file}"
        die "${name}: action failed"
    fi
    grep -E '^::|Checking for package' "${log_file}" | sed 's/\x1b\[[0-9;]*m//g; s/^/    | /' || true
    repo_dir="$(sed -n 's/^dir=//p' "${output}")"
    [[ -d "${repo_dir}" ]] || die "${name}: no repository dir in outputs"
}

# --- repository inspection --------------------------------------------------------------------------

# index_sha256 <repo dir> <package> [arch, default amd64] [component, default main]:
# SHA256 of the package in the Packages index
index_sha256() {
    awk -v package="$2" '
        /^Package: / { name = $2 }
        /^SHA256: / && name == package { print $2 }
    ' "$1/dists/${REPO_NAME}/${4:-main}/binary-${3:-amd64}/Packages"
}

# source_version <repo dir> <package>: version of the source package in the Sources index (empty if absent)
source_version() {
    zcat "$1/dists/${REPO_NAME}/main/source/Sources.gz" | awk -v package="$2" '
        /^Package: / { name = $2 }
        /^Version: / && name == package { print $2 }
    '
}

# pool_sha256 <repo dir> <package>: SHA256 of the package file(s) in the pool
pool_sha256() {
    find "$1/pool" -type f -name "$2_*.deb" -exec sha256sum {} + | cut -d' ' -f1
}

file_sha256() {
    sha256sum <"$1" | cut -d' ' -f1
}

# check_pool <description> <repo dir>: every file in every Packages and Sources index (all components) exists
# with the listed SHA256
check_pool() {
    local description="$1" dir="$2" index filename sha256 errors=()
    for index in "${dir}/dists/${REPO_NAME}"/*/binary-*/Packages.gz "${dir}/dists/${REPO_NAME}"/*/source/Sources.gz; do
        [[ -f "${index}" ]] || continue
        while read -r filename sha256; do
            if [[ ! -f "${dir}/${filename}" ]]; then
                errors+=("${filename} missing")
            elif [[ "$(file_sha256 "${dir}/${filename}")" != "${sha256}" ]]; then
                errors+=("${filename} sha256 mismatch")
            fi
        done < <(zcat "${index}" | awk '
            # Packages: Filename + SHA256, Sources: Directory + Checksums-Sha256 lines (" <sha256> <size> <name>")
            /^Filename: / { file = $2 }
            /^SHA256: / { print file, $2 }
            /^Directory: / { directory = $2 }
            /^[^ ]/ { in_sha256 = ($0 == "Checksums-Sha256:") ; next }
            in_sha256 && NF == 3 { print directory "/" $3, $1 }
        ')
    done
    assert_eq "${description}" "ok" "$(if [[ "${#errors[@]}" -eq 0 ]]; then echo ok; else echo "${errors[*]}"; fi)"
}

# state_dir <name>: reprepro state (.repo) left in repo.sh's tmpdir of run <name>
state_dir() {
    find "${workdir}/tmp-$1" -mindepth 2 -maxdepth 2 -type d -name .repo
}

# --- test -------------------------------------------------------------------------------------------

main() {
    local publish_repo republish_repo carried_repo carried_state live_repo stale_repo
    local repo package arch component key_date keyring_deb
    check_requirements
    workdir="$(mktemp -d -t apt-repo-action-e2e.XXXXXX)"
    trap cleanup EXIT

    signing_key="$(generate_signing_key)"
    [[ -n "${signing_key}" ]] || die "could not generate signing key"

    group "publish: initial repository"
    build_package pkga 1.0 original "${workdir}/ws/publish/build"
    build_package pkgb 1.0 unchanged "${workdir}/ws/publish/build"
    # two different new files with the same name, version and arch: first one (sorted by path) wins
    build_package pkgd 1.0 first "${workdir}/ws/publish/a dir"
    build_package pkgd 1.0 second "${workdir}/ws/publish/build"
    # architecture specific, with epoch (not part of the pool file name)
    for arch in amd64 arm64; do
        build_package pkgx 1:2.0 "${arch}" "${workdir}/ws/publish/build" "${arch}"
    done
    build_source pkgs 1.0-1 source "${workdir}/ws/publish/build/src"
    run_action publish ""
    publish_repo="${repo_dir}"
    endgroup

    group "republish: import published repository, rebuilt and new packages"
    start_http_server "${publish_repo}"
    build_package pkga 1.0 rebuilt-different "${workdir}/ws/republish/build"
    build_package pkgb 1.0 unchanged "${workdir}/ws/republish/build"
    build_package pkgc 1.0 new "${workdir}/ws/republish/build"
    build_package pkgx 1:2.0 amd64 "${workdir}/ws/republish/build" amd64
    # sources aren't imported (default regex), provide them again
    cp -a "${workdir}/ws/publish/build/src" "${workdir}/ws/republish/build/src"
    run_action republish "$(printf 'deb-%s %s %s main\n' amd64 "${HTTP_URL}" "${REPO_NAME}" arm64 "${HTTP_URL}" "${REPO_NAME}")"
    republish_repo="${repo_dir}"
    stop_http_server
    endgroup

    group "carried: existing reprepro state (.repo) with missing pool files, no import"
    carried_state="${workdir}/ws/carried/.repo"
    mkdir -p "${workdir}/ws/carried/build"
    cp -a "$(state_dir republish)" "${carried_state}"
    # second component with pkgx amd64 as well, trailing whitespace after the codename
    sed -i 's/^Components: .*/Components: main contrib/; s/^Codename: .*/& \t/' "${carried_state}/${REPO_NAME}/conf/distributions"
    reprepro -b "${carried_state}/${REPO_NAME}" --export=never -C contrib includedeb "${REPO_NAME}" \
        "${workdir}/ws/publish/build/pkgx_1:2.0_amd64.deb" >/dev/null
    # pkgc is available in the workspace again, pkgx amd64 (main and contrib) and pkgs (source) aren't,
    # pkgx arm64 must stay
    rm "${carried_state}/${REPO_NAME}/pool/main/p/pkgc/pkgc_1.0_all.deb" \
        "${carried_state}/${REPO_NAME}/pool/main/p/pkgx/pkgx_2.0_amd64.deb" \
        "${carried_state}/${REPO_NAME}/pool/contrib/p/pkgx/pkgx_2.0_amd64.deb" \
        "${carried_state}/${REPO_NAME}/pool/main/p/pkgs/pkgs_1.0.orig.tar.gz"
    cp "${workdir}/ws/republish/build/pkgc_1.0_all.deb" "${workdir}/ws/carried/build/"
    build_package pkga 1.0 rebuilt-again "${workdir}/ws/carried/build"
    # architecture specific package with the same name and version as the published "all" one
    build_package pkgb 1.0 amd64-variant "${workdir}/ws/carried/build" amd64
    run_action carried ""
    carried_repo="${repo_dir}"
    endgroup

    group "stale: cached reprepro state differs from the live repository"
    # live repository with a different pkga 1.0 than the cached state of the publish run
    build_package pkga 1.0 live "${workdir}/ws/live/build"
    run_action live ""
    live_repo="${repo_dir}"
    start_http_server "${live_repo}"
    mkdir -p "${workdir}/ws/stale"
    cp -a "$(state_dir publish)" "${workdir}/ws/stale/.repo"
    run_action stale "deb-amd64 ${HTTP_URL} ${REPO_NAME} main"
    stale_repo="${repo_dir}"
    stop_http_server
    endgroup

    group "checks"
    for repo in publish republish carried live stale; do
        check_pool "${repo}: every indexed file exists with the indexed sha256" "$(sed -n 's/^dir=//p' "${workdir}/${repo}.output")"
    done

    for package in pkga pkgb pkgd "${KEYRING_NAME}"; do
        assert_eq "${package}: unchanged in index after republish" \
            "$(index_sha256 "${publish_repo}" "${package}")" "$(index_sha256 "${republish_repo}" "${package}")"
        assert_eq "${package}: pool file matches index" \
            "$(index_sha256 "${republish_repo}" "${package}")" "$(pool_sha256 "${republish_repo}" "${package}")"
    done
    assert_eq "pkga: rebuilt file with different content not published" \
        "$(file_sha256 "${workdir}/ws/publish/build/pkga_1.0_all.deb")" "$(index_sha256 "${republish_repo}" pkga)"
    assert_log "pkga: warning about rebuilt file" "${workdir}/republish.log" \
        "^::warning title=Package already published::.*/build/pkga_1\.0_all\.deb "
    assert_log "pkgb: identical rebuilt file skipped" "${workdir}/republish.log" \
        "Checking for package pkgb 1\.0 \(all\) \.\.\. OK \(identical to "
    assert_eq "pkgc: new package added" \
        "$(file_sha256 "${workdir}/ws/republish/build/pkgc_1.0_all.deb")" "$(index_sha256 "${republish_repo}" pkgc)"
    assert_eq "pkgd: first file (sorted by path) published" \
        "$(file_sha256 "${workdir}/ws/publish/a dir/pkgd_1.0_all.deb")" "$(index_sha256 "${publish_repo}" pkgd)"
    assert_log "pkgd: warning about conflicting files" "${workdir}/publish.log" \
        "^::warning title=Conflicting package files::.*Keeping .*/a dir/pkgd_1\.0_all\.deb\.$"
    for arch in amd64 arm64; do
        assert_eq "pkgx ${arch}: published with epoch" \
            "$(file_sha256 "${workdir}/ws/publish/build/pkgx_1:2.0_${arch}.deb")" "$(index_sha256 "${publish_repo}" pkgx "${arch}")"
        assert_eq "pkgx ${arch}: unchanged in index after republish" \
            "$(index_sha256 "${publish_repo}" pkgx "${arch}")" "$(index_sha256 "${republish_repo}" pkgx "${arch}")"
    done
    assert_log "pkgx amd64: identical rebuilt file skipped" "${workdir}/republish.log" \
        "Checking for package pkgx 1:2\.0 \(amd64\) \.\.\. OK \(identical to "

    assert_log "carried: missing pkgc pool file cleaned up" "${workdir}/carried.log" \
        "^::warning title=Missing pool file::Removing pkgc 1\.0 \(binary\) from ${REPO_NAME}, as pool/main/p/pkgc/pkgc_1\.0_all\.deb is missing"
    assert_eq "carried: pkgc re-added from the workspace" \
        "$(index_sha256 "${republish_repo}" pkgc)" "$(index_sha256 "${carried_repo}" pkgc)"
    for component in main contrib; do
        assert_log "carried: missing pkgx amd64 pool file in ${component} cleaned up" "${workdir}/carried.log" \
            "^::warning title=Missing pool file::Removing pkgx 1:2\.0 \(binary\) from ${REPO_NAME}, as pool/${component}/p/pkgx/pkgx_2\.0_amd64\.deb is missing"
        assert_eq "carried: unavailable pkgx amd64 removed from ${component} index" \
            "absent" "$([[ -z "$(index_sha256 "${carried_repo}" pkgx amd64 "${component}")" ]] && echo absent || echo present)"
    done
    assert_eq "carried: pkgx arm64 kept" \
        "$(index_sha256 "${publish_repo}" pkgx arm64)" "$(index_sha256 "${carried_repo}" pkgx arm64)"
    assert_log "carried: source package with missing tarball cleaned up" "${workdir}/carried.log" \
        "^::warning title=Missing pool file::Removing pkgs 1\.0-1 \(source\) from ${REPO_NAME}, as pool/main/p/pkgs/pkgs_1\.0\.orig\.tar\.gz is missing"
    assert_eq "carried: source package not re-added from the carried pool" \
        "absent" "$([[ -z "$(source_version "${carried_repo}" pkgs)" ]] && echo absent || echo present)"
    assert_eq "carried: pkga from repo db kept" \
        "$(index_sha256 "${publish_repo}" pkga)" "$(index_sha256 "${carried_repo}" pkga)"
    assert_log "carried: warning about rebuilt pkga differing from repo db" "${workdir}/carried.log" \
        "^::warning title=Package already published::.*/build/pkga_1\.0_all\.deb .* differs from the published .*repo db"
    assert_log "carried: arch specific pkgb not compared with published all pkgb" "${workdir}/carried.log" \
        "Checking for package pkgb 1\.0 \(amd64\) \.\.\. +Adding"

    assert_eq "pkgs: source package published" "1.0-1" "$(source_version "${publish_repo}" pkgs)"

    assert_log "stale: warning about stale repo db" "${workdir}/stale.log" \
        "^::warning title=Stale repo db::pkga 1\.0 \(all\) in the repo db differs from the published "
    assert_eq "stale: live pkga published instead of the cached one" \
        "$(index_sha256 "${live_repo}" pkga)" "$(index_sha256 "${stale_repo}" pkga)"

    # new key: newest self-signature is the creation signature
    key_date="$(GNUPGHOME="${workdir}/keygen" gpg --batch --with-colons --list-keys 2>/dev/null |
        awk -F: '$1 == "pub" { print $6; exit }')"
    key_date="$(date -u -d "@${key_date}" +%Y-%m-%d)"
    keyring_deb="$(find "${republish_repo}/pool" -type f -name "${KEYRING_NAME}_*.deb")"
    assert_eq "keyring: version is 1:<date of newest self-signature>" \
        "1:${key_date}" "$(dpkg-deb --field "${keyring_deb}" Version)"
    assert_log "keyring: rebuilt keyring identical to published one" "${workdir}/republish.log" \
        "Checking for package ${KEYRING_NAME} 1:${key_date} \(all\) \.\.\. OK \(identical to "

    assert_eq "signature: InRelease valid for published gpg.key" "valid" "$(
        export GNUPGHOME="${workdir}/verify"
        install -d -m 700 "${GNUPGHOME}"
        gpg --batch --quiet --import "${republish_repo}/gpg.key" 2>/dev/null
        gpg --batch --quiet --verify "${republish_repo}/dists/${REPO_NAME}/InRelease" 2>/dev/null && echo valid
        gpgconf --kill gpg-agent
    )"
    endgroup

    if [[ "${failures}" -gt 0 ]]; then
        die "${failures} check(s) failed"
    fi
    log "All checks passed."
}

main "$@"
