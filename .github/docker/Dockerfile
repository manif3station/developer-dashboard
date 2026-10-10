# BuildKit builds this Linux image for linux/amd64 and linux/arm64. Docker does
# not publish macOS-kernel container images; Apple Silicon uses the arm64 Linux
# variant through Docker Desktop's Linux VM.
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

ARG DIST_VERSION
LABEL org.opencontainers.image.title="Developer Dashboard" \
      org.opencontainers.image.description="Developer Dashboard CLI built from the latest master source" \
      org.opencontainers.image.version="${DIST_VERSION}" \
      org.opencontainers.image.source="https://github.com/manif3station/developer-dashboard"

ENV PERL_LOCAL_LIB_ROOT=/root/perl5 \
    PERL5LIB=/root/perl5/lib/perl5 \
    PATH=/root/perl5/bin:${PATH}

WORKDIR /workspace
COPY . /workspace

# Run the repository installer against the checked-out master tree, install
# Dist::Zilla and the plugins used by dist.ini, build that tree's tarball, and
# install the exact archive into the runtime image. This avoids a stale
# MetaCPAN version becoming the final image payload.
# install.sh's default source-checkout branch invokes cpanm on the repository
# root before Dist::Zilla has built its Makefile.PL. Bootstrap its runtime using
# the published distribution, then replace it below with this checkout's archive.
RUN DD_INSTALL_CPAN_TARGET=Developer::Dashboard ./install.sh

RUN cpanm --notest --local-lib=/root/perl5 \
       Dist::Zilla \
       Dist::Zilla::Plugin::ManifestSkip \
       Dist::Zilla::Plugin::MetaProvides::Package \
       Dist::Zilla::Plugin::PkgVersion \
       Dist::Zilla::Plugin::ShareDir \
       File::ShareDir::Install

RUN source_version="$(awk -F ' = ' '$1 == "version" { print $2; exit }' dist.ini)" \
    && test "${source_version}" = "${DIST_VERSION}" \
    && dzil build

RUN archive="Developer-Dashboard-${DIST_VERSION}.tar.gz" \
    && test -f "${archive}" \
    && cpanm --verbose --reinstall --local-lib=/root/perl5 "${archive}" \
    && rm -rf /workspace

WORKDIR /root
EXPOSE 7890
ENTRYPOINT ["d2"]
