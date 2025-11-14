#!/usr/bin/env bash
#
# Instalación y configuración global de Miniconda para múltiples usuarios
# Rocky Linux 8.10 — /opt/conda — grupo colaborativo: research
# Deja conda en PATH del sistema, ACLs y canales globales (conda-forge, bioconda, defaults)
#
# Uso: sudo bash install_conda.sh

set -euo pipefail

# variables
CONDA_DIR="/opt/conda"
CONDA_INSTALLER_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
CONDA_INSTALLER="/tmp/miniconda.sh"
GROUP_NAME="research"
PROFILE_SNIPPET="/etc/profile.d/conda.sh"
GLOBAL_CONDARC_DIR="/etc/conda"
GLOBAL_CONDARC="${GLOBAL_CONDARC_DIR}/condarc"
CONDA_ENV_DIR="${CONDA_DIR}/envs"
CONDA_PKGS_DIR="${CONDA_DIR}/pkgs"

# functions
msg() { echo -e "\n[INFO] $*"; }
warn() { echo -e "\n[WARN] $*"; }
err() { echo -e "\n[ERROR] $*" >&2; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Ejecuta este script como root (sudo)."
  fi
}

install_prereqs() {
  msg "Instalando prerrequisitos via dnf…"
  dnf -y update
  dnf -y install wget bzip2 ca-certificates curl coreutils tar which \
                 sysstat dstat
                 git nano procps-ng findutils acl \
                 policycoreutils-python-utils >/dev/null
}

ensure_group() {
  if getent group "${GROUP_NAME}" >/dev/null; then
    msg "Grupo '${GROUP_NAME}' ya existe."
  else
    msg "Creando grupo '${GROUP_NAME}'…"
    groupadd "${GROUP_NAME}"
  fi
}

download_miniconda() {
  if [[ -x "${CONDA_DIR}/bin/conda" ]]; then
    msg "Conda ya parece instalado en ${CONDA_DIR}; omitiendo descarga."
    return
  fi
  msg "Descargando instalador Miniconda…"
  curl -fsSL "${CONDA_INSTALLER_URL}" -o "${CONDA_INSTALLER}"
}

install_miniconda() {
  if [[ -x "${CONDA_DIR}/bin/conda" ]]; then
    msg "Conda ya instalado en ${CONDA_DIR}."
    return
  fi
  msg "Instalando Miniconda en ${CONDA_DIR}…"
  bash "${CONDA_INSTALLER}" -b -p "${CONDA_DIR}"
  rm -f "${CONDA_INSTALLER}" || true
}

set_permissions_acls() {
  msg "Aplicando permisos, setgid y ACLs para grupo '${GROUP_NAME}'…"
  chown -R root:"${GROUP_NAME}" "${CONDA_DIR}"
  # Directorios: 2775 (rwxrwxr-x con setgid)
  find "${CONDA_DIR}" -type d -print0 | xargs -0 chmod 2775
  # Archivos: 664
  find "${CONDA_DIR}" -type f -print0 | xargs -0 chmod 664 || true
  chmod 775 "${CONDA_DIR}"

  # ACLs (lectura/escritura/ejecución para el grupo y como default)
  setfacl -R -m g:${GROUP_NAME}:rwx "${CONDA_DIR}"
  setfacl -R -d -m g:${GROUP_NAME}:rwx "${CONDA_DIR}"
}

write_profile_snippet() {
  msg "Creando ${PROFILE_SNIPPET}…"
  cat > "${PROFILE_SNIPPET}" <<'EOF'
export PATH=/opt/conda/bin:$PATH
export CONDA_ENVS_PATH=/opt/conda/envs
export CONDA_PKGS_DIRS=/opt/conda/pkgs
if [ -f /opt/conda/etc/profile.d/conda.sh ]; then
  . /opt/conda/etc/profile.d/conda.sh
fi
export CONDA_AUTO_ACTIVATE_BASE=false
umask 0002
EOF

  chmod 644 "${PROFILE_SNIPPET}"
}

write_global_condarc() {
  msg "Escribiendo configuración global de conda en ${GLOBAL_CONDARC}…"
  mkdir -p "${GLOBAL_CONDARC_DIR}"
  cat > "${GLOBAL_CONDARC}" <<EOF
channels:
  - conda-forge
  - bioconda
  - defaults
channel_priority: strict
auto_activate_base: false
ssl_verify: true
envs_dirs:
  - ${CONDA_ENV_DIR}
pkgs_dirs:
  - ${CONDA_PKGS_DIR}
EOF

  chown -R root:"${GROUP_NAME}" "${GLOBAL_CONDARC_DIR}"
  chmod 664 "${GLOBAL_CONDARC}"
  setfacl -m g:${GROUP_NAME}:rw "${GLOBAL_CONDARC}" || true

  mkdir -p "${CONDA_DIR}/.conda"
  ln -sf "${GLOBAL_CONDARC}" "${CONDA_DIR}/.condarc"
  chown -R root:"${GROUP_NAME}" "${CONDA_DIR}/.conda"
  chmod 775 "${CONDA_DIR}/.conda"
}

conda_init_and_mamba() {
  msg "Inicializando conda para bash a nivel sistema…"
  "${CONDA_DIR}/bin/conda" init bash || true

  if ! "${CONDA_DIR}/bin/conda" run -n base mamba --version >/dev/null 2>&1; then
    msg "Instalando mamba en 'base'…"
    # accept channels
    "${CONDA_DIR}/bin/conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    "${CONDA_DIR}/bin/conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
    
    # install mamba
    sudo "${CONDA_DIR}/bin/conda" install -n base -y mamba
  else
    msg "mamba ya está instalado en 'base'."
  fi
}

verify_summary() {
  msg "Verificación rápida…"
  # cargar PATH/funciones en esta shell actual
  # shellcheck disable=SC1091
  source "${PROFILE_SNIPPET}"

  echo "Conda version:"
  conda --version || err "conda no responde en PATH"
  echo "Mamba version:"
  mamba --version || warn "mamba no responde (verificar instalación en base)"

  echo
  echo "=== RESUMEN ==="
  echo "Conda dir:          ${CONDA_DIR}"
  echo "Grupo colaborativo: ${GROUP_NAME}"
  echo "Condarc global:     ${GLOBAL_CONDARC}"
  echo "Profile snippet:    ${PROFILE_SNIPPET}"
  echo
  echo "Para habilitar el grupo a un usuario existente:"
  echo "  usermod -aG ${GROUP_NAME} <usuario>   # cerrar sesión y volver a entrar"
  echo
  echo "Para crear un usuario y agregarlo al grupo ${GROUP_NAME}:"
  echo "  sudo useradd -m -g ${GROUP_NAME} <usuario>"
  echo "  sudo passwd <usuario>    # asignar una contraseña"
  echo
  echo "Crear un entorno compartido de prueba (como usuario del grupo ${GROUP_NAME}):"
  echo "  conda create -n test -y python=3.11"
  echo "  conda activate test && python -V"
  echo
}

main() {
  require_root
  install_prereqs
  ensure_group
  download_miniconda
  install_miniconda
  set_permissions_acls
  write_profile_snippet
  write_global_condarc
  conda_init_and_mamba
  verify_summary
  msg "Instalación y configuración de Conda completada."
}

main "$@"

