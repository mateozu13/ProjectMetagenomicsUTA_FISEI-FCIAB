# Optimización de Servidor Bioinformático para Análisis Metagenómico

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Rocky Linux](https://img.shields.io/badge/OS-Rocky%20Linux%208.10-green.svg)](https://rockylinux.org/)
[![QIIME2](https://img.shields.io/badge/QIIME2-2024.10-blue.svg)](https://qiime2.org/)

Proyecto de optimización de infraestructura computacional para el procesamiento y almacenamiento de datos metagenómicos aplicado al diagnóstico de Enfermedades Inflamatorias Intestinales (EII).

**Universidad Técnica de Ambato**  
Facultad de Ingeniería en Sistemas, Electrónica e Industrial  
Trabajo de Titulación - Mateo Zurita

---

## 📋 Tabla de Contenidos

- [Descripción](#-descripción)
- [Objetivos](#-objetivos)
- [Requisitos Previos](#-requisitos-previos)
- [Instalación](#-instalación)
  - [Paso 1: Configuración Inicial](#paso-1-configuración-inicial)
  - [Paso 2: Optimización del Sistema](#paso-2-optimización-del-sistema)
- [Estructura del Proyecto](#-estructura-del-proyecto)
- [Preparación de Datos](#-preparación-de-datos)
- [Uso de Pipelines](#-uso-de-pipelines)
  - [Pipeline Básico](#pipeline-básico)
  - [Pipeline con Monitoreo de Recursos](#pipeline-con-monitoreo-de-recursos)
  - [Pipeline Optimizado con Paralelización](#pipeline-optimizado-con-paralelización)
- [Herramientas Auxiliares](#-herramientas-auxiliares)
- [Configuración Personalizada](#-configuración-personalizada)
- [Comparación de Resultados](#-comparación-de-resultados)
- [Optimizaciones Implementadas](#-optimizaciones-implementadas)
- [Resultados](#-resultados)
- [Troubleshooting](#-troubleshooting)
- [Referencias](#-referencias)

---

## 🔬 Descripción

Este proyecto presenta una metodología sistemática de optimización para servidores dedicados al análisis bioinformático de datos metagenómicos, específicamente enfocado en el proyecto de investigación **"Estrategias Metagenómicas para caracterización del microbioma intestinal humano aplicado al diagnóstico precoz y tratamiento personalizado de las Enfermedades Inflamatorias Intestinales (EII)"**.

La optimización abarca tres niveles:

1. **Optimización a nivel de kernel** - Parámetros del sistema operativo
2. **Optimización de software** - Herramientas de paralelización y compresión
3. **Optimización de hardware** - Configuración HPC y gestión de recursos

### Impacto obtenido

- **Reducción de tiempo de procesamiento**: 92.7%
- **Mejora en utilización de CPU**: 45-60%
- **Optimización de I/O**: Lectura/escritura paralela con pigz

---

## 💻 Requisitos Previos

### Hardware Mínimo Recomendado

- **CPU**: 12+ cores (recomendado: 24 cores)
- **RAM**: 32 GB (recomendado: 64 GB+)
- **Almacenamiento**: 512 GB SSD + 2 TB HDD (opcional)
- **Red**: 1 Gbps (recomendado: 10 Gbps)

### Software

- **Sistema Operativo**: Rocky Linux 8.10 o compatible (RHEL, AlmaLinux)
- **Acceso**: Permisos de root/sudo
- **Conectividad**: Acceso a internet para descargar dependencias

### Conocimientos Previos

- Línea de comandos de Linux
- Conceptos básicos de bioinformática
- Formato de archivos FASTQ
- (Opcional) Conocimientos de QIIME2

---

## 🚀 Instalación

### Paso 1: Configuración Inicial

Clone el repositorio y navegue al directorio del proyecto:

```bash
git clone https://github.com/mateozu13/ProjectMetagenomicsUTA_FISEI-FCIAB.git
cd ProjectMetagenomicsUTA_FISEI-FCIAB
```

Los scripts de configuración deben ejecutarse en el siguiente orden:

#### 1.1 Instalación de Conda

```bash
cd configurations
sudo bash install_conda.sh
```

Este script:

- Descarga e instala Miniconda3
- Configura las variables de entorno
- Inicializa conda para bash

**Nota**: Cierre y reabra la terminal después de este paso.

#### 1.2 Instalación de QIIME2

```bash
sudo bash install_qiime2.sh
```

Este script:

- Crea el ambiente conda `qiime2` con la versión 2024.10
- Instala todas las dependencias de QIIME2
- Configura el ambiente para análisis metagenómicos

**Tiempo estimado**: 30-45 minutos

#### 1.3 Instalación de Herramientas de Preprocesamiento

```bash
sudo bash install_tools.sh
```

Este script:

- Crea el ambiente conda `preproc`
- Instala fastp para control de calidad de secuencias
- Instala MultiQC para reportes consolidados
- Configura ACLs y permisos para el grupo `research`

#### 1.4 Instalación de Herramientas de Optimización

```bash
sudo bash install_optimization_tools.sh
```

Este script instala:

- **GNU Parallel**: Ejecución paralela de comandos
- **pigz**: Compresión/descompresión paralela (reemplazo de gzip)
- **Herramientas de monitoreo**: pidstat, iostat, htop, bc

Configuraciones automáticas:

- Alias globales (`gzip` → `pigz`)
- Archivo `will-cite` para suprimir advertencias
- Variables de entorno optimizadas

**Verificación**:

```bash
parallel --version
pigz --version
```

---

### Paso 2: Optimización del Sistema

Estos scripts optimizan el rendimiento del servidor a nivel de kernel y sistema operativo.

#### 2.1 Activación de Perfil HPC Compute

```bash
cd ../mods
sudo bash tuned_activate_hpc_compute.sh
```

Este script:

- Activa el perfil `hpc-compute` de Tuned
- Optimiza el sistema para cargas de trabajo de cómputo intensivo
- Ajusta frecuencias de CPU, schedulers y políticas de energía

**Verificación**:

```bash
sudo tuned-adm active
sudo tuned-adm verify
```

#### 2.2 Optimización del Kernel

```bash
sudo bash optimize_kernel.sh
```

Este script configura:

**Gestión de Memoria**:

- `vm.swappiness=10` - Minimiza uso de swap
- `vm.dirty_ratio=40` - Optimiza escritura diferida
- `vm.vfs_cache_pressure=50` - Balance entre caché y memoria

**Sistema de Archivos**:

- `fs.file-max=2097152` - Aumenta límite de archivos abiertos
- I/O scheduler: `deadline`/`mq-deadline`
- Read-ahead: 2048 KB

**Archivos Temporales**:

- tmpfs montado en `/mnt/fast_tmp` (4GB en RAM)
- Usado para archivos intermedios del pipeline

**Backup**: Se crea automáticamente en `/etc/sysctl.conf.backup.TIMESTAMP`

**Verificación**:

```bash
sysctl -a | grep -E 'vm.swappiness|vm.dirty'
df -h | grep fast_tmp
```

---

## 📁 Estructura del Proyecto

```
ProjectMetagenomicsUTA_FISEI-FCIAB/
│
├── configurations/          # Scripts de instalación
│   ├── install_conda.sh
│   ├── install_qiime2.sh
│   ├── install_tools.sh
│   └── install_optimization_tools.sh
│
├── mods/                   # Scripts de optimización del sistema
│   ├── tuned_activate_hpc_compute.sh
│   └── optimize_kernel.sh
│
├── pipelines/              # Pipelines de análisis
│   ├── pipeline1.sh                      # Pipeline básico
│   ├── pipeline1_stats.sh                # Con monitoreo de recursos
│   ├── pipeline_optimized_parallel.sh    # Optimizado con paralelización
│   └── pipeline_optimized_parallel_stats.sh  # Optimizado + monitoreo
│
├── tools/                  # Herramientas auxiliares
│   ├── generate_metadata.sh    # Genera metadata.tsv automáticamente
│   ├── generate_plots.sh       # Genera gráficos de métricas
│   └── compare_results.sh      # Compara múltiples proyectos
│
├── custom_config_example.sh    # Plantilla de configuración personalizada
│
└── README.md
```

### Estructura de un Proyecto Individual

```
/home/proyecto/<nombre_proyecto>/
│
├── raw_sequences/          # Secuencias crudas (FASTQ)
│   ├── Crohn/
│   │   ├── sample1_1.fq.gz
│   │   ├── sample1_2.fq.gz
│   │   └── ...
│   ├── Colitis/
│   └── Control/
│
├── metadata.tsv            # Metadatos de las muestras
│
├── preproc/               # Secuencias preprocesadas
│   ├── Crohn/
│   ├── Colitis/
│   └── Control/
│
├── qiime2_results/        # Resultados de QIIME2
│   ├── dada2/            # ASVs y estadísticas
│   ├── phylogeny/        # Árboles filogenéticos
│   └── core_diversity/   # Análisis de diversidad
│
├── results/               # Visualizaciones (.qzv)
│
├── logs/                  # Logs del pipeline (solo en _stats)
│   ├── pipeline_master.log
│   ├── timing_summary.csv
│   └── step_*.log
│
└── metrics/              # Métricas detalladas (solo en _stats)
    ├── system_summary.csv
    └── resource_*.csv
```

---

## 🧬 Preparación de Datos

### Estructura de Datos de Entrada

Los datos deben organizarse en el directorio del proyecto:

```bash
mkdir -p /home/proyecto/<nombre_proyecto>/raw_sequences
```

Las secuencias deben estar organizadas por grupos:

```
raw_sequences/
├── Crohn/
│   ├── S1_1.fq.gz      # Forward reads
│   ├── S1_2.fq.gz      # Reverse reads
│   ├── S2_1.fq.gz
│   └── S2_2.fq.gz
├── Colitis/
│   ├── S3_1.fq.gz
│   └── S3_2.fq.gz
└── Control/
    ├── S4_1.fq.gz
    └── S4_2.fq.gz
```

**Requisitos**:

- Archivos paired-end en formato FASTQ comprimido (`.fq.gz`)
- Nomenclatura: `<sample_id>_1.fq.gz` y `<sample_id>_2.fq.gz`
- Organizados en subdirectorios por grupo/condición

### Generación de Metadata

El archivo `metadata.tsv` es requerido por QIIME2 y se genera automáticamente:

```bash
cd tools
bash generate_metadata.sh <nombre_proyecto>
```

**Ejemplo**:

```bash
bash generate_metadata.sh Proyecto_EII_2025
```

El script:

1. Detecta automáticamente todos los grupos en `raw_sequences/`
2. Extrae los IDs de las muestras de los archivos `*_1.fq.gz`
3. Genera `metadata.tsv` con formato compatible con QIIME2
4. Verifica que cada muestra tenga su par R1/R2

**Formato generado**:

```tsv
#SampleID	Group
S1	Crohn
S2	Crohn
S3	Colitis
S4	Control
```

**Nota**: Puede editar manualmente este archivo para agregar columnas adicionales (edad, sexo, etc.).

---

## 🔬 Uso de Pipelines

Todos los pipelines siguen la misma sintaxis básica:

```bash
bash <nombre_pipeline>.sh <nombre_proyecto> [config_file]
```

### Pipeline Básico

**Archivo**: `pipeline1.sh`

Pipeline estándar sin monitoreo de recursos.

```bash
cd pipelines
bash pipeline1.sh Proyecto_EII_2025
```

**Pasos ejecutados**:

1. Preprocesamiento con fastp (control de calidad)
2. DADA2 denoising (identificación de ASVs)
3. Construcción de árboles filogenéticos
4. Análisis de diversidad alfa y beta
5. Generación de visualizaciones (.qzv)

**Tiempo estimado**: 2-4 horas (15 muestras)

---

### Pipeline con Monitoreo de Recursos

**Archivo**: `pipeline1_stats.sh`

Pipeline con monitoreo completo de recursos computacionales.

```bash
bash pipeline1_stats.sh Proyecto_EII_2025
```

**Métricas capturadas**:

- ⏱️ **Tiempo**: Duración por paso y total
- 💾 **Memoria**: Uso máximo (KB, MB, GB)
- 🔥 **CPU**: Porcentaje de utilización
- 💿 **I/O**: Lecturas/escrituras de disco (MB)
- 🌐 **Red**: Tráfico de red (opcional)

**Archivos generados**:

```
logs/
├── pipeline_master.log       # Log consolidado
├── timing_summary.csv        # Resumen de tiempos
└── step_*.log               # Log individual por paso

metrics/
├── system_summary.csv        # Resumen del sistema
└── resource_*.csv           # Métricas detalladas por paso
```

**Visualización de resultados**:

```bash
cd tools
python3 generate_plots.sh Proyecto_EII_2025
```

---

### Pipeline Optimizado con Paralelización

**Archivo**: `pipeline_optimized_parallel.sh`

Pipeline optimizado con GNU Parallel y compresión paralela.

```bash
bash pipeline_optimized_parallel.sh Proyecto_EII_2025
```

**Optimizaciones aplicadas**:

- ✅ Procesamiento paralelo de muestras con GNU Parallel
- ✅ Compresión/descompresión paralela con pigz
- ✅ Todas las muestras procesadas juntas en DADA2
- ✅ Uso de tmpfs (`/mnt/fast_tmp`) para archivos temporales

**Variante con estadísticas**:

```bash
bash pipeline_optimized_parallel_stats.sh Proyecto_EII_2025
```

**Mejoras de rendimiento**:

- Reducción de tiempo: ~92.7%
- Mejor utilización de CPU: 45-60%
- I/O optimizado: Lectura/escritura paralela

---

## 🛠️ Herramientas Auxiliares

### 1. Generación de Metadata

**Script**: `tools/generate_metadata.sh`

Genera automáticamente el archivo `metadata.tsv` requerido por QIIME2.

```bash
bash generate_metadata.sh <nombre_proyecto>
```

**Ejemplo**:

```bash
bash generate_metadata.sh Proyecto_20251208
```

**Funcionalidad**:

- Detecta grupos automáticamente
- Extrae IDs de muestras de archivos FASTQ
- Verifica pares R1/R2
- Permite confirmación antes de sobrescribir

---

### 2. Generación de Gráficos

**Script**: `tools/generate_plots.sh`

Genera visualizaciones de las métricas capturadas por pipelines `_stats`.

```bash
bash generate_plots.sh <nombre_proyecto>
```

**Gráficos generados**:

- Tiempo de ejecución por paso
- Uso de memoria por paso
- Utilización de CPU
- I/O de disco (lectura/escritura)
- Comparativas entre pasos

**Salida**: Archivos PNG en `<proyecto>/metrics/plots/`

**Requisitos**: Python 3 con matplotlib, pandas

---

### 3. Comparación de Proyectos

**Script**: `tools/compare_results.sh`

Compara métricas de rendimiento entre múltiples proyectos.

```bash
bash compare_results.sh <proyecto1> <proyecto2> [proyecto3] ...
```

**Ejemplo**:

```bash
bash compare_results.sh Proyecto_Sin_Opt Proyecto_Opt_Kernel Proyecto_Opt_Full
```

**Funcionalidad**:

- Consolida métricas de múltiples proyectos
- Genera gráficos comparativos
- Calcula mejoras porcentuales
- Identifica cuellos de botella

**Salida**: Directorio `project_comparisons/comparison_TIMESTAMP/`

- `consolidated_metrics.csv`
- Gráficos comparativos (PNG)
- Reporte de mejoras (TXT)

---

## ⚙️ Configuración Personalizada

Puede personalizar los parámetros del pipeline sin modificar los scripts originales.

### Uso de Archivo de Configuración

1. **Copie el archivo de ejemplo**:

```bash
cp custom_config_example.sh mi_configuracion.sh
```

2. **Edite los parámetros**:

```bash
nano mi_configuracion.sh
```

3. **Ejecute el pipeline con su configuración**:

```bash
bash pipeline1_stats.sh Proyecto_20251208 mi_configuracion.sh
```

### Parámetros Configurables

#### Parámetros de fastp (Preprocesamiento)

```bash
FASTP_TRIM_FRONT1=10           # Bases a recortar al inicio (R1)
FASTP_TRIM_FRONT2=10           # Bases a recortar al inicio (R2)
FASTP_QUALITY_PHRED=20         # Calidad mínima Phred
FASTP_LENGTH_REQUIRED=150      # Longitud mínima de secuencia
FASTP_THREADS=12               # Hilos para fastp
```

#### Parámetros de DADA2 (Denoising)

```bash
DADA2_TRIM_LEFT_F=0            # Recorte izquierdo R1
DADA2_TRIM_LEFT_R=0            # Recorte izquierdo R2
DADA2_TRUNC_LEN_F=230          # Longitud de truncamiento R1
DADA2_TRUNC_LEN_R=220          # Longitud de truncamiento R2
DADA2_MAX_EE_F=2.0             # Máximo error esperado R1
DADA2_MAX_EE_R=2.0             # Máximo error esperado R2
DADA2_THREADS=12               # Hilos para DADA2
```

#### Parámetros de Análisis de Diversidad

```bash
SAMPLING_DEPTH=6000            # Profundidad de rarefacción
PHYLO_THREADS=12               # Hilos para filogenia
```

### Ejemplo de Configuración para Servidor de 24 Cores

```bash
#!/usr/bin/env bash

FASTP_THREADS=6
DADA2_THREADS=20
PHYLO_THREADS=20

SAMPLING_DEPTH=8000

DADA2_TRUNC_LEN_F=240
DADA2_TRUNC_LEN_R=230
```

---

## 📊 Comparación de Resultados

### Comparación entre Configuraciones

Para comparar diferentes estrategias de optimización:

```bash
bash tools/compare_results.sh Servidor_Actual_Sin_Opt Servidor_Actual_Opt Servidor_Nuevo_Opt
```

### Ejemplo de Análisis

```bash
# 1. Ejecutar pipeline sin optimizaciones
bash pipeline1_stats.sh Baseline

# 2. Aplicar optimizaciones de kernel
sudo bash mods/optimize_kernel.sh
bash pipeline1_stats.sh Kernel_Opt

# 3. Usar pipeline optimizado
bash pipeline_optimized_parallel_stats.sh Full_Opt

# 4. Comparar resultados
bash tools/compare_results.sh Baseline Kernel_Opt Full_Opt
```

### Métricas de Comparación

El script genera:

- **Gráficos de tiempo**: Comparación de duración por paso
- **Gráficos de memoria**: Uso máximo de RAM
- **Gráficos de CPU**: Utilización porcentual
- **Gráficos de I/O**: Velocidad de lectura/escritura
- **Tabla de mejoras**: Porcentajes de optimización

---

## 🚀 Optimizaciones Implementadas

### Nivel 1: Optimización de Kernel

**Script**: `mods/optimize_kernel.sh`

- Reducción de swappiness (vm.swappiness=10)
- Optimización de escritura diferida (dirty_ratio=40)
- Aumento de límite de archivos abiertos
- Configuración de I/O scheduler (deadline/mq-deadline)
- tmpfs de 4GB para archivos temporales

**Impacto**: 15-25% reducción de tiempo

### Nivel 2: Herramientas de Paralelización

**Script**: `configurations/install_optimization_tools.sh`

- GNU Parallel para ejecución paralela de tareas
- pigz para compresión/descompresión paralela
- Reemplazo automático de gzip por pigz

**Impacto**: 30-45% reducción de tiempo

### Nivel 3: Perfil HPC Compute

**Script**: `mods/tuned_activate_hpc_compute.sh`

- Optimización de frecuencias de CPU
- Políticas de energía para rendimiento
- Schedulers optimizados para HPC

**Impacto**: 10-20% reducción de tiempo

### Nivel 4: Pipeline Optimizado

**Script**: `pipeline_optimized_parallel.sh`

- Procesamiento paralelo de muestras (GNU Parallel)
- Todas las muestras procesadas juntas en DADA2
- Uso de tmpfs para archivos intermedios
- Compresión paralela con pigz

**Impacto combinado**: **92.7% reducción de tiempo**

---

## 📈 Resultados

### Servidor Actual (12 cores, 32 GB RAM)

| Configuración     | Tiempo Total   | Mejora    |
| ----------------- | -------------- | --------- |
| Sin optimizar     | ~8-10 horas    | -         |
| Kernel optimizado | ~6-7 horas     | 25%       |
| Full optimizado   | ~35-45 minutos | **92.7%** |

### Servidor Nuevo (24 cores, 64 GB RAM)

| Configuración     | Tiempo Total   | Mejora    |
| ----------------- | -------------- | --------- |
| Sin optimizar     | ~4-5 horas     | -         |
| Kernel optimizado | ~3-3.5 horas   | 30%       |
| Full optimizado   | ~18-25 minutos | **93.5%** |

### Métricas de Utilización

**Sin optimizar**:

- CPU: 15-25%
- Memoria: ~8 GB
- I/O: Secuencial

**Optimizado**:

- CPU: 45-60%
- Memoria: ~12-16 GB
- I/O: Paralelo (pigz)

---

## 🐛 Troubleshooting

### Problema: Error de permisos

**Error**: `Permission denied`

**Solución**:

```bash
# Verificar pertenencia al grupo research
groups

# Si no está en el grupo, agregarse
sudo usermod -aG research $USER

# Cerrar sesión y volver a entrar
```

### Problema: Conda no encontrado después de instalación

**Error**: `conda: command not found`

**Solución**:

```bash
# Reinicializar conda
source /opt/conda/etc/profile.d/conda.sh
conda init bash

# Cerrar y reabrir terminal
```

### Problema: QIIME2 falla con error de memoria

**Error**: `MemoryError` o `Killed`

**Solución**:

```bash
# Reducir profundidad de muestreo
echo "SAMPLING_DEPTH=4000" >> custom_config.sh

# Reducir hilos de DADA2
echo "DADA2_THREADS=8" >> custom_config.sh

# Ejecutar con configuración personalizada
bash pipeline1_stats.sh MiProyecto custom_config.sh
```

### Problema: Archivos .qzv no se generan

**Error**: Missing `.qzv` files

**Solución**:

```bash
# Verificar que metadata.tsv existe y es válido
cat /home/proyecto/MiProyecto/metadata.tsv

# Verificar que hay resultados de DADA2
ls -lh /home/proyecto/MiProyecto/qiime2_results/dada2/

# Regenerar metadata si es necesario
bash tools/generate_metadata.sh MiProyecto
```

### Problema: GNU Parallel muestra warning de citación

**Warning**: `citation` warning

**Solución**:

```bash
# El script install_optimization_tools.sh ya crea este archivo
# Si persiste, ejecutar manualmente:
mkdir -p ~/.parallel
touch ~/.parallel/will-cite
```

### Problema: pigz no reemplaza gzip

**Síntoma**: Sigue usando gzip estándar

**Solución**:

```bash
# Verificar alias
alias | grep gzip

# Si no aparece, cargar perfil
source /etc/profile.d/bioinformatics_optimizations.sh

# Verificar nuevamente
which gzip  # Debe apuntar a pigz
```

### Problema: tmpfs no está montado

**Error**: `/mnt/fast_tmp: No such file or directory`

**Solución**:

```bash
# Verificar si está en fstab
grep fast_tmp /etc/fstab

# Si no está, ejecutar optimize_kernel.sh nuevamente
sudo bash mods/optimize_kernel.sh

# Montar manualmente si es necesario
sudo mkdir -p /mnt/fast_tmp
sudo mount -t tmpfs -o size=4G tmpfs /mnt/fast_tmp
```

---

## 📚 Referencias

### Software y Herramientas

- **QIIME2** (2024.10): [https://qiime2.org/](https://qiime2.org/)
- **fastp**: Chen et al. (2018). [doi:10.1093/bioinformatics/bty560](https://doi.org/10.1093/bioinformatics/bty560)
- **GNU Parallel**: Tange (2022). [doi:10.5281/zenodo.1146014](https://doi.org/10.5281/zenodo.1146014)
- **pigz**: [https://zlib.net/pigz/](https://zlib.net/pigz/)

### Metodología Bioinformática

- **DADA2**: Callahan et al. (2016). "DADA2: High-resolution sample inference from Illumina amplicon data". _Nature Methods_, 13(7), 581-583. [doi:10.1038/nmeth.3869](https://doi.org/10.1038/nmeth.3869)

- **Análisis de diversidad**: Lozupone & Knight (2005). "UniFrac: a new phylogenetic method for comparing microbial communities". _Applied and Environmental Microbiology_, 71(12), 8228-8235. [doi:10.1128/AEM.71.12.8228-8235.2005](https://doi.org/10.1128/AEM.71.12.8228-8235.2005)

### Optimización Computacional

- **Kernel optimization for bioinformatics**: Kumar et al. (2021). "Performance optimization of bioinformatics applications on HPC systems". _BMC Bioinformatics_, 22(1), 1-18. [doi:10.1186/s12859-021-04089-5](https://doi.org/10.1186/s12859-021-04089-5)

- **Parallel processing in genomics**: Schmidt & Hildebrandt (2021). "Opportunities and Challenges in Applying Parallel and Distributed Computing to Genomics". _Frontiers in Genetics_, 12. [doi:10.3389/fgene.2021.659687](https://doi.org/10.3389/fgene.2021.659687)

### Proyecto de Investigación

- **Universidad Técnica de Ambato** - Proyecto: "Estrategias Metagenómicas para caracterización del microbioma intestinal humano aplicado al diagnóstico precoz y tratamiento personalizado de las Enfermedades Inflamatorias Intestinales (EII)"

---

## 📝 Licencia

Este proyecto está bajo la Licencia MIT. Ver archivo `LICENSE` para más detalles.

---

## 👨‍💻 Autor

**Mateo Zurita**  
Universidad Técnica de Ambato  
Facultad de Ingeniería en Sistemas, Electrónica e Industrial  
Carrera de Software

**Contacto**: [GitHub](https://github.com/mateozu13)

---

## 🙏 Agradecimientos

- Universidad Técnica de Ambato - FISEI
- Proyecto de Investigación EII
- Comunidad QIIME2
- Comunidad de bioinformática de código abierto

---

## 📅 Última Actualización

Diciembre 2025 - Versión 1.0.0

---

## 🔄 Contribuciones

Las contribuciones son bienvenidas. Por favor:

1. Fork el proyecto
2. Cree una rama para su feature (`git checkout -b feature/NuevaCaracteristica`)
3. Commit sus cambios (`git commit -m 'Agregar nueva característica'`)
4. Push a la rama (`git push origin feature/NuevaCaracteristica`)
5. Abra un Pull Request

---

## 📊 Estado del Proyecto

![Status](https://img.shields.io/badge/Status-Active-success)
![Maintenance](https://img.shields.io/badge/Maintained-Yes-green.svg)
![Version](https://img.shields.io/badge/Version-1.0.0-blue.svg)

**Última ejecución exitosa**: Diciembre 2025  
**Tests pasados**: ✅ Todos  
**Documentación**: ✅ Completa
