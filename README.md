# TrenchBoot/.github

This is an infrastructure repository of TrenchBoot organization meant to serve
as a storage for relatively generic CI workflows used by other repositories of
the organization.

## Structure

```
<root>
├── .github/workflows/ (path to reusable workflows dictated by GitHub)
│   ├── qubes-dom0-package.yml (workflow for v1 (Make) Qubes OS builder)
│   └── qubes-dom0-packagev2.yml (workflow for v2 (Python) Qubes OS builder)
└── qubes-builder-docker/ (container used by v1 workflow)
```

## Workflows

Both workflows do the following:

1. Checkout repository with package source.
2. Build or fetch from cache Docker container which is used in the next step.
3. Perform the build and produce Qubes OS packages (this is where workflows
   differ the most).
4. Upload built RPM files as CI artifacts.
5. If workflow was started by a tag push, a release on that tag is created to
   preserve artifacts indefinitely and make them available for download without
   logging into GitHub.  Release's body contains `wget` and `curl` commands
   which can be pasted into console to obtain the corresponding artifact.

### qubes-dom0-package

This workflow uses [Make-based Qubes OS builder][qubes-builder-v1] and works by
generating a set of patches for `qubes-component` starting from `base-commit`
which are then inserted into component's `*.spec.in` file to be picked up
during RPM build process.

This workflow is suitable for Qubes OS components which reference an upstream
release and provide a set of patches on top of it.  Other ("native") components
that contain sources along with packaging information should use
`qubes-dom0-packagev2` because patching isn't set up in their `*.spec.in` and
it wouldn't be able to affect files such as `*.spec.in` that get processed
before patching.

This workflow additionally caches dom0 chroot environment between successive
runs of the Docker container which somewhat reduces build time.

| Parameter         | Type   | Req. | Def. | Description
| ---------         | ----   | ---- | ---- | -----------
| `base-commit`     | string | Yes  | -    | First upstream commit to be used as a base for `git format-patch` command.
| `patch-start`     | number | Yes  | -    | `--start-number` argument for `git format-patch` command.
| `qubes-component` | string | Yes  | -    | Name of QubesOS component as recognized by its build system.
| `spec-pattern`    | string | Yes  | -    | `sed` pattern used to find insert position for patches in `*.spec.in` files.
| `spec-file`       | string | No   | `""` | Name used for `*.spec.in` file, if empty `qubes-component` is stripped from everything before the last dash (e.g. `vmm-xen` -> `xen`).  Extensions (`.spec.in`) are always added, don't specify them here.

Used by [TrenchBoot/xen][xen] and [TrenchBoot/grub][grub].

[qubes-builder-v1]: https://github.com/QubesOS/qubes-builder
[xen]: https://github.com/TrenchBoot/xen/blob/f703de3bbfbda2251f49abf8e50e5fb265a57e5a/.github/workflows/build.yml
[grub]: https://github.com/TrenchBoot/grub/blob/43998592dc8993d4c802f6c98f6eb73a5800853b/.github/workflows/build.yml

### qubes-dom0-packagev2

This workflow uses new (v2) [Python-based Qubes OS builder][qubes-builder-v2] and works by patching
builder configuration file (`builder.yml`) to use TrenchBoot's fork of the
package, hence significantly reduced set of parameters.

There is also no need to use `qubes-builder-docker/` in this case because
builder's repository contains its own Docker image.

| Parameter                | Type   | Req. | Def. | Description
| ---------                | ----   | ---- | ---- | -----------
| `qubes-component`        | string | Yes  | -    | Name of QubesOS component as recognized by its build system.
| `qubes-pkg-src-dir`      | string | No   | -    | Relative path to directory containing Qubes OS package.
| `qubes-pkg-version`      | string | No   | auto | Version for RPM packages
| `qubes-pkg-revision`     | string | No   | `1`  | Revision for RPM packages
| `qubes-component-branch` | string | No   | -    | Forced repository branch to build component from

[qubes-builder-v2]: https://github.com/QubesOS/qubes-builderv2
[aem]: https://github.com/TrenchBoot/qubes-antievilmaid/blob/2b6b796e31789fca599986c9cfb0a3ceced5967d/.github/workflows/build.yml
[skl]: https://github.com/TrenchBoot/secure-kernel-loader

