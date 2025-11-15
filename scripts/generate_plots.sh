#!/usr/bin/env bash
################################################################################
# Generador de gráficos COMPLETOS de rendimiento para pipeline QIIME2
# Crea visualizaciones interactivas en HTML usando Python/Plotly
# Incluye: Tiempo, CPU, Memoria, I/O, Comparaciones
# 
# Uso: bash generate_plots_mejorado.sh <nombre_proyecto>
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
echo "╔════════════════════════════════════════════════════════╗"
echo "║      GENERADOR DE GRÁFICOS DE RENDIMIENTO              ║"
echo "╚════════════════════════════════════════════════════════╝"
echo "Proyecto: $PROJECT_NAME"
echo ""

# Verificar que existen los archivos de métricas
if [[ ! -f "$LOGS_DIR/timing_summary.csv" ]]; then
  echo "ERROR: No se encontró $LOGS_DIR/timing_summary.csv"
  echo "Debe ejecutar primero el pipeline monitoreado"
  exit 1
fi

# ============================================================================
# SCRIPT PYTHON MEJORADO PARA GENERAR GRÁFICOS
# ============================================================================

cat > "$PLOTS_DIR/generate_plots.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
Generador COMPLETO de gráficos de rendimiento para pipeline QIIME2
Incluye: Tiempo, CPU, Memoria, I/O, Comparaciones y análisis detallado
"""

import pandas as pd
import plotly.graph_objects as go
import plotly.express as px
from plotly.subplots import make_subplots
import sys
import os
from pathlib import Path
import numpy as np

def load_timing_data(timing_file):
    """Cargar datos de timing con TODAS las columnas"""
    df = pd.read_csv(timing_file)
    
    # Crear columnas adicionales si no existen
    if 'duration_minutes' not in df.columns and 'duration_seconds' in df.columns:
        df['duration_minutes'] = df['duration_seconds'] / 60
    
    if 'max_memory_mb' not in df.columns and 'max_memory_kb' in df.columns:
        df['max_memory_mb'] = df['max_memory_kb'] / 1024
    
    if 'max_memory_gb' not in df.columns and 'max_memory_kb' in df.columns:
        df['max_memory_gb'] = df['max_memory_kb'] / 1024 / 1024
    
    return df

def plot_timing_summary(df, output_dir):
    """Gráfico de barras de duración por paso con percentiles"""
    fig = go.Figure()
    
    # Calcular percentiles para referencia
    p50 = df['duration_minutes'].median()
    p90 = df['duration_minutes'].quantile(0.9)
    
    fig.add_trace(go.Bar(
        x=df['step'],
        y=df['duration_minutes'],
        text=[f"{v:.2f} min" for v in df['duration_minutes']],
        textposition='outside',
        marker=dict(
            color=df['duration_minutes'],
            colorscale='Viridis',
            showscale=True,
            colorbar=dict(title="Minutos")
        ),
        hovertemplate='<b>%{x}</b><br>Duración: %{y:.2f} min<br>Segundos: %{customdata:.0f}s<extra></extra>',
        customdata=df['duration_seconds']
    ))
    
    # Líneas de referencia
    fig.add_hline(y=p50, line_dash="dash", line_color="orange", 
                  annotation_text=f"Mediana: {p50:.2f} min")
    fig.add_hline(y=p90, line_dash="dot", line_color="red", 
                  annotation_text=f"P90: {p90:.2f} min")
    
    fig.update_layout(
        title='Duración de cada paso del pipeline<br><sub>Comparación de tiempos de ejecución</sub>',
        xaxis_title='Paso del Pipeline',
        yaxis_title='Duración (minutos)',
        template='plotly_white',
        height=600,
        xaxis={'tickangle': -45},
        showlegend=False
    )
    
    fig.write_html(f"{output_dir}/01_duration_summary.html")
    print("✓ Gráfico 1: Duración por paso")

def plot_memory_usage(df, output_dir):
    """Gráfico de uso de memoria con múltiples escalas"""
    fig = make_subplots(
        rows=1, cols=2,
        subplot_titles=('Memoria en MB', 'Memoria en GB'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}]]
    )
    
    # MB
    fig.add_trace(
        go.Bar(
            x=df['step'],
            y=df['max_memory_mb'],
            text=[f"{v:.0f} MB" for v in df['max_memory_mb']],
            textposition='outside',
            marker=dict(color='lightsalmon'),
            name='MB',
            hovertemplate='<b>%{x}</b><br>Memoria: %{y:.0f} MB<extra></extra>'
        ),
        row=1, col=1
    )
    
    # GB
    fig.add_trace(
        go.Bar(
            x=df['step'],
            y=df['max_memory_gb'],
            text=[f"{v:.2f} GB" for v in df['max_memory_gb']],
            textposition='outside',
            marker=dict(color='indianred'),
            name='GB',
            hovertemplate='<b>%{x}</b><br>Memoria: %{y:.3f} GB<extra></extra>'
        ),
        row=1, col=2
    )
    
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=1)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=2)
    fig.update_yaxes(title_text="Memoria (MB)", row=1, col=1)
    fig.update_yaxes(title_text="Memoria (GB)", row=1, col=2)
    
    fig.update_layout(
        title_text='Uso máximo de memoria por paso<br><sub>Visualización en MB y GB</sub>',
        template='plotly_white',
        height=600,
        showlegend=False
    )
    
    fig.write_html(f"{output_dir}/02_memory_summary.html")
    print("✓ Gráfico 2: Uso de memoria")

def plot_cpu_usage(df, output_dir):
    """Gráfico de uso de CPU con análisis"""
    fig = go.Figure()
    
    avg_cpu = df['cpu_percent'].mean()
    
    fig.add_trace(go.Bar(
        x=df['step'],
        y=df['cpu_percent'],
        text=[f"{v:.1f}%" for v in df['cpu_percent']],
        textposition='outside',
        marker=dict(
            color=df['cpu_percent'],
            colorscale='Blues',
            showscale=True,
            colorbar=dict(title="CPU %")
        ),
        hovertemplate='<b>%{x}</b><br>CPU: %{y:.1f}%<extra></extra>'
    ))
    
    # Línea de promedio
    fig.add_hline(y=avg_cpu, line_dash="dash", line_color="red",
                  annotation_text=f"Promedio: {avg_cpu:.1f}%")
    
    fig.update_layout(
        title=f'Uso de CPU por paso<br><sub>CPU promedio del pipeline: {avg_cpu:.1f}%</sub>',
        xaxis_title='Paso',
        yaxis_title='CPU (%)',
        template='plotly_white',
        height=600,
        xaxis={'tickangle': -45}
    )
    
    fig.write_html(f"{output_dir}/03_cpu_summary.html")
    print("✓ Gráfico 3: Uso de CPU")

def plot_io_analysis(df, output_dir):
    """Gráfico de análisis de I/O (Lectura, Escritura, Total)"""
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=('I/O Lectura', 'I/O Escritura', 'I/O Total', 'Comparación Lectura vs Escritura'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'bar'}, {'type': 'scatter'}]]
    )
    
    # Lectura
    fig.add_trace(
        go.Bar(x=df['step'], y=df['io_read_mb'], name='Lectura',
               marker_color='lightblue',
               text=[f"{v:.1f} MB" for v in df['io_read_mb']],
               textposition='outside',
               hovertemplate='<b>%{x}</b><br>Lectura: %{y:.2f} MB<extra></extra>'),
        row=1, col=1
    )
    
    # Escritura
    fig.add_trace(
        go.Bar(x=df['step'], y=df['io_write_mb'], name='Escritura',
               marker_color='lightcoral',
               text=[f"{v:.1f} MB" for v in df['io_write_mb']],
               textposition='outside',
               hovertemplate='<b>%{x}</b><br>Escritura: %{y:.2f} MB<extra></extra>'),
        row=1, col=2
    )
    
    # Total
    fig.add_trace(
        go.Bar(x=df['step'], y=df['io_total_mb'], name='Total',
               marker_color='lightgreen',
               text=[f"{v:.1f} MB" for v in df['io_total_mb']],
               textposition='outside',
               hovertemplate='<b>%{x}</b><br>Total I/O: %{y:.2f} MB<extra></extra>'),
        row=2, col=1
    )
    
    # Scatter comparativo
    fig.add_trace(
        go.Scatter(
            x=df['io_read_mb'], 
            y=df['io_write_mb'],
            mode='markers+text',
            text=df['step'],
            textposition='top center',
            marker=dict(
                size=df['io_total_mb']/100,
                color=df['io_total_mb'],
                colorscale='Viridis',
                showscale=True,
                colorbar=dict(title="Total I/O (MB)", x=1.15)
            ),
            name='Lectura vs Escritura',
            hovertemplate='<b>%{text}</b><br>Lectura: %{x:.1f} MB<br>Escritura: %{y:.1f} MB<extra></extra>'
        ),
        row=2, col=2
    )
    
    # Línea diagonal de referencia
    max_io = max(df['io_read_mb'].max(), df['io_write_mb'].max())
    fig.add_trace(
        go.Scatter(x=[0, max_io], y=[0, max_io], mode='lines',
                   line=dict(dash='dash', color='gray'),
                   showlegend=False, hoverinfo='skip'),
        row=2, col=2
    )
    
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=1)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=2)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=2, col=1)
    fig.update_xaxes(title_text="Lectura (MB)", row=2, col=2)
    
    fig.update_yaxes(title_text="MB", row=1, col=1)
    fig.update_yaxes(title_text="MB", row=1, col=2)
    fig.update_yaxes(title_text="MB", row=2, col=1)
    fig.update_yaxes(title_text="Escritura (MB)", row=2, col=2)
    
    fig.update_layout(
        title_text="Análisis de I/O del Pipeline<br><sub>Lectura y escritura de disco</sub>",
        height=900,
        showlegend=False,
        template='plotly_white'
    )
    
    fig.write_html(f"{output_dir}/04_io_analysis.html")
    print("✓ Gráfico 4: Análisis de I/O")

def plot_resource_dashboard(df, output_dir):
    """Dashboard completo de recursos"""
    fig = make_subplots(
        rows=3, cols=2,
        subplot_titles=('Duración', 'Memoria (GB)', 'CPU', 'I/O Total', 
                       'Eficiencia: Tiempo vs Memoria', 'Eficiencia: Tiempo vs I/O'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'scatter'}, {'type': 'scatter'}]],
        vertical_spacing=0.12,
        horizontal_spacing=0.15
    )
    
    # Duración
    fig.add_trace(
        go.Bar(x=df['step'], y=df['duration_minutes'], name='Duración',
               marker_color='indianred', showlegend=False),
        row=1, col=1
    )
    
    # Memoria
    fig.add_trace(
        go.Bar(x=df['step'], y=df['max_memory_gb'], name='Memoria',
               marker_color='lightsalmon', showlegend=False),
        row=1, col=2
    )
    
    # CPU
    fig.add_trace(
        go.Bar(x=df['step'], y=df['cpu_percent'], name='CPU',
               marker_color='lightblue', showlegend=False),
        row=2, col=1
    )
    
    # I/O Total
    fig.add_trace(
        go.Bar(x=df['step'], y=df['io_total_mb'], name='I/O',
               marker_color='lightgreen', showlegend=False),
        row=2, col=2
    )
    
    # Scatter Tiempo vs Memoria
    fig.add_trace(
        go.Scatter(
            x=df['duration_minutes'], 
            y=df['max_memory_gb'],
            mode='markers+text',
            text=df['step'],
            textposition='top center',
            marker=dict(
                size=df['cpu_percent']/3,
                color=df['cpu_percent'],
                colorscale='Viridis',
                showscale=True,
                colorbar=dict(title="CPU %", y=0.2, len=0.3)
            ),
            showlegend=False,
            hovertemplate='<b>%{text}</b><br>Tiempo: %{x:.1f} min<br>Memoria: %{y:.2f} GB<br>CPU: %{marker.color:.1f}%<extra></extra>'
        ),
        row=3, col=1
    )
    
    # Scatter Tiempo vs I/O
    fig.add_trace(
        go.Scatter(
            x=df['duration_minutes'], 
            y=df['io_total_mb'],
            mode='markers+text',
            text=df['step'],
            textposition='top center',
            marker=dict(
                size=df['max_memory_gb']*5,
                color=df['max_memory_gb'],
                colorscale='Reds',
                showscale=True,
                colorbar=dict(title="Memoria (GB)", y=0.2, len=0.3, x=1.15)
            ),
            showlegend=False,
            hovertemplate='<b>%{text}</b><br>Tiempo: %{x:.1f} min<br>I/O: %{y:.0f} MB<br>Memoria: %{marker.color:.2f} GB<extra></extra>'
        ),
        row=3, col=2
    )
    
    # Actualizar ejes
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=1)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=1, col=2)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=2, col=1)
    fig.update_xaxes(title_text="Paso", tickangle=-45, row=2, col=2)
    fig.update_xaxes(title_text="Duración (min)", row=3, col=1)
    fig.update_xaxes(title_text="Duración (min)", row=3, col=2)
    
    fig.update_yaxes(title_text="Minutos", row=1, col=1)
    fig.update_yaxes(title_text="GB", row=1, col=2)
    fig.update_yaxes(title_text="%", row=2, col=1)
    fig.update_yaxes(title_text="MB", row=2, col=2)
    fig.update_yaxes(title_text="Memoria (GB)", row=3, col=1)
    fig.update_yaxes(title_text="I/O Total (MB)", row=3, col=2)
    
    fig.update_layout(
        title_text="Dashboard Completo de Recursos del Pipeline",
        height=1200,
        template='plotly_white'
    )
    
    fig.write_html(f"{output_dir}/05_resource_dashboard.html")
    print("✓ Gráfico 5: Dashboard completo")

def plot_performance_summary(df, output_dir):
    """Tabla resumen con métricas clave"""
    
    # Calcular totales y promedios
    total_time = df['duration_minutes'].sum()
    total_memory = df['max_memory_gb'].sum()
    avg_cpu = df['cpu_percent'].mean()
    total_io = df['io_total_mb'].sum()
    
    # Identificar pasos más costosos
    slowest = df.nlargest(3, 'duration_minutes')[['step', 'duration_minutes']]
    memory_intensive = df.nlargest(3, 'max_memory_gb')[['step', 'max_memory_gb']]
    io_intensive = df.nlargest(3, 'io_total_mb')[['step', 'io_total_mb']]
    
    # Crear tabla visual
    fig = go.Figure(data=[go.Table(
        header=dict(
            values=['<b>Paso</b>', '<b>Tiempo<br>(min)</b>', '<b>Memoria<br>(GB)</b>', 
                   '<b>CPU<br>(%)</b>', '<b>I/O Total<br>(MB)</b>'],
            fill_color='paleturquoise',
            align='left',
            font=dict(size=12, color='black')
        ),
        cells=dict(
            values=[
                df['step'],
                [f"{v:.2f}" for v in df['duration_minutes']],
                [f"{v:.3f}" for v in df['max_memory_gb']],
                [f"{v:.1f}" for v in df['cpu_percent']],
                [f"{v:.1f}" for v in df['io_total_mb']]
            ],
            fill_color='lavender',
            align='left',
            font=dict(size=11)
        )
    )])
    
    fig.update_layout(
        title=f'Tabla Resumen de Rendimiento<br><sub>Total: {total_time:.2f} min | Memoria: {total_memory:.2f} GB | CPU: {avg_cpu:.1f}% | I/O: {total_io:.1f} MB</sub>',
        height=600
    )
    
    fig.write_html(f"{output_dir}/06_performance_table.html")
    print("✓ Gráfico 6: Tabla de rendimiento")

def plot_comparison_charts(df, output_dir):
    """Gráficos de comparación y correlaciones"""
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=('Top 10 Pasos más Lentos', 'Top 10 Mayor Uso de Memoria',
                       'Top 10 Mayor I/O', 'Correlación: Tiempo vs Recursos'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'bar'}, {'type': 'scatter'}]]
    )
    
    # Top 10 más lentos
    top_time = df.nlargest(10, 'duration_minutes').sort_values('duration_minutes')
    fig.add_trace(
        go.Bar(y=top_time['step'], x=top_time['duration_minutes'],
               orientation='h', marker_color='crimson',
               text=[f"{v:.2f}" for v in top_time['duration_minutes']],
               textposition='outside', showlegend=False),
        row=1, col=1
    )
    
    # Top 10 memoria
    top_mem = df.nlargest(10, 'max_memory_gb').sort_values('max_memory_gb')
    fig.add_trace(
        go.Bar(y=top_mem['step'], x=top_mem['max_memory_gb'],
               orientation='h', marker_color='orange',
               text=[f"{v:.2f}" for v in top_mem['max_memory_gb']],
               textposition='outside', showlegend=False),
        row=1, col=2
    )
    
    # Top 10 I/O
    top_io = df.nlargest(10, 'io_total_mb').sort_values('io_total_mb')
    fig.add_trace(
        go.Bar(y=top_io['step'], x=top_io['io_total_mb'],
               orientation='h', marker_color='green',
               text=[f"{v:.0f}" for v in top_io['io_total_mb']],
               textposition='outside', showlegend=False),
        row=2, col=1
    )
    
    # Correlación múltiple
    fig.add_trace(
        go.Scatter(
            x=df['duration_minutes'],
            y=df['max_memory_gb'],
            mode='markers',
            marker=dict(
                size=df['io_total_mb']/50,
                color=df['cpu_percent'],
                colorscale='Rainbow',
                showscale=True,
                colorbar=dict(title="CPU %")
            ),
            text=df['step'],
            hovertemplate='<b>%{text}</b><br>Tiempo: %{x:.2f} min<br>Memoria: %{y:.3f} GB<extra></extra>',
            showlegend=False
        ),
        row=2, col=2
    )
    
    fig.update_xaxes(title_text="Minutos", row=1, col=1)
    fig.update_xaxes(title_text="GB", row=1, col=2)
    fig.update_xaxes(title_text="MB", row=2, col=1)
    fig.update_xaxes(title_text="Duración (min)", row=2, col=2)
    
    fig.update_yaxes(title_text="Paso", row=1, col=1)
    fig.update_yaxes(title_text="Paso", row=1, col=2)
    fig.update_yaxes(title_text="Paso", row=2, col=1)
    fig.update_yaxes(title_text="Memoria (GB)", row=2, col=2)
    
    fig.update_layout(
        title_text="Análisis Comparativo de Pasos Críticos",
        height=900,
        template='plotly_white'
    )
    
    fig.write_html(f"{output_dir}/07_comparison_charts.html")
    print("✓ Gráfico 7: Comparaciones y correlaciones")

def create_index_html(output_dir, df):
    """Crear índice HTML mejorado con todos los gráficos y estadísticas"""
    html_files = sorted([f for f in os.listdir(output_dir) if f.endswith('.html') and f != 'index.html'])
    
    # Calcular estadísticas globales
    total_time_min = df['duration_minutes'].sum()
    total_time_sec = df['duration_seconds'].sum()
    total_memory_gb = df['max_memory_gb'].sum()
    avg_cpu = df['cpu_percent'].mean()
    total_io_gb = df['io_total_mb'].sum() / 1024
    num_steps = len(df)
    
    # Convertir tiempo total a formato legible
    hours = int(total_time_min // 60)
    minutes = int(total_time_min % 60)
    seconds = int(total_time_sec % 60)
    
    html_content = f"""
