FROM fedora:37

RUN dnf -y install \
    createrepo \
    debootstrap \
    devscripts \
    dpkg-dev \
    dialog \
    dnf-plugins-core \
    e2fsprogs \
    git \
    gnupg \
    make \
    perl-open \
    perl-Digest-MD5 \
    perl-Digest-SHA \
    psmisc \
    python2 \
    python3-pyyaml \
    python3-sh \
    rpm-build \
    rpm-sign \
    rpmdevtools \
    systemd-container \
    systemd-udev \
    wget \
    which

# the build system requires regular user with passwordless sudo access
RUN groupadd -g 1000 builder && \
    useradd -ms /bin/bash -u 1000 -g 1000 builder && \
    usermod -aG wheel builder && \
    sed -e 's/^%wheel/#%wheel/g' -e 's/^# %wheel/%wheel/g' -i /etc/sudoers

RUN git clone --depth=1 https://github.com/QubesOS/qubes-builder /builder && \
    chown -R builder:builder /builder
COPY builder.conf /builder/builder.conf
RUN su -c 'make -C /builder COMPONENTS=builder-rpm get-sources' - builder

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