### rebase

This workflow automates rebasing a downstream repository branch on top of an
upstream branch. On success, it pushes the rebased branch. If conflicts arise,
it opens a pull request against the downstream repository to ask for
resolution.

| Parameter              | Type   | Req. | Def. | Description
| ---------              | ----   | ---- | ---- | -----------
| `downstream-repo`      | string | Yes  | -    | URL of the repository to rebase (`<first_repo>` argument of `rebase.sh`).
| `downstream-branch`    | string | Yes  | -    | Branch in the downstream repository to rebase (`<first_repo_branch>` argument of `rebase.sh`).
| `upstream-repo`        | string | Yes  | -    | URL of the repository that provides the new base (`<second_repo>` argument of `rebase.sh`).
| `upstream-branch`      | string | Yes  | -    | Branch in the upstream repository to rebase onto (`<second_repo_branch>` argument of `rebase.sh`).
| `commit-user-name`     | string | Yes  | -    | Git author name used for rebase commits (`--commit-user-name` option of `rebase.sh`).
| `commit-user-email`    | string | Yes  | -    | Git author e-mail used for rebase commits (`--commit-user-email` option of `rebase.sh`).
| `cicd-trigger-resume`  | string | Yes  | -    | Human-readable message appended to the conflict PR describing how to resume the pipeline (`--cicd-trigger-resume` option of `rebase.sh`).
| `first-remote-token`   | string | Yes  | -    | Personal access token with permissions to fetch, branch, commit, push, and open/close PRs on `downstream-repo`. Passed as a GitHub Actions secret.

### trigger-woodpecker-pipeline

This workflow is a generic wrapper for the woodpecker-trigger.sh script for
triggering Woodpecker CI/CD pipelines on some remote Woodpecker instance. As for
now it is used only for triggering the pipelines for signing RPM packages built
by the `qubes-dom0-package` and `qubes-dom0-packagev2` workflows.

| Parameter           | Type   | Req. | Def.     | Description
| ---------           | ----   | ---- | ----     | -----------
| `api-url`           | string | Yes  | -        | Base URL of the Woodpecker instance, e.g. `https://ci.example.com`.
| `owner`             | string | Yes  | -        | Repository owner (user or organization).
| `repo`              | string | Yes  | -        | Repository name.
| `ref`               | string | No   | `main`   | Branch to trigger the pipeline on.
| `inputs`            | string | No   | -        | Additional `--input KEY=VALUE` flags passed to `woodpecker-trigger.sh`. Keys must be valid shell variable names (no hyphens).
| `woodpecker-token`  | string | Yes  | -        | Woodpecker API token for authentication. Passed as a GitHub Actions secret.

## Usage

