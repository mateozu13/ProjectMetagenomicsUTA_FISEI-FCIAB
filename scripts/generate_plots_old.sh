#!/usr/bin/env bash
################################################################################
# Generador de gráficos COMPLETOS de rendimiento para pipeline QIIME2
# Crea visualizaciones interactivas en HTML usando Python/Plotly
# Incluye: Tiempo, CPU, Memoria, I/O, Comparaciones
# 
# Uso: bash generate_plots.sh <nombre_proyecto>
################################################################################

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto>"
  exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="/home/proyecto/$PROJECT_NAME"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$PROJECT_DIR/logs"
PLOTS_DIR="$PROJECT_DIR/performance_plots"

mkdir -p "$PLOTS_DIR"

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║      GENERADOR DE GRÁFICOS DE RENDIMIENTO          ║"
echo "╚════════════════════════════════════════════════════╝"
echo "Proyecto: $PROJECT_NAME"
echo ""

# Verificar que existen los archivos de métricas
if [[ ! -f "$LOGS_DIR/timing_summary.csv" ]]; then
  echo "ERROR: No se encontró $LOGS_DIR/timing_summary.csv"
  echo "Debe ejecutar primero el pipeline monitoreado"
  exit 1
fi

# Script Python para generar plots
cat > "$PLOTS_DIR/generate_plots.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import sys
import os
from pathlib import Path
import re

def load_timing_data(timing_file):
    df = pd.read_csv(timing_file)
    if 'duration_minutes' not in df.columns and 'duration_seconds' in df.columns:
        df['duration_minutes'] = df['duration_seconds'] / 60
    if 'max_memory_mb' not in df.columns and 'max_memory_kb' in df.columns:
        df['max_memory_mb'] = df['max_memory_kb'] / 1024
    if 'max_memory_gb' not in df.columns and 'max_memory_kb' in df.columns:
        df['max_memory_gb'] = df['max_memory_kb'] / 1024 / 1024
    return df

def load_pidstat_data(pidstat_file):
    """Cargar datos de pidstat"""
    try:
        with open(pidstat_file, 'r') as f:
            lines = f.readlines()
        
        times = []
        cpu_user = []
        cpu_system = []
        mem_percent = []
        
        # Parsear líneas de pidstat
        # Formato típico: TIME UID PID %usr %system %guest %wait %CPU CPU minflt/s majflt/s VSZ RSS %MEM
        for line in lines:
            if re.match(r'^\d+:\d+:\d+', line):
                parts = line.split()
                if len(parts) >= 13:
                    try:
                        times.append(parts[0])
                        cpu_user.append(float(parts[3]))
                        cpu_system.append(float(parts[4]))
                        mem_percent.append(float(parts[12]))
                    except (ValueError, IndexError):
                        continue
        
        if not times:
            return None
        
        df = pd.DataFrame({
            'time': times,
            'cpu_user': cpu_user,
            'cpu_system': cpu_system,
            'mem_percent': mem_percent
        })
        
        return df
    except Exception as e:
        print(f"Warning: Could not load {pidstat_file}: {e}")
        return None

def plot_timing_summary(df, output_dir):
    fig = go.Figure()
    
    p50 = df['duration_minutes'].median()
    p90 = df['duration_minutes'].quantile(0.9)
    
    fig.add_trace(go.Bar(
        x=df['step'],
        y=df['duration_minutes'],
        text=[f"{v:.2f} min" for v in df['duration_minutes']],
        textposition='outside',
        marker=dict(color=df['duration_minutes'], colorscale='Viridis', showscale=True),
        hovertemplate='<b>%{x}</b><br>Duración: %{y:.2f} min<extra></extra>'
    ))
    
    fig.add_hline(y=p50, line_dash="dash", line_color="orange", annotation_text=f"Mediana: {p50:.2f} min")
    fig.add_hline(y=p90, line_dash="dot", line_color="red", annotation_text=f"P90: {p90:.2f} min")
    
    fig.update_layout(
        title='Duración de cada paso del pipeline',
        xaxis_title='Paso',
        yaxis_title='Duración (minutos)',
        template='plotly_white',
        height=600,
        xaxis={'tickangle': -45}
    )
    
    fig.write_html(f"{output_dir}/01_duration_summary.html")
    print("✓ Gráfico 1: Duración")

