# AVA Nexus v6.2 (Medical Grade Edition)
### *Plataforma de Monitoreo Ambulatorio Edge-Computing para el Síndrome de Piernas Inquietas (SPI)*

**AVA Nexus** es un sistema modular integral de grado médico diseñado para la detección y monitoreo continuo del Síndrome de Piernas Inquietas (SPI/RLS). En su versión más reciente, el sistema ha evolucionado hacia una arquitectura de **Edge Computing**, procesando rigurosamente las métricas clínicas de la *American Academy of Sleep Medicine (AASM)* de forma local. Esto garantiza un análisis en tiempo real, protección contra desbordamientos de memoria (OOM-Safe) y latencia cero al eliminar la dependencia de servidores en la nube.

---

## ✨ Características Principales (V6.2)

* **Monitoreo Multimodal de Grado Clínico:** Adquisición simultánea y sincronizada de Electromiografía tibial (EMG), Actigrafía (SVM), Frecuencia Cardíaca (BPM) y Saturación de Oxígeno (SpO2).
* **Endurance & OOM-Safe:** El núcleo de MATLAB está optimizado mediante *Ring Buffers* y carga por *Chunks*, permitiendo grabar estudios completos de **hasta 10 horas continuas (1.8 millones de muestras)** en computadoras estándar (mínimo 8GB RAM) sin riesgo de cuelgues o fugas de memoria.
* **Telemetría Zero-Drift:** Sincronización de nodos de hardware mediante un acumulador de microsegundos (`micros()`) que garantiza un muestreo perfecto y libre de deriva a **50.00 Hz exactos** durante toda la noche.
* **Procesamiento AASM en el Borde:** Sustitución de IA en la nube por un motor determinista ultrarrápido que aplica las reglas oficiales de la AASM para detectar y agrupar Movimientos Periódicos de las Extremidades (PLMS) y diagnosticar SPI.
* **Exportación de Alta Precisión:** Generación automática de datasets universales en **CSV** (12 decimales de precisión médica) y reportes de anotaciones clínicas en **TXT** para validación médica o investigación (Ground Truth).

---

## 🛠 Stack Tecnológico

### **Hardware (Nodos Inteligentes ESP32)**
* **Procesamiento:** Microcontroladores **ESP32** con conectividad Wi-Fi (UDP) optimizados para evitar bloqueos del bus I2C.
* **Nodo Tobillo (Maestro):** Acelerómetro/Giroscopio **MPU6050** de 6 ejes para cinemática y frontend **AD8232** para capturar biopotenciales EMG en la pierna.
* **Nodo Bíceps (Esclavo):** Sensor óptico reflectivo **MAX30102** procesando fotopletismografía (PPG) pura para extraer SpO2 y frecuencia cardíaca.
* **Autonomía:** Gestión de energía mediante módulos **TP4056** preparados para >10 horas de funcionamiento.

### **Software (Dashboard Analítico)**
* **Núcleo de Procesamiento:** Desarrollado en **MATLAB (R2018b+)**, implementando *Thread-Safe Logging*, filtrado EMA (Exponential Moving Average) en tiempo real y *Graceful Disconnects* ante fallos de red.
* **Interfaz Dinámica:** UI con renderizado por lotes (*batching* gráfico) y *downsampling* visual para mantener 25 FPS sin saturar la GPU.

---

## 🔬 Metodología de Evaluación (Reglas AASM)

AVA Nexus abandona las cajas negras y audita el sueño aplicando estrictamente la fisiología clínica:

1. **Detección Base (Fusión Sensorial):** Combinación multiplicativa de la envolvente EMG y la acelerometría SVM para aislar el movimiento primario.
2. **Micro-cortes (Debounce):** Fusión automática de eventos separados por menos de 0.5 segundos.
3. **Validación PLM:** Un espasmo se considera un *Movimiento Periódico de las Piernas (PLM)* válido si su duración neta está estrictamente entre **0.5s y 10.0s**.
4. **Diagnóstico SPI:** El sistema agrupa los PLMs. Si ocurren **≥ 4 eventos** separados por un intervalo de descanso de entre **5 y 90 segundos**, se cataloga como una serie SPI positiva.
5. **Correlación Autonómica (Arousal):** Monitoreo continuo de SpO2 y fluctuaciones de BPM para diferenciar el SPI de trastornos respiratorios del sueño (como la Apnea Obstructiva).

---

## 📂 Estructura del Repositorio

* `/Firmware`: Código fuente en C++ para los nodos ESP32 (Tobillo y Bíceps), con algoritmos *Drift-Free* y auto-calibración.
* `/Dashboard`: Archivos fuente del núcleo de MATLAB (`AVA_Core_System.m`) con la arquitectura V6.2 Endurance.

---

## 🛡 Confidencialidad, Respaldo y Estándares

Pensado para la usabilidad clínica en entornos domiciliarios, el sistema incluye un mecanismo de **Backup Incremental Oculto** en caché que salva los datos cada 5 minutos, garantizando que ninguna falla eléctrica o desconexión corrompa el estudio de un paciente. Los datos crudos se exportan en formatos abiertos compatibles con Pandas (Python), R y Excel, democratizando la investigación médica del sueño.

---
*Desarrollado como solución tecnológica integral para la democratización del diagnóstico avanzado en medicina del sueño.*

---
## ⚖ Licencia

Este proyecto está bajo la Licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.
