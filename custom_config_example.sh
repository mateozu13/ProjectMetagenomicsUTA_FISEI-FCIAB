#!/usr/bin/env bash
################################################################################
# Archivo de configuración personalizada para el pipeline QIIME2
#
# INSTRUCCIONES DE USO:
# ---------------------
# 1. Copia este archivo y modifica los parámetros que necesites
# 2. Ejecuta el pipeline con:
#    bash complete_pipeline_corregido.sh Proyecto1_20251113 custom_config.sh
#
# VENTAJAS:
# ---------
# - No necesitas modificar el script principal
# - Puedes tener múltiples configuraciones para diferentes análisis
# - Útil para optimizar parámetros sin tocar el código base
# - Ideal para probar diferentes profundidades de rarefacción o 
#   parámetros de calidad
#
################################################################################

# ============================================================================
# EJEMPLO 1: CONFIGURACIÓN ESTRICTA (alta calidad)
# ============================================================================
# Usar esta configuración cuando necesites máxima calidad y tengas
# profundidad de secuenciación alta (>20,000 reads/muestra)

# FASTP - Control de calidad más estricto
FASTP_QUALITY_PHRED=25          # Calidad mínima más alta (en lugar de 20)
FASTP_LENGTH_REQUIRED=200       # Lecturas más largas (en lugar de 150)
FASTP_TRIM_FRONT1=15            # Recortar más del inicio
FASTP_TRIM_FRONT2=15

# DADA2 - Parámetros más conservadores
DADA2_TRUNC_LEN_F=250           # Mantener más longitud
DADA2_TRUNC_LEN_R=230
DADA2_MAX_EE_F=1.5              # Menos errores permitidos (más estricto)
DADA2_MAX_EE_R=1.5

# DIVERSIDAD - Mayor profundidad de rarefacción
SAMPLING_DEPTH=10000            # Requiere más reads por muestra


# ============================================================================
# EJEMPLO 2: CONFIGURACIÓN PERMISIVA (baja calidad de secuenciación)
# ============================================================================
# Descomenta esta sección si tus datos tienen baja calidad o
# profundidad de secuenciación baja (<10,000 reads/muestra)

# FASTP_QUALITY_PHRED=15
# FASTP_LENGTH_REQUIRED=100
# FASTP_TRIM_FRONT1=5
# FASTP_TRIM_FRONT2=5

# DADA2_TRUNC_LEN_F=200
# DADA2_TRUNC_LEN_R=180
# DADA2_MAX_EE_F=3.0
# DADA2_MAX_EE_R=3.0

# SAMPLING_DEPTH=3000


# ============================================================================
# EJEMPLO 3: CONFIGURACIÓN PARA REGIÓN V4 (más corta)
# ============================================================================
# Usar cuando secuencies solo la región V4 del 16S

# DADA2_TRUNC_LEN_F=200
# DADA2_TRUNC_LEN_R=150
# SAMPLING_DEPTH=7000


# ============================================================================
# EJEMPLO 4: OPTIMIZACIÓN DE RECURSOS
# ============================================================================
# Ajustar según tu servidor/computadora

# FASTP_THREADS=24              # Usar todos los cores disponibles
# DADA2_THREADS=1               # DADA2 no mejora con más de 1-2 threads
# PHYLO_THREADS=24              # Alineamiento y árbol se benefician de paralelización


# ============================================================================
# NOTAS IMPORTANTES:
# ============================================================================
#
# 1. SAMPLING_DEPTH:
#    - Revisa denoising-stats.qzv ANTES de elegir este valor
#    - Debe ser menor que el número mínimo de reads retenidos
#    - Ejemplo: Si tu muestra con menos reads tiene 8,000 reads,
#      usa SAMPLING_DEPTH=6000 o 7000
#
# 2. DADA2_TRUNC_LEN:
#    - Depende de la región 16S secuenciada (V3-V4, V4, V1-V2, etc.)
#    - Para V3-V4: F=230-250, R=220-230
#    - Para V4 solo: F=200, R=150
#    - Las lecturas deben tener overlap de ~20-50 bp para merge
#
# 3. DADA2_MAX_EE:
#    - 2.0 es un buen punto de partida
#    - Reducir a 1.5 para mayor calidad (pero menos reads)
#    - Aumentar a 3.0 si pierdes muchas muestras
#
# 4. FASTP_QUALITY_PHRED:
#    - Phred 20 = 99% de precisión (1% error)
#    - Phred 30 = 99.9% de precisión (0.1% error)
#    - Más alto = más estricto = menos reads pero mejor calidad
#
################################################################################