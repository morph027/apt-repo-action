# create-apt-repo

Create an APT repo using [reprepro](https://manpages.debian.org/bookworm/reprepro/reprepro.1.en.html).
Can be deployed to GH pages using [upload-pages-artifact](https://github.com/actions/upload-pages-artifact) and [deploy-pages](https://github.com/actions/deploy-pages) actions.

## Inputs

| Input | Required? | Default | Description |
| ----- | --------- | ------- | ----------- |
| `repo-name` | `true` | | Repository name |
| `scan-dir` | `false` | `$PWD` | Scan this directory for packages to include in the repo. |
| `keyring-name` | `false` | `${{ inputs.repo-name }}-keyring` | Keyring package name |
| `origin` | `false` | `${{ inputs.repo-name }}` | [Origin](https://wiki.debian.org/DebianRepository/Format#Origin) |
| `suite` | `false` | `${{ inputs.repo-name }}` | [Suite](https://wiki.debian.org/DebianRepository/Format#Suite) |
| `label` | `false` | `${{ inputs.repo-name }}` | [Label](https://wiki.debian.org/DebianRepository/Format#Label) |
| `codename` | `false` | `${{ inputs.repo-name }}` | [Codename](https://wiki.debian.org/DebianRepository/Format#Codename) |
| `components` | `false` | `main` | [Components](https://wiki.debian.org/DebianRepository/Format#Components) |
| `architectures` | `false` | `amd64` | [Architectures](https://wiki.debian.org/DebianRepository/Format#Architectures) |
| `limit` | `false` | `0` | How many package versions to keep (0 = unlimited). |
| `signing-key` | `true` | `n/a` | Private gpg key for signing. Please use secrets! |
| `import-from-repo-url` | `false` | `n/a` | Import existing packages from this repo url. Workaround for immutable GH actions cache. |
| `import-from-repo-failure-allow` | `false` | `n/a` | Do not fail on import errors (e.g. first run). |
| `maintainer` | `false` | `apt-repo-action@${GITHUB_REPOSITORY_OWNER}` | Package maintainer for keyring package. |
| `homepage` | `false` | `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}` | Homepage for keyring package. |
| `override` | `false` | `n/a` | Optional override file (see [man page](https://manpages.debian.org/unstable/reprepro/reprepro.1.en.html#OVERRIDE_FILES)) |

## Outputs

| Output | Description |
| ------ | ----------- |
| `dir` | The directory containing the ready to deploy APT repo |
| `keyring` | The name of the created keyring |

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
      - uses: morph027/apt-repo-action@v2
        id: create-apt-repo
        with:
          repo-name: ${{ env.REPO_NAME }}
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
        run: |
          echo ':rocket:' >> $GITHUB_STEP_SUMMARY
          echo '' >> $GITHUB_STEP_SUMMARY
          echo '```bash' >> $GITHUB_STEP_SUMMARY
          echo 'curl -sfLo /etc/apt.trusted.gpg.d/${{ needs.build.outputs.keyring }}.asc ${{ steps.deploy-pages.outputs.page_url }}gpg.key' >> $GITHUB_STEP_SUMMARY
          echo 'echo "deb ${{ steps.deploy-pages.outputs.page_url }} ${{ env.CODENAME }} ${{ env.COMPONENTS }}" >/etc/apt/sources.list.d/${{ env.REPO_NAME }}.list' >> $GITHUB_STEP_SUMMARY
          echo '```' >> $GITHUB_STEP_SUMMARY
```

Due to current cache limitations ([A cache today is immutable and cannot be updated](https://github.com/actions/cache/blob/main/tips-and-workarounds.md#update-a-cache)), we can't store the
reprepro database between workflow runs. To keep the current packages, you can set `import-from-repo-url` which will trigger an `apt-mirror` process on the existing repo before re-building the repo.

```yaml
...
      - uses: morph027/apt-repo-action@v2
        id: create-apt-repo
        with:
          ...
          import-from-repo-url: |
            deb-amd64 https://your-github-handle.github.io/your-github-repo-name/ jammy main
            deb-arm64 https://your-github-handle.github.io/your-github-repo-name/ jammy main
...
```
