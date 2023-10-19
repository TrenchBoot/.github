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

| Parameter         | Type   | Req. | Def. | Description
| ---------         | ----   | ---- | ---- | -----------
| `qubes-component` | string | Yes  | -    | Name of QubesOS component as recognized by its build system.

Used by [TrenchBoot/qubes-antievilmaid][aem].

[qubes-builder-v2]: https://github.com/QubesOS/qubes-builderv2
[aem]: https://github.com/TrenchBoot/qubes-antievilmaid/blob/2b6b796e31789fca599986c9cfb0a3ceced5967d/.github/workflows/build.yml

## Usage

Full details can be found in [GitHub's documentation][workflow-docs] on
reusable workflows.  Below is just an example which should be sufficient when no
modifications to workflows are necessary.

[workflow-docs]: https://docs.github.com/en/actions/using-workflows/reusing-workflows

Create a workflow file like `.github/workflows/build.yml` inside of your
repository.  It will have 3 parts: name, triggering conditions and invocation
of one of the workflows defined here.  Let's use [TrenchBoot/xen][xen] as an
example.

### Name

```yaml
name: Test build and package QubesOS RPMs
```

Specify workflow title used for identification in UI.

### Triggering conditions

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

### Workflow invocation

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
