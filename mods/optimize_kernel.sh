#!/usr/bin/env bash

set -euo pipefail

echo "======================================================================"
echo "  SCRIPT DE OPTIMIZACIÓN DEL KERNEL - ROCKY LINUX 8.10"
echo "  Para análisis bioinformáticos intensivos en I/O y memoria"
echo "======================================================================"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Este script debe ejecutarse como root (sudo)"
   exit 1
fi

BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"

echo "[1/5] Creando backup de configuración actual..."
cp /etc/sysctl.conf "$BACKUP_FILE"
echo "    ✓ Backup guardado en: $BACKUP_FILE"
echo ""

echo "[2/5] Aplicando optimizaciones del kernel..."
cat >> /etc/sysctl.conf << 'EOF'

vm.swappiness=10
vm.dirty_ratio=40
vm.dirty_background_ratio=10
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500

fs.file-max=2097152
fs.inotify.max_user_watches=524288

kernel.sched_min_granularity_ns=10000000
kernel.sched_wakeup_granularity_ns=15000000
kernel.sched_migration_cost_ns=5000000

vm.vfs_cache_pressure=50
vm.min_free_kbytes=65536
vm.max_map_count=262144

net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728

EOF

echo "    ✓ Parámetros agregados a /etc/sysctl.conf"
echo ""

echo "[3/5] Aplicando cambios inmediatamente..."
sysctl -p
echo "    ✓ Configuración aplicada"
echo ""

echo "[4/5] Optimizando schedulers de I/O..."

for device in /sys/block/sd* /sys/block/vd* /sys/block/nvme*; do
    if [[ -d "$device" ]]; then
        device_name=$(basename "$device")

        if [[ -f "$device/queue/scheduler" ]]; then
            if [[ "$device_name" == nvme* ]]; then
                echo none > "$device/queue/scheduler" 2>/dev/null || true
                echo "    ✓ Scheduler 'none' configurado para NVMe: $device_name"
            else
                echo deadline > "$device/queue/scheduler" 2>/dev/null || echo mq-deadline > "$device/queue/scheduler" 2>/dev/null || true
                echo "    ✓ Scheduler 'deadline' configurado para: $device_name"
            fi
        fi
        
        if [[ -f "$device/queue/read_ahead_kb" ]]; then
            echo 2048 > "$device/queue/read_ahead_kb" 2>/dev/null || true
            echo "    ✓ Read-ahead configurado para $device_name"
        fi
        
        if [[ -f "$device/queue/nr_requests" ]]; then
            echo 256 > "$device/queue/nr_requests" 2>/dev/null || true
        fi
    fi
done
echo ""

echo "[5/5] Configurando tmpfs para archivos temporales..."
if ! grep -q "/mnt/fast_tmp" /etc/fstab; then
    mkdir -p /mnt/fast_tmp
    echo "tmpfs /mnt/fast_tmp tmpfs defaults,size=4G,mode=1777 0 0" >> /etc/fstab
    mount /mnt/fast_tmp
    echo "    ✓ tmpfs montado en /mnt/fast_tmp (4GB)"
else
    echo "    ⚠ tmpfs ya configurado en /etc/fstab"
fi
echo ""

echo "======================================================================"
echo "  OPTIMIZACIÓN COMPLETADA"
echo "======================================================================"
echo ""
echo "RESUMEN DE CAMBIOS:"
echo "-------------------"
echo "✓ Swappiness reducido a 10 (menos uso de swap)"
echo "✓ Dirty ratio optimizado para mejor I/O"
echo "✓ Límite de archivos abiertos aumentado"
echo "✓ Scheduling de CPU optimizado"
echo "✓ Caché de VFS optimizado"
echo "✓ I/O scheduler configurado (deadline/mq-deadline)"
echo "✓ Read-ahead aumentado a 2MB"
echo "✓ tmpfs de 4GB montado en /mnt/fast_tmp"
echo ""
echo "RECOMENDACIONES:"
echo "----------------"
echo "1. Ejecutar 'sysctl -p' después de cada reinicio (ya configurado)"
echo "2. Verificar configuración: sysctl -a | grep -E 'vm.swappiness|vm.dirty'"
echo "3. Usar /mnt/fast_tmp para archivos temporales del pipeline"
echo "4. Monitorear rendimiento con: iostat -x 2 y vmstat 2"
echo ""
echo "Para revertir cambios, restaurar desde: $BACKUP_FILE"
echo "======================================================================"