<!DOCTYPE html>
<html>
<head>
    <title>Performance Report - QIIME2 Pipeline</title>
    <meta charset="UTF-8">
    <style>
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }}
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            padding: 30px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
        }}
        h1 {{
            color: #2c3e50;
            border-bottom: 4px solid #3498db;
            padding-bottom: 15px;
            margin-top: 0;
            font-size: 2.5em;
        }}
        h2 {{
            color: #34495e;
            margin-top: 40px;
            font-size: 1.8em;
            border-left: 5px solid #3498db;
            padding-left: 15px;
        }}
        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }}
        .stat-card {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.3s;
        }}
        .stat-card:hover {{
            transform: translateY(-5px);
            box-shadow: 0 6px 12px rgba(0,0,0,0.2);
        }}
        .stat-value {{
            font-size: 2.5em;
            font-weight: bold;
            margin: 10px 0;
        }}
        .stat-label {{
            font-size: 0.9em;
            opacity: 0.9;
            text-transform: uppercase;
            letter-spacing: 1px;
        }}
        .graph-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
            gap: 25px;
            margin: 30px 0;
        }}
        .graph-card {{
            background: white;
            border-radius: 12px;
            padding: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.3s, box-shadow 0.3s;
            border: 1px solid #e0e0e0;
        }}
        .graph-card:hover {{
            transform: translateY(-8px);
            box-shadow: 0 12px 24px rgba(0,0,0,0.15);
        }}
        .graph-card h3 {{
            margin-top: 0;
            color: #2980b9;
            font-size: 1.3em;
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .graph-card h3::before {{
            content: "📊";
            font-size: 1.2em;
        }}
        .graph-card a {{
            display: inline-block;
            margin: 10px 0;
            padding: 10px 20px;
            background: linear-gradient(135deg, #3498db 0%, #2980b9 100%);
            color: white;
            text-decoration: none;
            border-radius: 6px;
            transition: all 0.3s;
            font-weight: 500;
        }}
        .graph-card a:hover {{
            background: linear-gradient(135deg, #2980b9 0%, #1c5d8b 100%);
            transform: scale(1.05);
        }}
        iframe {{
            width: 100%;
            height: 600px;
            border: 2px solid #ddd;
            border-radius: 8px;
            margin: 10px 0;
        }}
        .info-box {{
            background: #e8f4f8;
            border-left: 5px solid #3498db;
            padding: 20px;
            margin: 20px 0;
            border-radius: 8px;
        }}
        .footer {{
            text-align: center;
            margin-top: 50px;
            padding-top: 20px;
            border-top: 2px solid #ddd;
            color: #7f8c8d;
        }}
        .badge {{
            display: inline-block;
            padding: 5px 12px;
            background: #3498db;
            color: white;
            border-radius: 20px;
            font-size: 0.85em;
            margin: 5px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>📊 Performance Report - QIIME2 Pipeline</h1>
        <p style="font-size: 1.1em; color: #555;">
            <strong>Proyecto:</strong> {os.path.basename(os.path.dirname(output_dir))} &nbsp;|&nbsp;
            <strong>Generado:</strong> {pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}
        </p>
        
        <div class="info-box">
            <h3 style="margin-top: 0;">ℹ️ Acerca de este reporte</h3>
            <p>Este reporte contiene análisis detallado del rendimiento del pipeline QIIME2, incluyendo métricas de tiempo de ejecución, uso de CPU, consumo de memoria y operaciones de I/O de disco. Use estos datos para optimizar su pipeline y comparar diferentes configuraciones.</p>
        </div>
        
        <h2>📈 Resumen General del Pipeline</h2>
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">⏱️ Tiempo Total</div>
                <div class="stat-value">{hours}h {minutes}m</div>
                <div class="stat-label">{total_time_sec:.0f} segundos</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">🧠 Memoria Total</div>
                <div class="stat-value">{total_memory_gb:.2f} GB</div>
                <div class="stat-label">Acumulada en todos los pasos</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">🔥 CPU Promedio</div>
                <div class="stat-value">{avg_cpu:.1f}%</div>
                <div class="stat-label">Utilización promedio</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">💾 I/O Total</div>
                <div class="stat-value">{total_io_gb:.2f} GB</div>
                <div class="stat-label">Lectura + Escritura</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">📋 Pasos Ejecutados</div>
                <div class="stat-value">{num_steps}</div>
                <div class="stat-label">Total de operaciones</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">⚡ Tiempo Promedio</div>
                <div class="stat-value">{total_time_min/num_steps:.1f} min</div>
                <div class="stat-label">Por paso</div>
            </div>
        </div>
        
        <h2>📊 Gráficos Principales</h2>
        <div class="graph-grid">
"""
    
    # Descripción de cada gráfico
    graph_descriptions = {
        '01': 'Muestra la duración de cada paso del pipeline. Identifica los cuellos de botella en tiempo de ejecución.',
        '02': 'Analiza el consumo máximo de memoria RAM en cada paso. Útil para dimensionar recursos.',
        '03': 'Porcentaje de uso de CPU en cada paso. Indica qué pasos son intensivos en procesamiento.',
        '04': 'Operaciones de entrada/salida de disco (lectura y escritura). Identifica pasos con alto uso de disco.',
        '05': 'Vista general de todos los recursos (tiempo, memoria, CPU, I/O) en un solo dashboard.',
        '06': 'Tabla detallada con todas las métricas de cada paso para análisis numérico.',
        '07': 'Comparación de los pasos más críticos y análisis de correlaciones entre recursos.'
    }
    
    # Agregar gráficos principales
    main_plots = [f for f in html_files if not f.startswith('timeseries_')]
    for plot_file in main_plots:
        plot_num = plot_file.split('_')[0]
        plot_name = plot_file.replace('.html', '').replace('_', ' ').title()
        description = graph_descriptions.get(plot_num, 'Análisis de rendimiento del pipeline.')
        
        html_content += f"""
        <div class="graph-card">
            <h3>{plot_name}</h3>
            <p style="color: #666; font-size: 0.9em;">{description}</p>
            <a href="{plot_file}" target="_blank">🔍 Ver en pantalla completa →</a>
            <iframe src="{plot_file}"></iframe>
        </div>
"""
    
    html_content += """
        </div>
"""
    
    # Series de tiempo si existen
    timeseries_plots = [f for f in html_files if f.startswith('timeseries_')]
    if timeseries_plots:
        html_content += """
        <h2>⏲️ Series de Tiempo por Paso</h2>
        <p style="color: #666;">Métricas del sistema capturadas en tiempo real durante la ejecución de cada paso.</p>
        <div class="graph-grid">
"""
        
        for plot_file in timeseries_plots:
            step_name = plot_file.replace('timeseries_', '').replace('.html', '').replace('_', ' ').title()
            html_content += f"""
        <div class="graph-card">
            <h3>{step_name}</h3>
            <p style="color: #666; font-size: 0.9em;">Monitoreo continuo de CPU, memoria y disco durante la ejecución.</p>
            <a href="{plot_file}" target="_blank">🔍 Ver en pantalla completa →</a>
            <iframe src="{plot_file}"></iframe>
        </div>
"""
        
        html_content += """
        </div>
"""
    
    # Top insights
    slowest_step = df.loc[df['duration_minutes'].idxmax()]
    memory_step = df.loc[df['max_memory_gb'].idxmax()]
    io_step = df.loc[df['io_total_mb'].idxmax()]
    
    html_content += f"""
        <h2>🔍 Insights Clave</h2>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin: 20px 0;">
            <div style="background: #fff3cd; padding: 20px; border-radius: 10px; border-left: 5px solid #ffc107;">
                <h4 style="margin-top: 0; color: #856404;">⏱️ Paso más lento</h4>
                <p style="font-size: 1.1em; margin: 10px 0;"><strong>{slowest_step['step']}</strong></p>
                <p style="color: #666;">Duración: <strong>{slowest_step['duration_minutes']:.2f} minutos</strong></p>
                <span class="badge">Optimizar tiempo</span>
            </div>
            <div style="background: #f8d7da; padding: 20px; border-radius: 10px; border-left: 5px solid #dc3545;">
                <h4 style="margin-top: 0; color: #721c24;">🧠 Mayor uso de memoria</h4>
                <p style="font-size: 1.1em; margin: 10px 0;"><strong>{memory_step['step']}</strong></p>
                <p style="color: #666;">Memoria: <strong>{memory_step['max_memory_gb']:.2f} GB</strong></p>
                <span class="badge">Optimizar memoria</span>
            </div>
            <div style="background: #d1ecf1; padding: 20px; border-radius: 10px; border-left: 5px solid #17a2b8;">
                <h4 style="margin-top: 0; color: #0c5460;">💾 Mayor I/O de disco</h4>
                <p style="font-size: 1.1em; margin: 10px 0;"><strong>{io_step['step']}</strong></p>
                <p style="color: #666;">I/O: <strong>{io_step['io_total_mb']:.0f} MB</strong></p>
                <span class="badge">Optimizar disco</span>
            </div>
        </div>
        
        <h2>💡 Recomendaciones</h2>
        <div class="info-box" style="background: #d4edda; border-left-color: #28a745;">
            <h4 style="margin-top: 0; color: #155724;">✅ Optimizaciones sugeridas</h4>
            <ul style="color: #155724; line-height: 1.8;">
                <li><strong>Tiempo:</strong> El paso "{slowest_step['step']}" consume {(slowest_step['duration_minutes']/total_time_min*100):.1f}% del tiempo total. Considere paralelización o ajuste de parámetros.</li>
                <li><strong>Memoria:</strong> El pico de memoria es {memory_step['max_memory_gb']:.2f} GB. Asegúrese de tener al menos {memory_step['max_memory_gb']*1.5:.1f} GB de RAM disponible.</li>
                <li><strong>I/O:</strong> Total de {total_io_gb:.2f} GB transferidos. Use discos SSD para mejor rendimiento.</li>
                <li><strong>CPU:</strong> Utilización promedio de {avg_cpu:.1f}%. {'Considere aumentar hilos si es bajo.' if avg_cpu < 70 else 'Buen aprovechamiento de CPU.'}</li>
            </ul>
        </div>
        
        <div class="footer">
            <p>Generado por QIIME2 Pipeline Performance Monitor</p>
            <p style="font-size: 0.9em;">© 2024 - Análisis automatizado de rendimiento</p>
        </div>
    </div>
</body>
</html>
"""
    
    with open(f"{output_dir}/index.html", 'w', encoding='utf-8') as f:
        f.write(html_content)
    
    print("✓ Índice HTML creado con estadísticas completas")

def plot_dstat_timeseries(metrics_dir, output_dir):
    """Gráficos de series de tiempo de métricas del sistema"""
    dstat_files = list(Path(metrics_dir).glob("*_dstat.csv"))
    
    if not dstat_files:
        print("⚠️  No se encontraron archivos dstat")
        return
    
    for dstat_file in dstat_files:
        step_name = dstat_file.stem.replace('_dstat', '')
        
        try:
            df = pd.read_csv(str(dstat_file), skiprows=6)
        except Exception as e:
            print(f"⚠️  Error al cargar {dstat_file}: {e}")
            continue
        
        if df.empty:
            continue
        
        # Crear gráfico de series de tiempo
        fig = make_subplots(
            rows=3, cols=1,
            subplot_titles=(f'{step_name} - CPU Usage', 
                          f'{step_name} - Memory Usage', 
                          f'{step_name} - Disk I/O'),
            vertical_spacing=0.1
        )
        
        # CPU
        if 'usr' in df.columns and 'sys' in df.columns:
            fig.add_trace(
                go.Scatter(y=df['usr'], name='User CPU', mode='lines', 
                          line=dict(color='blue', width=2)),
                row=1, col=1
            )
            fig.add_trace(
                go.Scatter(y=df['sys'], name='System CPU', mode='lines', 
                          line=dict(color='red', width=2)),
                row=1, col=1
            )
        
        # Memoria
        if 'used' in df.columns:
            memory_mb = df['used'] / 1024 / 1024
            fig.add_trace(
                go.Scatter(y=memory_mb, name='Memoria usada', mode='lines', 
                          line=dict(color='orange', width=2),
                          fill='tozeroy'),
                row=2, col=1
            )
        
        # Disco
        if 'read' in df.columns and 'writ' in df.columns:
            read_mb = df['read'] / 1024
            write_mb = df['writ'] / 1024
            fig.add_trace(
                go.Scatter(y=read_mb, name='Lectura', mode='lines', 
                          line=dict(color='green', width=2)),
                row=3, col=1
            )
            fig.add_trace(
                go.Scatter(y=write_mb, name='Escritura', mode='lines', 
                          line=dict(color='purple', width=2)),
                row=3, col=1
            )
        
        fig.update_xaxes(title_text="Tiempo (segundos)", row=1, col=1)
        fig.update_xaxes(title_text="Tiempo (segundos)", row=2, col=1)
        fig.update_xaxes(title_text="Tiempo (segundos)", row=3, col=1)
        
        fig.update_yaxes(title_text="% CPU", row=1, col=1)
        fig.update_yaxes(title_text="MB", row=2, col=1)
        fig.update_yaxes(title_text="MB/s", row=3, col=1)
        
        fig.update_layout(
            title_text=f"Métricas en Tiempo Real - {step_name}",
            height=900,
            template='plotly_white',
            showlegend=True
        )
        
        safe_name = step_name.replace('/', '_')
        fig.write_html(f"{output_dir}/timeseries_{safe_name}.html")
    
    print(f"✓ Gráficos de series de tiempo: {len(dstat_files)} archivos procesados")

def main():
    if len(sys.argv) != 4:
        print("Usage: python generate_plots.py <logs_dir> <metrics_dir> <output_dir>")
        sys.exit(1)
    
    logs_dir = sys.argv[1]
    metrics_dir = sys.argv[2]
    output_dir = sys.argv[3]
    
    timing_file = f"{logs_dir}/timing_summary.csv"
    
    print("\n" + "="*60)
    print("Generando gráficos de rendimiento COMPLETOS...")
    print("="*60 + "\n")
    
    # Cargar datos
    df_timing = load_timing_data(timing_file)
    
    # Generar todos los gráficos
    plot_timing_summary(df_timing, output_dir)
    plot_memory_usage(df_timing, output_dir)
    plot_cpu_usage(df_timing, output_dir)
    plot_io_analysis(df_timing, output_dir)
    plot_resource_dashboard(df_timing, output_dir)
    plot_performance_summary(df_timing, output_dir)
    plot_comparison_charts(df_timing, output_dir)
    plot_dstat_timeseries(metrics_dir, output_dir)
    
    # Crear índice con estadísticas
    create_index_html(output_dir, df_timing)
    
    print("\n" + "="*60)
    print(f"    Todos los gráficos generados exitosamente")
    print("="*60)
    print(f"\n  Ubicación: {output_dir}")
    print(f"    Abrir en navegador: {output_dir}/index.html\n")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

# ============================================================================
# EJECUTAR SCRIPT PYTHON
# ============================================================================

echo "Generando gráficos completos..."
echo ""

/opt/conda/bin/conda run -n qiime2 python "$PLOTS_DIR/generate_plots.py" \
  "$LOGS_DIR" \
  "$METRICS_DIR" \
  "$PLOTS_DIR"

if [[ $? -eq 0 ]]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║           GRÁFICOS GENERADOS EXITOSAMENTE              ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo ""
  echo " Ubicación: $PLOTS_DIR"
  echo ""
  echo " Para visualizar, abra en su navegador:"
  echo "   file://$PLOTS_DIR/index.html"
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