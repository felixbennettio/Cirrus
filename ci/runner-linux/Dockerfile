# A self-hosted GitHub Actions runner for Cirrus's Linux jobs (tests, the
# Linux and Android builds), with everything those jobs need. Ubuntu 22.04
# keeps the Linux build's glibc requirement as low as GitHub's runner did.
# See ci/RUNNERS.md.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git git-lfs jq unzip zip xz-utils file sudo tzdata openssh-client \
      python3 python3-venv python3-pip \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev libstdc++-12-dev \
      librsvg2-bin libglu1-mesa xvfb \
      openjdk-17-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# Android SDK: the command-line tools and accepted licences; Gradle fetches
# the platforms and build tools a build asks for.
ENV ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
ARG ANDROID_CMDLINE_TOOLS=13114758
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl -fsSL -o /tmp/tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
    && unzip -q /tmp/tools.zip -d /tmp/tools && mv /tmp/tools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" \
    && rm -rf /tmp/tools /tmp/tools.zip \
    && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > /dev/null \
    && "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platform-tools"
ENV PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# Go, for the licence server's tests.
ARG GO_VERSION=1.24.7
# https://golang.google.cn/dl where go.dev is unreachable.
ARG GO_DOWNLOAD=https://go.dev/dl
RUN curl -fsSL "${GO_DOWNLOAD}/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:$PATH"

# The runner itself, as an unprivileged user (sudo for the odd job step).
RUN useradd -m -s /bin/bash runner \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chown -R runner:runner "$ANDROID_HOME"
WORKDIR /home/runner/actions-runner
# The latest release unless RUNNER_VERSION is given; it updates itself later.
ARG RUNNER_VERSION=
RUN VERSION="${RUNNER_VERSION:-$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest | sed 's|.*/v||')}" \
    && echo "actions runner $VERSION" \
    && curl -fsSL "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-x64-${VERSION}.tar.gz" | tar -xz \
    && ./bin/installdependencies.sh \
    && chown -R runner:runner /home/runner
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
USER runner
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