def plot_memory_usage(df, output_dir):
    fig = make_subplots(rows=1, cols=2, subplot_titles=('Memoria MB', 'Memoria GB'))
    
    fig.add_trace(go.Bar(x=df['step'], y=df['max_memory_mb'], text=[f"{v:.0f}" for v in df['max_memory_mb']], textposition='outside', marker_color='lightsalmon'), row=1, col=1)
    fig.add_trace(go.Bar(x=df['step'], y=df['max_memory_gb'], text=[f"{v:.2f}" for v in df['max_memory_gb']], textposition='outside', marker_color='indianred'), row=1, col=2)
    
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=1)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=2)
    fig.update_yaxes(title_text="MB", row=1, col=1)
    fig.update_yaxes(title_text="GB", row=1, col=2)
    
    fig.update_layout(title='Uso máximo de memoria', template='plotly_white', height=600, showlegend=False)
    fig.write_html(f"{output_dir}/02_memory_summary.html")
    print("✓ Gráfico 2: Memoria")

def plot_cpu_usage(df, output_dir):
    fig = go.Figure()
    avg_cpu = df['cpu_percent'].mean()
    
    fig.add_trace(go.Bar(x=df['step'], y=df['cpu_percent'], text=[f"{v:.1f}%" for v in df['cpu_percent']], textposition='outside', marker=dict(color=df['cpu_percent'], colorscale='Blues', showscale=True)))
    fig.add_hline(y=avg_cpu, line_dash="dash", line_color="red", annotation_text=f"Promedio: {avg_cpu:.1f}%")
    
    fig.update_layout(title=f'Uso de CPU (promedio: {avg_cpu:.1f}%)', xaxis_title='Paso', yaxis_title='CPU %', template='plotly_white', height=600, xaxis={'tickangle': -45})
    fig.write_html(f"{output_dir}/03_cpu_summary.html")
    print("✓ Gráfico 3: CPU")

def plot_io_analysis(df, output_dir):
    fig = make_subplots(rows=2, cols=2, subplot_titles=('I/O Lectura', 'I/O Escritura', 'I/O Total', 'Lectura vs Escritura'), specs=[[{'type': 'bar'}, {'type': 'bar'}], [{'type': 'bar'}, {'type': 'scatter'}]])
    
    fig.add_trace(go.Bar(x=df['step'], y=df['io_read_mb'], marker_color='lightblue', text=[f"{v:.1f}" for v in df['io_read_mb']], textposition='outside'), row=1, col=1)
    fig.add_trace(go.Bar(x=df['step'], y=df['io_write_mb'], marker_color='lightcoral', text=[f"{v:.1f}" for v in df['io_write_mb']], textposition='outside'), row=1, col=2)
    fig.add_trace(go.Bar(x=df['step'], y=df['io_total_mb'], marker_color='lightgreen', text=[f"{v:.1f}" for v in df['io_total_mb']], textposition='outside'), row=2, col=1)
    fig.add_trace(go.Scatter(x=df['io_read_mb'], y=df['io_write_mb'], mode='markers+text', text=df['step'], textposition='top center', marker=dict(size=df['io_total_mb']/50, color=df['io_total_mb'], colorscale='Viridis', showscale=True)), row=2, col=2)
    
    fig.update_xaxes(tickangle=-45, row=1, col=1)
    fig.update_xaxes(tickangle=-45, row=1, col=2)
    fig.update_xaxes(tickangle=-45, row=2, col=1)
    fig.update_yaxes(title_text="MB", row=1, col=1)
    fig.update_yaxes(title_text="MB", row=1, col=2)
    fig.update_yaxes(title_text="MB", row=2, col=1)
    
    fig.update_layout(title='Análisis de I/O', height=900, showlegend=False, template='plotly_white')
    fig.write_html(f"{output_dir}/04_io_analysis.html")
    print("✓ Gráfico 4: I/O")

