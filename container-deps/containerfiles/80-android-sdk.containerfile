# Linux SDK binaries from Google currently require x86_64.
# Source: https://developer.android.com/studio#command-tools
ARG ANDROID_CMDLINE_TOOLS=15859902
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
ARG ANDROID_ACCEPT_LICENSES=1
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_BUILD_TOOLS_VERSION=36.0.0
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS_VERSION}:${PATH}"

RUN test "${ANDROID_ACCEPT_LICENSES}" = 1 \
      || { echo 'Review the Android SDK license, then build with ANDROID_ACCEPT_LICENSES=1.' >&2; exit 1; }
RUN test "$(uname -m)" = x86_64 \
      || { echo 'The Android SDK profile requires Linux x86_64.' >&2; exit 1; }
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" /tmp/android-cli \
  && curl -fL --retry 3 \
    "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
    -o /tmp/android-cli.zip \
  && echo "${ANDROID_CMDLINE_TOOLS_SHA256}  /tmp/android-cli.zip" | sha256sum -c - \
  && unzip -q /tmp/android-cli.zip -d /tmp/android-cli \
  && mv /tmp/android-cli/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest" \
  && rm -rf /tmp/android-cli /tmp/android-cli.zip

RUN yes | "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="${ANDROID_HOME}" --licenses >/dev/null
RUN "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="${ANDROID_HOME}" \
    'platform-tools' "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" \
  && apksigner --version \
  && aapt2 version \
  && adb version
