# create-apt-repo

Create an APT repo using [reprepro](https://manpages.debian.org/bookworm/reprepro/reprepro.1.en.html).
Can be deployed to GH pages using [upload-pages-artifact](https://github.com/actions/upload-pages-artifact) and [deploy-pages](https://github.com/actions/deploy-pages) actions.

## Inputs

| Input | Required? | Default | Description |
| ----- | --------- | ------- | ----------- |
| `repo-name` | `true` | `n/a` | Repository name |
| `scan-dir` | `false` | `$PWD` | Scan this directory for packages to include in the repo. |
| `keyring-name` | `false` | `${{ inputs.repo-name }}-keyring` | Keyring package name (signed repos only). |
| `origin` | `false` | `${{ inputs.repo-name }}` | [Origin](https://wiki.debian.org/DebianRepository/Format#Origin) |
| `suite` | `false` | `${{ inputs.repo-name }}` | [Suite](https://wiki.debian.org/DebianRepository/Format#Suite) |
| `label` | `false` | `${{ inputs.repo-name }}` | [Label](https://wiki.debian.org/DebianRepository/Format#Label) |
| `codename` | `false` | `${{ inputs.repo-name }}` | [Codename](https://wiki.debian.org/DebianRepository/Format#Codename) |
| `components` | `false` | `main` | [Components](https://wiki.debian.org/DebianRepository/Format#Components) |
| `architectures` | `false` | `amd64` | [Architectures](https://wiki.debian.org/DebianRepository/Format#Architectures) |
| `limit` | `false` | `0` | How many package versions to keep (0 = unlimited). |
| `signing-key` | `false`* | `n/a` | **Recommended.** Private gpg key for signing. *Required unless `allow-unsigned` is `true`. Please use secrets! |
| `signing-key-passphrase` | `false` | `n/a` | Passphrase for `signing-key` (if the key is protected). Please use secrets! |
| `allow-unsigned` | `false` | `false` | Set to `true` to explicitly publish an unsigned repo when `signing-key` is empty (no `SignWith`, no `gpg.key`, no keyring package). Without it, an empty `signing-key` fails the action. Not recommended, see [Unsigned repositories](#unsigned-repositories). |
| `import-from-repo-url` | `false` | `n/a` | Import existing packages from this repo url. Workaround for immutable GH actions cache. |
| `import-from-repo-regex` | `false` | `n/a` | Regex (`find -regex`, emacs syntax) to apply to imported packages, e.g. <code>^.*_\(arm64\&#124;all\)\.deb$</code> for arm64 and architecture independent packages. Filtered packages are not protected against republishing, see below. |
| `import-from-repo-failure-allow` | `false` | `n/a` | Do not fail on import errors (e.g. first run). |
| `maintainer` | `false` | `apt-repo-action@${GITHUB_REPOSITORY_OWNER}` | Package maintainer for keyring package (signed repos only). |
| `homepage` | `false` | `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}` | Homepage for keyring package (signed repos only). |
| `override` | `false` | `n/a` | Optional override file (see [man page](https://manpages.debian.org/unstable/reprepro/reprepro.1.en.html#OVERRIDE_FILES)) |

## Outputs

| Output | Description |
| ------ | ----------- |
| `dir` | The directory containing the ready to deploy APT repo |
| `keyring` | The name of the created keyring (empty if unsigned) |

## Unsigned repositories

> [!WARNING]
> Without a `signing-key`, clients cannot verify that packages are authentic and untampered.
> APT only accepts such a repo with `[trusted=yes]`, which disables **all** signature checks for that source:
> anyone who can tamper with the hosting or the transport can serve packages that are installed as root.
> Only use `allow-unsigned: true` for testing or trusted internal setups.

Switching an existing repo between signed and unsigned is handled automatically: `SignWith` is added or removed
in the reprepro config, the repo is re-exported, and `gpg.key` and the keyring package are dropped when unsigned.
Clients have to update their APT source accordingly.

## Usage Example

```yaml

# yamllint disable rule:truthy
on:
  release:
    types:
      - published

permissions:
  contents: read
  pages: write
  id-token: write

env:
  REPO_NAME: caddy
  CODENAME: jammy
  COMPONENTS: main
  ARCHITECTURES: amd64 arm64

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      artifact_id: ${{ steps.upload-artifact.outputs.artifact-id }}
      keyring: ${{ steps.create-apt-repo.outputs.keyring }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      - name: Setup Pages
        uses: actions/configure-pages@v4
      - name: Create packages
        run: |
          ...
          do something funny to create your packages using e.g. fpm, nfpm, ....
          ...
      - uses: morph027/apt-repo-action@v3
        id: create-apt-repo
        with:
          repo-name: ${{ env.REPO_NAME }}
          # for an unsigned repo (not recommended), omit signing-key and set allow-unsigned: true
          signing-key: ${{ secrets.SIGNING_KEY }}
          codename: ${{ env.CODENAME }}
          components: ${{ env.COMPONENTS }}
          architectures: ${{ env.ARCHITECTURES }}
      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          name: github-pages
          path: ${{ steps.create-apt-repo.outputs.dir }}
  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
      - name: Adding summary
        env:
          KEYRING: ${{ needs.build.outputs.keyring }}
          PAGE_URL: ${{ steps.deployment.outputs.page_url }}
        run: |
          PAGE_URL="${PAGE_URL%/}/"
          {
            echo ':rocket:'
            echo ''
            echo '```bash'
            if [ -n "${KEYRING}" ]; then
              echo "sudo curl -sfLo /etc/apt/trusted.gpg.d/${KEYRING}.asc ${PAGE_URL}gpg.key"
              echo "echo \"deb ${PAGE_URL} ${CODENAME} ${COMPONENTS}\" | sudo tee /etc/apt/sources.list.d/${REPO_NAME}.list"
            else
              # unsigned repo (allow-unsigned), APT needs to be told to trust it
              echo "echo \"deb [trusted=yes] ${PAGE_URL} ${CODENAME} ${COMPONENTS}\" | sudo tee /etc/apt/sources.list.d/${REPO_NAME}.list"
            fi
            echo '```'
          } >> "${GITHUB_STEP_SUMMARY}"
```

Due to current cache limitations ([A cache today is immutable and cannot be updated](https://github.com/actions/cache/blob/main/tips-and-workarounds.md#update-a-cache)), we can't store the
reprepro database between workflow runs. To keep the current packages, you can set `import-from-repo-url` which will trigger an `apt-mirror` process on the existing repo before re-building the repo.

```yaml
...
      - uses: morph027/apt-repo-action@v3
        id: create-apt-repo
        with:
          ...
          import-from-repo-url: |
            deb-amd64 https://your-github-handle.github.io/your-github-repo-name/ jammy main
            deb-arm64 https://your-github-handle.github.io/your-github-repo-name/ jammy main
...
```

Packages are compared by name, version (without epoch) and architecture, plus sha256. Imported packages are treated as published and always win:

* a rebuilt package that is identical to the published one is skipped
* a rebuilt package with different content is not published (warning), as replacing a file under the same version causes `Hash Sum mismatch` errors on clients. Bump the version instead.
* two new (not yet published) files with the same name, version and architecture but different content (e.g. non-reproducible builds in multiple jobs): the first one (sorted by path) is published, the others are skipped (warning)

> [!NOTE]
> Only imported packages (or packages in an existing reprepro db, see below) are protected, so `import-from-repo-url` must
> cover every published distribution and architecture, and `import-from-repo-regex` must not filter out published packages.
> Source packages are not imported by default.
> Not covered: an `all` and an architecture specific package with the same name and version are not compared with each other,
> and for source packages only the `.dsc` is compared (not the referenced tarballs).

If `<scan-dir>/.repo` contains an existing reprepro state (`conf`, `db`, `pool`), packages in its db count as published too.
Entries whose pool files are missing are removed first (only the affected architecture or source package, in every codename)
and re-added if the package is available in the scan dir or the import.

The keyring package version is the date of the newest self-signature of the signing key (e.g. `1:2022-09-26`),
so extending the expiry or adding a uid or subkey publishes a new keyring package. Changes on the same day as the previous
self-signature, third-party signatures or a changed `maintainer`/`homepage` keep the version, so the published keyring
package is kept (with a warning).