def plot_resource_dashboard(df, output_dir):
    fig = make_subplots(rows=2, cols=2, subplot_titles=('Duración', 'Memoria', 'CPU', 'I/O'), specs=[[{'type': 'bar'}, {'type': 'bar'}], [{'type': 'bar'}, {'type': 'bar'}]])
    
    fig.add_trace(go.Bar(x=df['step'], y=df['duration_minutes'], marker_color='indianred'), row=1, col=1)
    fig.add_trace(go.Bar(x=df['step'], y=df['max_memory_gb'], marker_color='lightsalmon'), row=1, col=2)
    fig.add_trace(go.Bar(x=df['step'], y=df['cpu_percent'], marker_color='lightblue'), row=2, col=1)
    fig.add_trace(go.Bar(x=df['step'], y=df['io_total_mb'], marker_color='lightgreen'), row=2, col=2)
    
    for i in range(1, 3):
        for j in range(1, 3):
            fig.update_xaxes(tickangle=-45, row=i, col=j)
    
    fig.update_layout(title='Dashboard de recursos', height=800, showlegend=False, template='plotly_white')
    fig.write_html(f"{output_dir}/05_resource_dashboard.html")
    print("✓ Gráfico 5: Dashboard")

def plot_pidstat_timeseries(metrics_dir, output_dir):
    """Gráficos de series de tiempo de pidstat"""
    pidstat_files = list(Path(metrics_dir).glob("*_pidstat.csv"))
    
    if not pidstat_files:
        print("⚠️  No se encontraron archivos pidstat")
        return
    
    count = 0
    for pidstat_file in pidstat_files:
        step_name = pidstat_file.stem.replace('_pidstat', '')
        df = load_pidstat_data(str(pidstat_file))
        
        if df is None or df.empty:
            continue
        
        fig = make_subplots(rows=2, cols=1, subplot_titles=(f'{step_name} - CPU', f'{step_name} - Memoria'), vertical_spacing=0.15)
        
        fig.add_trace(go.Scatter(x=list(range(len(df))), y=df['cpu_user'], name='User CPU', mode='lines', line=dict(color='blue')), row=1, col=1)
        fig.add_trace(go.Scatter(x=list(range(len(df))), y=df['cpu_system'], name='System CPU', mode='lines', line=dict(color='red')), row=1, col=1)
        fig.add_trace(go.Scatter(x=list(range(len(df))), y=df['mem_percent'], name='Memoria %', mode='lines', line=dict(color='orange')), row=2, col=1)
        
        fig.update_xaxes(title_text="Muestras (cada 2s)", row=1, col=1)
        fig.update_xaxes(title_text="Muestras (cada 2s)", row=2, col=1)
        fig.update_yaxes(title_text="% CPU", row=1, col=1)
        fig.update_yaxes(title_text="% Memoria", row=2, col=1)
        
        fig.update_layout(title=f"Métricas - {step_name}", height=600, template='plotly_white')
        
        safe_name = step_name.replace('/', '_')
        fig.write_html(f"{output_dir}/timeseries_{safe_name}.html")
        count += 1
    
    if count > 0:
        print(f"✓ Series de tiempo: {count} gráficos")
    else:
        print("⚠️  No se generaron series de tiempo")

def create_index_html(output_dir, df):
    html_files = sorted([f for f in os.listdir(output_dir) if f.endswith('.html') and f != 'index.html'])
    
    total_time = df['duration_minutes'].sum()
    total_mem = df['max_memory_gb'].sum()
    avg_cpu = df['cpu_percent'].mean()
    total_io = df['io_total_mb'].sum() / 1024
    
    html_content = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Performance Report</title>
