#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
DOCKER_VERSION="${DOCKER_VERSION:-}"

if [[ "${INSTALL_DOCKER}" != "true" ]]; then
  echo "Skipping Docker installation because INSTALL_DOCKER=${INSTALL_DOCKER}"
  exit 0
fi

echo "Installing Docker Engine"

# Install docker engine and supporting tooling. Plugins are optional but ship with upstream packages,
# so install them when available without failing the build if a plugin is missing in the channel.
DOCKER_PACKAGE="docker"
if [[ -n "${DOCKER_VERSION}" ]]; then
  DOCKER_PACKAGE="docker-${DOCKER_VERSION}"
fi

if ! sudo dnf install -y "${DOCKER_PACKAGE}"; then
  echo "Failed to install docker package via dnf" >&2
  exit 1
fi

# Install optional plugins when they are present in the repo.
for pkg in docker-buildx-plugin docker-compose-plugin; do
  if sudo dnf list --available "${pkg}" >/dev/null 2>&1; then
    sudo dnf install -y "${pkg}"
  fi
done

# Align docker group id with the value used by the upstream EKS AMIs to avoid collisions.
if ! getent group docker >/dev/null 2>&1; then
  sudo groupadd -og 1950 docker
fi

if ! id docker >/dev/null 2>&1; then
  sudo useradd --system --no-create-home --gid "$(getent group docker | cut -d: -f3)" docker
fi

sudo usermod -aG docker "${USER}"

sudo mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat <<'JSON' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "bridge": "none",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "10"
  },
  "live-restore": true,
  "max-concurrent-downloads": 10,
  "default-ulimits": {
    "memlock": {
      "Hard": -1,
      "Name": "memlock",
      "Soft": -1
    }
  }
}
JSON
fi

# Make sure systemd registers the unit and enables it for the next boot.
sudo systemctl daemon-reload
sudo systemctl enable docker

# Lock docker packages to the installed version to keep the AMI reproducible.
if [[ -n "${DOCKER_VERSION}" ]]; then
  sudo dnf versionlock "docker-${DOCKER_VERSION}"
else
  sudo dnf versionlock "docker-*"
fi

for pkg in docker-buildx-plugin docker-compose-plugin; do
  if sudo dnf list installed "${pkg}" >/dev/null 2>&1; then
    sudo dnf versionlock "${pkg}" || true
  fi
done

# Record the installed docker package version for diagnostics.
sudo mkdir -p /etc/eks
rpm -q --qf '%{VERSION}-%{RELEASE}\n' docker | sudo tee /etc/eks/docker-version.txt >/dev/null
