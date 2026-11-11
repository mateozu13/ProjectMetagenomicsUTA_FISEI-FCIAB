# Métricas por etapa — servidor actual (Xeon E312xx, KVM, 8 GB, HDD)

Los CSV originales generados por `pipeline1_stats.sh` y `pipeline_optimized_parallel_stats.sh`
(ejecuciones del 18 y 19 de noviembre de 2025) no se conservaron. Estos archivos son una
transcripción manual de los valores por etapa que aparecen en los informes PDF generados
automáticamente en esa fecha, incluidos en esta carpeta.

- `duration_min`, `cpu_percent`, `max_rss_mb`: valores de los informes.
- `io_total_mb`: solo disponible por etapa en el informe optimizado.
- `cpu_min`: columna derivada = duration_min × cpu_percent / 100.

Los nombres de etapa del informe base para las muestras de fastp siguen el orden en que aparecen
en el gráfico de duración del informe.
