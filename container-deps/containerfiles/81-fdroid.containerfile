# Keep F-Droid dependencies separate from both RPMs and project dependencies.
# Source: https://f-droid.org/docs/Installing_the_Server_and_Repo_Tools/
ARG FDROIDSERVER_VERSION=2.4.5
RUN python3 -m venv /opt/fdroid-venv \
  && /opt/fdroid-venv/bin/python -m pip install --no-cache-dir "fdroidserver==${FDROIDSERVER_VERSION}" \
  && /opt/fdroid-venv/bin/python -m pip check \
  && /opt/fdroid-venv/bin/fdroid --version

# Generic writable project environment; install the mounted project at runtime.
RUN python3 -m venv /opt/project-venv \
  && /opt/project-venv/bin/python -m pip install --no-cache-dir 'pytest>=8' 'setuptools>=75' wheel \
  && /opt/project-venv/bin/python -m pip check \
  && chown -R "${USERNAME}:${USERNAME}" /opt/project-venv
ENV VIRTUAL_ENV=/opt/project-venv
# Keep Google's sdkmanager ahead of fdroidserver's Python sdkmanager dependency.
ENV PATH="/opt/project-venv/bin:${PATH}:/opt/fdroid-venv/bin"
COPY --chmod=755 container-runtime/verify-fdroid-env /usr/local/bin/codex-verify-fdroid-env
RUN codex-verify-fdroid-env
