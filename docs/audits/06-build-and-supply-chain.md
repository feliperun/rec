# Build and supply-chain audit (baseline 1a21cf271f98)

## Scope
- Build definition: `build.zig`, `build.zig.zon` (no external Zig package
  dependencies; the only vendored native dependency, `vendor/miniaudio.h`, is
  checked into the tree rather than fetched at build time).
- CI/release workflows: `.github/workflows/ci.yml`, `.github/workflows/release.yml`,
  `.github/workflows/quality.yml`, including trigger conditions, permissions,
  and every `run:`/`uses:` step.
- Installer scripts: `install.sh`, `install.ps1` (the curl/irm-piped installers
  linked from the project's README).
- Git hooks: `githooks/pre-commit`, `githooks/commit-msg`.
- E2E harness scripts referenced from CI: `scripts/e2e_transcribe.py`,
  `scripts/e2e_viewer.py`.
- `docs/sentrux.md` and `.sentrux/rules.toml` were read to confirm the Sentrux
  install/verification story is the same (none) in local docs as in CI.
- Not inspected: `scripts/e2e_record_silence.py`, `scripts/e2e_playback_notes.py`,
  `scripts/e2e_notes_jobs.py`, `scripts/e2e_player.py`, `scripts/e2e_resize.py` —
  referenced by `ci.yml` but not in this node's read list; the two harness
  scripts that were read use only synthetic, locally-generated fixtures and
  a fake `PATH`-shadowed clipboard binary, so the pattern looked consistent.
  `vendor/miniaudio.h`'s contents were not reviewed — it is a vendored,
  version-controlled source file, not something fetched or executed by the
  build, so it is out of scope for a supply-chain audit.

## Summary
- critical: 1 · major: 2 · minor: 1

## FINDING-BSC-01: CI installs and executes an unauthenticated third-party binary with no integrity check
- **Severity:** critical
- **Class:** security
- **Location:** `.github/workflows/quality.yml:18-29`
- **Evidence:**
  ```
  - name: Install Sentrux
    env:
      SENTRUX_VERSION: v0.5.7
    run: |
      mkdir -p "$HOME/.sentrux/bin"
      curl -fsSL "https://github.com/sentrux/sentrux/releases/download/${SENTRUX_VERSION}/sentrux-linux-x86_64" \
        -o "$HOME/.sentrux/bin/sentrux"
      chmod +x "$HOME/.sentrux/bin/sentrux"
      echo "$HOME/.sentrux/bin" >> "$GITHUB_PATH"

  - name: Sentrux check (absolute rules)
    run: sentrux check .

  - name: Sentrux gate (no regression)
    if: github.event_name == 'pull_request'
    run: sentrux gate .
  ```
- **Failure mode:** the workflow downloads a release binary from a third-party
  GitHub repository (`sentrux/sentrux`) by version tag only, with no checksum,
  detached signature, or provenance (`cosign`/`slsa`) check of any kind before
  making it executable and running it. The job triggers unattended on every
  `push` to `main` and on every `pull_request` (`quality.yml:3-6`), so the
  download-and-execute step runs automatically for any pull request opened
  against the repo — no maintainer approval gates it before the binary is
  fetched and run.
- **Impact:** if the referenced release asset is ever replaced behind the same
  tag (GitHub does not prevent an asset under an existing release from being
  reuploaded), or the `sentrux/sentrux` account/repo is compromised, the next
  CI run on `main` or on any pull request executes the attacker's binary with
  full access to the repository checkout, the runner's network egress, and
  whatever `GITHUB_TOKEN`/environment the job carries — with no code change to
  this repository needed to trigger it.
- **Suggested fix:** pin and verify a SHA-256 (or signature) for
  `SENTRUX_VERSION` and `curl`-fetch a checksums file (or use `cosign verify`)
  before `chmod +x`, failing the job if the digest does not match.

## FINDING-BSC-02: Release build job carries `pull-requests: write` it never uses, widening the blast radius of a compromised action
- **Severity:** major
- **Class:** security
- **Location:** `.github/workflows/release.yml:7-9,27-47`
- **Evidence:**
  ```
  permissions:
    contents: write
    pull-requests: write

  jobs:
    ...
    build:
      needs: release-please
      if: ${{ needs.release-please.outputs.release_created == 'true' }}
      strategy:
        fail-fast: false
        matrix:
          include:
            - { runs-on: macos-14, target: aarch64-macos, artifact: rec-macos-arm64, bin: rec, sanity: true }
            ...
      runs-on: ${{ matrix.runs-on }}
      steps:
        - uses: actions/checkout@v4
          with:
            ref: ${{ needs.release-please.outputs.tag_name }}
        - uses: mlugg/setup-zig@v2
          with:
            version: "0.16.0"
  ```
- **Failure mode:** `permissions:` is declared once at the workflow level and
  applies to every job, including `build`. The `build` job only checks out the
  tagged source, cross-compiles with `zig`, and later runs
  `gh release upload ... --clobber` (`release.yml:78`), which needs
  `contents: write` but never touches pull requests. It still runs with
  `pull-requests: write` for its entire duration, across five matrix runners
  each pulling `actions/checkout@v4` and `mlugg/setup-zig@v2` from upstream by
  a mutable version tag rather than a pinned commit SHA (`release.yml:49,52`
  and the same pattern in `ci.yml:18-19,44-45,67-68` and `quality.yml:14`).
- **Impact:** if either third-party action is compromised upstream (a tag
  moved to a malicious commit — the same class of incident as the 2025
  `tj-actions/changed-files` compromise), the injected code runs inside the
  `build` job with a `GITHUB_TOKEN` scoped to `contents: write` *and*
  `pull-requests: write`, letting it modify or merge pull requests in this
  repository in addition to tampering with release contents — a scope no step
  in this job legitimately needs.
- **Suggested fix:** scope `pull-requests: write` to only the
  `release-please` job (which opens the release PR) via a per-job
  `permissions:` block, and pin `actions/checkout`, `mlugg/setup-zig`, and
  `googleapis/release-please-action` to full commit SHAs instead of mutable
  tags.

## FINDING-BSC-03: Installer scripts fetch and run release binaries with no integrity verification
- **Severity:** major
- **Class:** security
- **Location:** `install.sh:42-50,76`
- **Evidence:**
  ```
  tmp_bin="$(mktemp)"
  trap 'rm -f "$tmp_bin"' EXIT

  echo "Downloading ${download_url}..."
  curl -fsSL -o "$tmp_bin" "$download_url"
  # mktemp creates the file 0600 and `chmod +x` honours the umask, which leaves
  # the install at 0711: every user but the installing one loses read access to
  # a binary whose whole point is to sit on a shared PATH.
  chmod 755 "$tmp_bin"
  ...
  "$dest" --help || true
  ```
  and `install.ps1:29-31,50`:
  ```
  Write-Host "Downloading $($asset.browser_download_url)..."
  Invoke-WebRequest $asset.browser_download_url -OutFile $dest
  ...
  & $dest --help
  ```
- **Failure mode:** both installers — the exact one-liners advertised for
  users to run (`curl ... | sh`, `irm ... | iex`) — resolve the newest (or a
  requested) GitHub release asset, download it over HTTPS, and neither
  compares it against a published checksum nor verifies any signature before
  making it executable, installing it onto the shared `PATH`
  (`install.sh:56-61`, potentially via `sudo mv`), and immediately executing
  it (`"$dest" --help`, `& $dest --help`).
- **Impact:** any compromise of the GitHub release assets for
  `feliperun/rec` (a hijacked maintainer token, a re-uploaded asset under an
  existing tag, or a compromised CI runner that produced the artifact) is
  installed and executed by every user who runs the documented install
  command, with no independent way for the script to detect the tampering.
- **Suggested fix:** publish a checksums file (and ideally a detached
  signature) alongside each release asset in `release.yml`, and have both
  installers download and verify it before `chmod +x`/execution.

## FINDING-BSC-04: GitHub Actions pinned by mutable version tag, not commit SHA
- **Severity:** minor
- **Class:** security
- **Location:** `.github/workflows/ci.yml:18-19,44-45,67-68`
- **Evidence:**
  ```
  - uses: actions/checkout@v4
  - uses: mlugg/setup-zig@v2
    with:
      version: "0.16.0"
  ```
  (repeated identically in `release.yml:49,52` and `quality.yml:14`, plus
  `googleapis/release-please-action@v5` at `release.yml:18`).
- **Failure mode:** every third-party action referenced across all three
  workflows is pinned to a major/minor version tag, which upstream
  maintainers (or an attacker who compromises their account) can move to any
  commit at any time; the next workflow run then executes whatever is at the
  new commit with no diff-review step in this repository.
- **Impact:** on `ci.yml`/`quality.yml` this is bounded by their limited
  default token scope, but the same unpinned actions run inside `release.yml`
  under `contents: write`/`pull-requests: write` (see FINDING-BSC-02),
  meaning an upstream action compromise reaches a job that can publish
  releases and modify pull requests in this repository.
- **Suggested fix:** pin each `uses:` line to a full commit SHA (with a
  trailing version comment for readability), e.g.
  `actions/checkout@<sha> # v4.x.x`.

## Areas checked with no significant finding
- **Windows PDB-vs-exe artifact swap (the known AGENTS.md instance):** the
  current `release.yml:63` stages the artifact with an explicit
  `cp "zig-out/bin/${{ matrix.bin }}" "dist/${{ matrix.artifact }}"` (matrix
  supplies `bin: rec` / `bin: rec.exe` per target) rather than a `rec*` glob,
  and a `sanity: true` step (`release.yml:76-77`) runs the staged binary with
  `about` before upload for every target except the unemulatable
  `aarch64-linux-gnu.2.28`. The glob-based failure mode described in
  `AGENTS.md:141-142` does not reproduce against this code.
- **Linux static-linking regression (v3.1.0 mute-recording bug):** both
  `ci.yml:51-55` and `release.yml:70-74` run `file <artifact> | grep -q
  "dynamically linked"` on the Linux build before it can ship, which fails
  the job if `miniaudio`'s ALSA/PulseAudio `dlopen` backends would be
  unreachable from a statically linked binary.
- **`pull_request_target` usage:** none of the three workflows use
  `pull_request_target`; all pull-request-triggered jobs use `pull_request`,
  so untrusted fork PRs do not run with base-repo secrets or an elevated
  token via that specific vector (Sentrux's unrelated integrity gap in
  FINDING-BSC-01 still applies to `pull_request` itself).
- **Untrusted input interpolated into a `run:` step:** no workflow
  interpolates `github.event.pull_request.title/body`, branch names, or other
  attacker-controlled strings directly into a shell `run:` block; the only
  dynamic values used in `run:` are `matrix.*` entries defined in the
  workflow file itself and `needs.release-please.outputs.tag_name`, which
  release-please derives from `build.zig.zon`/conventional commits in this
  repo, not from PR-supplied text.
- **`build.zig` / `build.zig.zon` dependency graph:** `build.zig.zon` declares
  no `.dependencies` entries, and `build.zig` fetches nothing over the
  network — the only native dependency, `vendor/miniaudio.h`, is a
  version-controlled file in the repository, not something downloaded at
  configure or build time.
- **Git hooks (`githooks/pre-commit`, `githooks/commit-msg`):** the
  pre-commit secrets scan operates only on `git diff --cached` (the
  developer's own staged content) and the commit-msg hook only regex-checks
  its own `$1` message-file argument; neither hook takes a crafted filename
  or repository content as an argument that could be turned into command
  injection, and both explicitly exclude `githooks/**` from the secrets scan
  to avoid self-matching on the literal patterns rather than skipping
  real content.
- **E2E harness scripts run from CI (`e2e_transcribe.py`, `e2e_viewer.py`):**
  both build all fixtures (WAV bytes, markdown, HTTP responses) locally from
  literals inside the script and only ever invoke the binary the same CI job
  just built (`REC_TEST_BIN`/`prefix`-relative paths), so there is no point
  where CI-external or attacker-controlled data reaches a `subprocess.run`
  argument list or shell string.