Full details can be found in [GitHub's documentation][workflow-docs] on
reusable workflows.  Below is just an example which should be sufficient when no
modifications to workflows are necessary.

[workflow-docs]: https://docs.github.com/en/actions/using-workflows/reusing-workflows

### qubes-dom0-package or qubes-dom0-packagev2

Create a workflow file like `.github/workflows/build.yml` inside of your
repository.  It will have 3 parts: name, triggering conditions and invocation
of one of the workflows defined here.  Let's use [TrenchBoot/grub][grub] as an
example.

#### Name

```yaml
name: Test build and package QubesOS RPMs
```

Specify workflow title used for identification in UI.

#### Triggering conditions

```yaml
on:
  push:
    branches:
      - 'intel-txt-aem*'
    tags:
      - '*'
```

Activate this workflow on push of any tag or a branch which starts with
`intel-txt-aem` (including this branch, i.e. `*` can expand to an empty string).

#### Workflow invocation

```yaml
jobs:
  qubes-dom0-package:
    uses: TrenchBoot/.github/.github/workflows/qubes-dom0-package.yml@master
    with:
      base-commit: 'ae94b97be2b81b625d6af6654d3ed79078b50ff6'
      patch-start: 1100
      qubes-component: 'grub2'
      spec-pattern: '/^Patch1001:/'
```

Invoke v1 workflow from `master` branch of this repository with the set of
parameters as described in a section above.

### rebase

`rebase` is typically one job in a larger workflow that first prepares the
upstream branch to rebase onto, then calls this workflow, and finally cleans up
any temporary branches.

#### Triggering conditions

There is no specific trigger condition that can be used to trigger pipelines
that contain this reusable workflow. So the developer is free to decide. But
there is one case: if the workflow that uses this reusable workflow has a
condition on push event, then the token provided via `first-remote-token` should
not have permissions to trigger CI/CDs. This is because the script used inside
this reusable workflow pushes to the remote repository several times.

#### Workflow invocation

```yaml
name: Rebase on top of QubesOS main

on:
  workflow_dispatch:
  schedule:
    - cron: '0 0 * * 6'

jobs:
  try-rebase:
    uses: TrenchBoot/.github/.github/workflows/rebase.yml@master
    secrets:
      first-remote-token: ${{secrets.TRENCHBOOT_REBASE_TOKEN}}
    permissions:
      # For creation/deletion/pushing to branches and creating PRs
      contents: write
    with:
      downstream-repo: 'https://github.com/DaniilKl/qubes-antievilmaid.git'
      downstream-branch: 'main'
      upstream-repo: 'https://github.com/QubesOS/qubes-antievilmaid.git'
      upstream-branch: 'main'
      commit-user-name: 'github-actions[bot]'
      commit-user-email: 'github-actions[bot]@users.noreply.github.com'
      cicd-trigger-resume: '7. Rerun the workflow https://github.com/DaniilKl/qubes-antievilmaid/actions/runs/${{ github.run_id }} to resume automated rebase.'
```

### trigger-woodpecker-pipeline

`trigger-woodpecker-pipeline` is meant to be added as an additional job to an
existing workflow, chained after a `qubes-dom0-package` or `qubes-dom0-packagev2`
job.

#### Workflow invocation

An example invocation:

```yaml
jobs:
  qubes-dom0-package:
    needs: get-version
    uses: TrenchBoot/.github/.github/workflows/qubes-dom0-packagev2.yml@master
    with:
      qubes-component: 'vmm-xen'
      qubes-component-branch: 'aem-next-rebased'
      qubes-pkg-src-dir: '.'
      qubes-pkg-version: '4.19.4'
  trigger-woodpecker-cicd:
    needs: qubes-dom0-package
    uses: TrenchBoot/.github/.github/workflows/trigger-woodpecker-pipeline.yml@master
    secrets:
      woodpecker-token: ${{ secrets.WOODPECKER_TOKEN }}
    with:
      api-url: 'https://ci.3mdeb.com'
      owner:   'zarhus'
      repo:    'trenchboot-release-cicd-pipeline'
      ref:     'master'
      inputs: >-
        --input GITHUB_REPO=xen
        --input GITHUB_SHA=${{ github.sha }}
        --input GITHUB_RUN_ID=${{ github.run_id }}
        --input QUBES_COMPONENT=vmm-xen
        --input WORKFLOW=sign-and-publish-test-rpms
```

Invokes the workflow from `master` branch of this repository after the
`qubes-dom0-package` job completes.  Pass the Woodpecker API token from the
repository's GitHub secrets, point it at the target Woodpecker instance
and repository, and supply any pipeline-specific key/value pairs via repeated
`--input` flags.

Note, that all the inputs to the `trigger-woodpecker-pipeline.yml` except from
the `inputs` serve for the purpose of connection to the desired Woodpecker
instance on which a pipeline for signing is running. But the data provided via
`inputs` input and `--input` flag is consumed by the signing pipeline itself.
One must specify the name of the signing pipeline via `--input WORKFLOW=` and
all the input data the specified pipeline requires. The above example presents
the required inputs for the `sign-and-publish-test-rpms` pipeline.

## Funding

This project was partially funded through the
[NGI Assure](https://nlnet.nl/assure) Fund, a fund established by
[NLnet](https://nlnet.nl/) with financial support from the European
Commission's [Next Generation Internet](https://ngi.eu/) programme, under the
aegis of DG Communications Networks, Content and Technology under grant
agreement No 957073.

<p align="center">
<img src="https://nlnet.nl/logo/banner.svg" height="75">
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<img src="https://nlnet.nl/image/logos/NGIAssure_tag.svg" height="75">
</p>
