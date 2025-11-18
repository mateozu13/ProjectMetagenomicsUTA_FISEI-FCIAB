#!/usr/bin/env bash
set -euo pipefail

CONDA_DIR="/opt/conda"
ENV_NAME="qiime2"
ENV_PATH="${CONDA_DIR}/envs/${ENV_NAME}"
GROUP_NAME="research"

msg(){ echo -e "\n[INFO] $*"; }
err(){ echo -e "\n[ERROR] $*" >&2; exit 1; }

[[ $(id -u) -ne 0 ]] && err "Ejecuta como root (sudo)."
[[ ! -x "${CONDA_DIR}/bin/conda" ]] && err "No se encontró conda en ${CONDA_DIR}"

if [[ -f /etc/profile.d/conda.sh ]]; then
  source /etc/profile.d/conda.sh
else
  export PATH="${CONDA_DIR}/bin:${PATH}"
fi

msg "Eliminando entorno corrupto si existe..."
"${CONDA_DIR}/bin/conda" env remove -n "${ENV_NAME}" -y 2>/dev/null || true

msg "Instalando QIIME2 2024.10 desde archivo de ambiente YAML..."

# Crear archivo de ambiente con versiones EXACTAS de tu máquina funcional
cat > /tmp/qiime2-2024.10-env.yml <<'EOF'
name: qiime2
channels:
  - qiime2
  - conda-forge
  - bioconda
  - defaults
dependencies:
  - python=3.10.14
  - setuptools<81
  - click=8.1.7
  - qiime2=2024.10.1
  - q2cli=2024.10.1
  - q2-alignment=2024.10.0
  - q2-composition=2024.10.0
  - q2-cutadapt=2024.10.0
  - q2-dada2=2024.10.0
  - q2-demux=2024.10.0
  - q2-diversity=2024.10.0
  - q2-diversity-lib=2024.10.0
  - q2-emperor=2024.10.0
  - q2-feature-classifier=2024.10.0
  - q2-feature-table=2024.10.0
  - q2-metadata=2024.10.0
  - q2-phylogeny=2024.10.0
  - q2-quality-control=2024.10.0
  - q2-quality-filter=2024.10.0
  - q2-taxa=2024.10.0
  - q2-types=2024.10.0
  - q2-vsearch=2024.10.0
  - mafft
  - fasttree
  - pandas
  - plotly
EOF

msg "Creando entorno desde YAML..."
if "${CONDA_DIR}/bin/conda" run -n base mamba --version >/dev/null 2>&1; then
  "${CONDA_DIR}/bin/mamba" env create -f /tmp/qiime2-2024.10-env.yml
else
  "${CONDA_DIR}/bin/conda" env create -f /tmp/qiime2-2024.10-env.yml
fi

rm /tmp/qiime2-2024.10-env.yml

msg "Aplicando permisos..."
chown -R root:"${GROUP_NAME}" "${ENV_PATH}"
chmod -R g+rwX "${ENV_PATH}"
setfacl -R -m g:${GROUP_NAME}:rwx "${ENV_PATH}"
setfacl -R -d -m g:${GROUP_NAME}:rwx "${ENV_PATH}"

msg "Suprimiendo warnings..."
mkdir -p "${ENV_PATH}/etc/conda/activate.d"
cat > "${ENV_PATH}/etc/conda/activate.d/env_vars.sh" <<'EOF'
#!/bin/bash
export PYTHONWARNINGS="ignore::DeprecationWarning:pkg_resources"
EOF
chmod +x "${ENV_PATH}/etc/conda/activate.d/env_vars.sh"
chown root:"${GROUP_NAME}" "${ENV_PATH}/etc/conda/activate.d/env_vars.sh"

msg "Verificando instalación..."
source /etc/profile.d/conda.sh
conda activate "${ENV_NAME}"

qiime --version || err "qiime no funciona"
python --version
echo ""
qiime info

echo ""
msg "Probando comando problemático..."
qiime dada2 denoise-paired --help >/dev/null 2>&1 && echo "✓ dada2 funciona correctamente" || err "dada2 sigue fallando"

conda deactivate

echo ""
echo "=== INSTALACIÓN COMPLETADA ==="
echo "Prueba: conda activate qiime2 && qiime info"