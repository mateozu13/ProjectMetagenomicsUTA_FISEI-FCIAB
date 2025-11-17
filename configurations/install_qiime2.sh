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
QIIME_SPECS=(
  "python=3.10.14"              # FIJADO a 3.10.14
  "setuptools<81"               # Evitar bug de pkg_resources
  "qiime2=2024.10"
  "q2cli=2024.10.1"
  "q2-dada2"
  "q2-metadata"
  "q2-phylogeny"
  "q2-feature-classifier"
  "q2-diversity"
  "q2-diversity-lib"
  "q2-taxa"
  "q2-composition"
  "q2-alignment"
  "q2-feature-table"
  "q2-cutadapt"
  "q2-demux"
  "q2-quality-filter"
  "q2-quality-control"
  "q2-vsearch"
  "q2-emperor"
  "q2-types"
  "mafft"
  "fasttree"
  "q2-fragment-insertion"
  "q2-longitudinal"
  "q2-sample-classifier"
  "q2-rescript"
)

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
  if [[ -f /etc/profile.d/conda.sh ]]; then
    source /etc/profile.d/conda.sh
  else
    export PATH="${CONDA_DIR}/bin:${PATH}"
  fi
}

create_env(){
  if [[ -d "${ENV_PATH}" ]]; then
    msg "El entorno ${ENV_NAME} ya existe en ${ENV_PATH}."
    msg "Actualizando/reinstalando con especificaciones exactas..."
    if "${CONDA_DIR}/bin/conda" run -n base mamba --version >/dev/null 2>&1; then
      CONDA_NO_PLUGINS=true "${CONDA_DIR}/bin/mamba" install -n "${ENV_NAME}" -y "${QIIME_CHANNELS[@]}" "${QIIME_SPECS[@]}"
    else
      CONDA_NO_PLUGINS=true "${CONDA_DIR}/bin/conda" install -n "${ENV_NAME}" -y "${QIIME_CHANNELS[@]}" "${QIIME_SPECS[@]}"
    fi
    return
  fi

  msg "Creando entorno ${ENV_NAME} con especificaciones exactas..."
  if "${CONDA_DIR}/bin/conda" run -n base mamba --version >/dev/null 2>&1; then
    CONDA_NO_PLUGINS=true "${CONDA_DIR}/bin/mamba" create -n "${ENV_NAME}" -y "${QIIME_CHANNELS[@]}" "${QIIME_SPECS[@]}"
  else
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

suppress_warnings(){
  msg "Configurando supresión de warnings de pkg_resources..."
  mkdir -p "${ENV_PATH}/etc/conda/activate.d"
  
  cat > "${ENV_PATH}/etc/conda/activate.d/env_vars.sh" <<'EOF'
#!/bin/bash
export PYTHONWARNINGS="ignore::DeprecationWarning:pkg_resources"
EOF
  
  chmod +x "${ENV_PATH}/etc/conda/activate.d/env_vars.sh"
  chown root:"${GROUP_NAME}" "${ENV_PATH}/etc/conda/activate.d/env_vars.sh"
}

verify(){
  msg "Instalando dependencias adicionales..."
  /opt/conda/bin/conda install -n qiime2 -c conda-forge pandas plotly -y

  msg "Verificando instalación de QIIME 2…"
  source /etc/profile.d/conda.sh 2>/dev/null || true
  conda activate "${ENV_NAME}"
  
  qiime --version || err "No se encontró 'qiime' en el entorno."
  
  echo ""
  echo "=========================================="
  echo "Información del entorno:"
  echo "=========================================="
  qiime info
  
  echo ""
  echo "Versión de Python:"
  python --version
  
  echo ""
  echo "Versión de setuptools:"
  python -c "import setuptools; print(f'setuptools: {setuptools.__version__}')"
  
  # Verificar plugins críticos
  echo ""
  echo "=========================================="
  echo "Verificando plugins críticos:"
  echo "=========================================="
  for plugin in phylogeny dada2 feature-classifier diversity taxa demux quality-filter; do
    if qiime $plugin --help &>/dev/null; then
      echo "  ✓ $plugin: OK"
    else
      echo "  ✗ $plugin: FALTA"
    fi
  done
  
  conda deactivate

  echo ""
  echo "=== INSTALACIÓN COMPLETADA ==="
  echo "Entorno:     ${ENV_NAME}"
  echo "Ubicación:   ${ENV_PATH}"
  echo "Grupo:       ${GROUP_NAME}"
  echo ""
  echo "Uso (para cualquier usuario del grupo ${GROUP_NAME}):"
  echo "  conda activate ${ENV_NAME}"
  echo "  qiime info"
  echo "  conda deactivate"
  echo ""
}

main(){
  require_root
  check_conda
  create_env
  permissions
  suppress_warnings
  verify
}

main "$@"