<style>
body{{font-family:Arial;margin:20px;background:#667eea;}}
.container{{max-width:1400px;margin:0 auto;background:white;border-radius:15px;padding:30px;box-shadow:0 10px 40px rgba(0,0,0,0.3);}}
h1{{color:#2c3e50;border-bottom:4px solid #3498db;padding-bottom:15px;}}
.stats-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px;margin:30px 0;}}
.stat-card{{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;padding:20px;border-radius:10px;text-align:center;}}
.stat-value{{font-size:2.5em;font-weight:bold;margin:10px 0;}}
.graph-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(500px,1fr));gap:25px;}}
.graph-card{{background:white;border-radius:12px;padding:20px;box-shadow:0 4px 6px rgba(0,0,0,0.1);}}
.graph-card:hover{{transform:translateY(-8px);box-shadow:0 12px 24px rgba(0,0,0,0.15);}}
iframe{{width:100%;height:600px;border:2px solid #ddd;border-radius:8px;margin:10px 0;}}
</style></head><body><div class="container">
<h1>📊 Performance Report - QIIME2</h1>
<p><strong>Proyecto:</strong> {os.path.basename(os.path.dirname(output_dir))}</p>
<div class="stats-grid">
<div class="stat-card"><div class="stat-value">{total_time:.1f} min</div><div>Tiempo Total</div></div>
<div class="stat-card"><div class="stat-value">{total_mem:.2f} GB</div><div>Memoria Total</div></div>
<div class="stat-card"><div class="stat-value">{avg_cpu:.1f}%</div><div>CPU Promedio</div></div>
<div class="stat-card"><div class="stat-value">{total_io:.2f} GB</div><div>I/O Total</div></div>
</div>
<h2>Gráficos</h2><div class="graph-grid">"""
    
    for plot_file in [f for f in html_files if not f.startswith('timeseries_')]:
        plot_name = plot_file.replace('.html', '').replace('_', ' ').title()
        html_content += f'<div class="graph-card"><h3>{plot_name}</h3><iframe src="{plot_file}"></iframe></div>'
    
    html_content += '</div>'
    
    timeseries = [f for f in html_files if f.startswith('timeseries_')]
    if timeseries:
        html_content += '<h2>Series de Tiempo</h2><div class="graph-grid">'
        for plot_file in timeseries:
            name = plot_file.replace('timeseries_', '').replace('.html', '').replace('_', ' ').title()
            html_content += f'<div class="graph-card"><h3>{name}</h3><iframe src="{plot_file}"></iframe></div>'
        html_content += '</div>'
    
    html_content += '</div></body></html>'
    
    with open(f"{output_dir}/index.html", 'w', encoding='utf-8') as f:
        f.write(html_content)
    
    print("✓ Índice HTML")

def main():
    if len(sys.argv) != 4:
        print("Usage: python generate_plots.py <logs_dir> <metrics_dir> <output_dir>")
        sys.exit(1)
    
    logs_dir, metrics_dir, output_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    
    print("\nGenerando gráficos...")
    print("="*50)
    
    df = load_timing_data(f"{logs_dir}/timing_summary.csv")
    
    plot_timing_summary(df, output_dir)
    plot_memory_usage(df, output_dir)
    plot_cpu_usage(df, output_dir)
    plot_io_analysis(df, output_dir)
    plot_resource_dashboard(df, output_dir)
    plot_pidstat_timeseries(metrics_dir, output_dir)
    create_index_html(output_dir, df)
    
    print("="*50)
    print(f"\n✓ Gráficos en: {output_dir}/index.html\n")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

echo "Generando gráficos..."
/opt/conda/bin/conda run -n qiime2 python "$PLOTS_DIR/generate_plots.py" "$LOGS_DIR" "$METRICS_DIR" "$PLOTS_DIR"

if [[ $? -eq 0 ]]; then
  echo ""
  echo "╔════════════════════════════════════════════════════╗"
  echo "║         GRÁFICOS GENERADOS EXITOSAMENTE            ║"
  echo "╚════════════════════════════════════════════════════╝"
  echo ""
  echo "Ubicación: $PLOTS_DIR"
  echo "Abrir: firefox $PLOTS_DIR/index.html"
  echo ""
  echo " Gráficos disponibles:"
  ls -1 "$PLOTS_DIR"/*.html | xargs -n 1 basename | grep -v "generate_plots.py" | nl
  echo ""
  echo " Tip: Use estos gráficos para:"
  echo "   - Identificar cuellos de botella"
  echo "   - Comparar diferentes configuraciones"
  echo "   - Optimizar uso de recursos"
  echo "   - Dimensionar infraestructura"
  echo ""
else
  echo " ERROR: Falló la generación de gráficos"
  exit 1
fi