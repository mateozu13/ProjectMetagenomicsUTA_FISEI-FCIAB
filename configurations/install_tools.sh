#!/usr/bin/env bash
# Rocky Linux 8.10
# Crea entorno compartido "/opt/conda/envs/preproc" con:
# fastqc multiqc fastp cutadapt trimmomatic (java 11)
# También descarga clasificador Silva 138 para QIIME2

set -euo pipefail

# Variables
CONDA_DIR="/opt/conda"
ENV_NAME="preproc"
ENV_PATH="${CONDA_DIR}/envs/${ENV_NAME}"
GROUP_NAME="research"

# Clasificador Silva
SILVA_DIR="/home/proyecto/tools"
SILVA_QZA="${SILVA_DIR}/silva-138-99-nb-classifier.qza"
SILVA_URL="https://data.qiime2.org/classifiers/sklearn-1.4.2/silva/silva-138-99-nb-classifier.qza"

# Paquetes a instalar
PKGS=(
  "python=3.11"
  "fastqc"
  "multiqc"
  "fastp"
  "cutadapt"
  "trimmomatic"
  "openjdk=11"
)

# Funciones
msg(){ echo -e "\n[INFO] $*"; }
err(){ echo -e "\n[ERROR] $*" >&2; exit 1; }

require_root(){
  if [[ $(id -u) -ne 0 ]]; then
    err "Ejecuta este script como root (sudo)."
  fi
}

check_prereqs(){
  [[ -x "${CONDA_DIR}/bin/conda" ]] || err "No se encontró conda en ${CONDA_DIR}. Instala Miniconda global primero."
  if [[ -f /etc/profile.d/conda.sh ]]; then
    source /etc/profile.d/conda.sh
  else
    export PATH="${CONDA_DIR}/bin:${PATH}"
  fi
}

set_channel_priority(){
  msg "Asegurando channel_priority=strict (a nivel sistema)…"
  "${CONDA_DIR}/bin/conda" config --system --set channel_priority strict || true
}

create_env(){
  if [[ -d "${ENV_PATH}" ]]; then
    msg "El entorno ${ENV_NAME} ya existe en ${ENV_PATH}. Saltando creación."
    return
  fi

  if "${CONDA_DIR}/bin/conda" run -n base mamba --version >/dev/null 2>&1; then
    msg "Creando entorno ${ENV_NAME} con mamba…"
    "${CONDA_DIR}/bin/mamba" create -n "${ENV_NAME}" -y \
      -c conda-forge -c bioconda "${PKGS[@]}"
  else
    msg "mamba no disponible; usando conda…"
    "${CONDA_DIR}/bin/conda" create -n "${ENV_NAME}" -y \
      -c conda-forge -c bioconda "${PKGS[@]}"
  fi
}

set_permissions(){
  msg "Aplicando permisos/ACL para el grupo '${GROUP_NAME}'…"
  chown -R root:"${GROUP_NAME}" "${ENV_PATH}"
  chmod -R g+rwX "${ENV_PATH}"
  setfacl -R -m g:${GROUP_NAME}:rwx "${ENV_PATH}"
  setfacl -R -d -m g:${GROUP_NAME}:rwx "${ENV_PATH}"
}

install_silva_classifier(){
  msg "Verificando clasificador Silva en ${SILVA_QZA}…"
  if [[ -f "${SILVA_QZA}" ]]; then
    msg "Clasificador Silva ya existe. Saltando descarga."
    return
  fi

  msg "Descargando clasificador Silva 138 desde QIIME2…"
  mkdir -p "${SILVA_DIR}"
  wget -O "${SILVA_QZA}" "${SILVA_URL}" || err "Fallo la descarga del clasificador Silva."
  msg "Clasificador Silva descargado exitosamente."
}

verify(){
  msg "Verificando herramientas en el entorno ${ENV_NAME}…"
  source /etc/profile.d/conda.sh 2>/dev/null || true
  conda activate "${ENV_NAME}"

  fastqc --version || err "fastqc no responde"
  multiqc --version || err "multiqc no responde"
  fastp -v || err "fastp no responde"
  cutadapt --version || err "cutadapt no responde"
  trimmomatic -version || trimmomatic 2>&1 | head -n 5 || true

  conda deactivate

  echo
  echo "=== OK: entorno '${ENV_NAME}' listo ==="
  echo "Ubicación: ${ENV_PATH}"
  echo "Grupo:     ${GROUP_NAME}"
  echo
  echo "Uso (usuarios del grupo ${GROUP_NAME}):"
  echo "  conda activate ${ENV_NAME}"
}

main(){
  require_root
  check_prereqs
  set_channel_priority
  create_env
  set_permissions
  install_silva_classifier
  verify
}

main "$@"
