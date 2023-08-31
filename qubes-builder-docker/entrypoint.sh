#!/bin/bash

set -xe

fail() {
    echo "$@"
    exit 1
}

# make sure all input environment variables were provided to avoid cryptic
# failures
[ -n "$COMPONENT" ] || fail "\$COMPONENT is empty"
[ -n "$PATCH_START" ] || fail "\$PATCH_START is empty"
[ -n "$BASE_COMMIT" ] || fail "\$BASE_COMMIT is empty"
[ -n "$SPEC_PATTERN" ] || fail "\$SPEC_PATTERN is empty"

# prevent errors due to inconsistent ownership
git config --global --add safe.directory "$PWD"

# load dom0 cache
if [ -f /tmp/cache/dom0.tar ]; then
    rm -rf /builder/cache /builder/chroot-dom0-fc37
    tar -C /builder -xf /tmp/cache/dom0.tar
fi

# fetch component's sources
su -c "make -C /builder 'COMPONENTS=$COMPONENT' get-sources" - builder

# create a set of patches on top of component's base and integrate them into
# sources
patches=( $(git format-patch --start-number "$PATCH_START" "$BASE_COMMIT") )
specLines=$'\\\n\\\n# Intel TXT support patches'
set +x # less noise in build logs
for patch in "${patches[@]}"; do
    patchNum=${patch%%-*}
    specLines=$specLines$'\\\n'"Patch$patchNum: $patch"
done
set -x
chown builder:builder "${patches[@]}"
mv "${patches[@]}" "/builder/qubes-src/$COMPONENT/"
sed -i \
    "${SPEC_PATTERN}a${specLines}" \
    "/builder/qubes-src/$COMPONENT/${COMPONENT##*-}.spec.in"

# build the component
su -c "make -C /builder 'COMPONENTS=$COMPONENT' '$COMPONENT'" - builder

# move RPMs out of the container
rpms=( $(find "/builder/qubes-src/$COMPONENT/pkgs" -name '*.rpm') )
cp --verbose "${rpms[@]}" .

# store dom0 cache if we didn't load from it
if [ ! -f /tmp/cache/dom0.tar ]; then
    umount /builder/chroot-dom0-fc37/proc
    tar -C /builder -cf /tmp/cache/dom0.tar cache chroot-dom0-fc37
fi
