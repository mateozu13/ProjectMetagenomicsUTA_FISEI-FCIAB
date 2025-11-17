#!/usr/bin/env bash
#
# Instalar QIIME 2 (2024.10) en un entorno COMPARTIDO
# Ubicación: /opt/conda/envs/qiime2  | Grupo colaborativo: research
# Requisitos previos:
#   - Miniconda global en /opt/conda
#   - Grupo "research" existente y usuarios añadidos a ese grupo
#
# Uso: sudo bash install_qiime2.sh

set -euo pipefail

# variables
CONDA_DIR="/opt/conda"
ENV_NAME="qiime2"
ENV_PATH="${CONDA_DIR}/envs/${ENV_NAME}"
GROUP_NAME="research"
QIIME_CHANNELS=(-c qiime2 -c conda-forge -c bioconda)
QIIME_SPECS=("qiime2=2024.10" "q2cli" "q2-dada2" "q2-metadata")

# functions
msg(){ echo -e "\n[INFO] $*"; }
err(){ echo -e "\n[ERROR] $*" >&2; exit 1; }

require_root(){
  if [[ $(id -u) -ne 0 ]]; then
    err "Ejecuta como root (sudo)."
  fi
}

check_conda(){
  if [[ ! -x "${CONDA_DIR}/bin/conda" ]]; then
    err "No se encontró conda en ${CONDA_DIR}. Instalar Miniconda global primero."
  fi
  # carga funciones conda en esta shell
  if [[ -f /etc/profile.d/conda.sh ]]; then
    source /etc/profile.d/conda.sh
  else
    export PATH="${CONDA_DIR}/bin:${PATH}"
  fi
}

create_env(){
  if [[ -d "${ENV_PATH}" ]]; then
    msg "El entorno ${ENV_NAME} ya existe en ${ENV_PATH}."
    return
  fi

  if "${CONDA_DIR}/bin/conda" run -n base mamba --version >/dev/null 2>&1; then
    msg "Creando entorno ${ENV_NAME} con mamba…"
    CONDA_NO_PLUGINS=true "${CONDA_DIR}/bin/mamba" create -n "${ENV_NAME}" -y "${QIIME_CHANNELS[@]}" "${QIIME_SPECS[@]}"
  else
    msg "mamba no disponible; usando conda…"
    CONDA_NO_PLUGINS=true "${CONDA_DIR}/bin/conda" create -n "${ENV_NAME}" -y "${QIIME_CHANNELS[@]}" "${QIIME_SPECS[@]}"
  fi
}

permissions(){
  msg "Aplicando permisos multiusuario para el grupo '${GROUP_NAME}'…"
  chown -R root:"${GROUP_NAME}" "${ENV_PATH}"
  chmod -R g+rwX "${ENV_PATH}"
  setfacl -R -m g:${GROUP_NAME}:rwx "${ENV_PATH}"
  setfacl -R -d -m g:${GROUP_NAME}:rwx "${ENV_PATH}"
}

verify(){
  # Instalar dependencias de python
  msg "Instalando dependencias python en el entorno de QIIME 2…"
  /opt/conda/bin/conda install -n qiime2 -c conda-forge pandas plotly

  msg "Verificando instalación de QIIME 2…"
  source /etc/profile.d/conda.sh 2>/dev/null || true
  conda activate "${ENV_NAME}"
  
  qiime --version || err "No se encontró 'qiime' en el entorno."
  qiime info | head -n 15
  conda deactivate

  echo
  echo "=== OK ==="
  echo "Entorno:     ${ENV_NAME}"
  echo "Ubicación:   ${ENV_PATH}"
  echo "Grupo:       ${GROUP_NAME}"
  echo
  echo "Uso (para cualquier usuario del grupo ${GROUP_NAME}):"
  echo "  conda activate ${ENV_NAME}"
  echo "  qiime info"
  echo "  conda deactivate    # salir del env"
  echo
}

main(){
  require_root
  check_conda
  create_env
  permissions
  verify
}

main "$@"

