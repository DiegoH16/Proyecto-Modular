# AVA Nexus
### *Plataforma de Monitoreo y Análisis para el Síndrome de Piernas Inquietas (SPI)*

**AVA Nexus** es un sistema modular integral de grado médico diseñado para la detección, monitoreo continuo y análisis del Síndrome de Piernas Inquietas (SPI/RLS). En su versión **V7.5**, el sistema ha evolucionado para funcionar como una arquitectura de **Edge Computing** en tiempo real (con hardware propio) y como un **Analizador Universal de archivos EDF** hospitalarios, procesando rigurosamente las métricas clínicas de la *American Academy of Sleep Medicine (AASM)* de forma local.

---

## Características Principales (V7.5)

* **Analizador AASM Determinista:** Sustitución de "cajas negras" por un motor matemático que aplica estrictamente los manuales de la AASM para diferenciar Movimientos Aislados (LM) de Series Patológicas (PLM).
* **Convertidor Universal EDF a CSV:** Integra una herramienta que lee estudios polisomnográficos hospitalarios (`.edf`), despliega un **Diccionario Clínico** para traducir la nomenclatura de los sensores (EEG, EOG, EMG, SpO2), aísla los canales necesarios y los sincroniza matemáticamente a 100 Hz, rellenando micro-cortes para evitar desbordamientos de datos.
* **Actigrafía Sintética & Compuerta de Ruido (Noise Gate):** Cuando procesa datos de hospital sin acelerómetro, el sistema genera una *Actigrafía Virtual* calculando la derivada de la energía cinética del EMG. Además, blinda el análisis contra escalas ruidosas usando un umbral dinámico basado en la desviación estándar del reposo del paciente.
* **Fusión Bilateral Automática:** Capacidad de importar EMG de ambas piernas simultáneamente, aplicando la regla clínica de superposición para crear una envolvente consolidada.
* **Monitoreo Multimodal Hardware:** Adquisición simultánea y sincronizada por telemetría (UDP) de EMG tibial, Actigrafía (SVM), Frecuencia Cardíaca (BPM) y SpO2 a **100.00 Hz exactos**, libres de deriva (*Zero-Drift*).

---

## Stack Tecnológico

### **Software (Dashboard Analítico AVA Core)**
* **Núcleo de Procesamiento:** Desarrollado en **MATLAB**, optimizado mediante *Ring Buffers* y carga por *Chunks*. Permite grabar y analizar estudios de **hasta 10 horas continuas (más de 3.6 millones de muestras)** sin cuelgues ni fugas de memoria (OOM-Safe).
* **Interfaz de Alta Eficiencia:** UI con limitador de refresco adaptativo (`limitrate`) y líneas de guía no destructivas, garantizando latencia cero en la captura de paquetes UDP.

### **Hardware Domiciliario (Nodos ESP32)**
* **Procesamiento:** Microcontroladores **ESP32** con conectividad Wi-Fi (UDP).
* **Nodo Tobillo:** Acelerómetro **MPU6050** de 6 ejes (cinemática) y frontend **AD8232** (biopotenciales EMG).
* **Nodo Bíceps:** Sensor óptico **MAX30102** con procesamiento DSP robusto para extraer SpO2 y frecuencia cardíaca descartando artefactos de movimiento.

---

## Metodología de Evaluación (Reglas AASM Aplicadas)

AVA Nexus audita el sueño aplicando la fisiología clínica paso a paso:

1. **Umbral Dinámico (Amplitud):** El movimiento debe superar en al menos **8 μV** la línea base del reposo local (aplanado mediante filtros de media móvil para evitar derivas).
2. **Micro-cortes (Fusión):** Contracciones separadas por **< 0.5 segundos** se unen en un solo evento.
3. **Validación de Movimiento Aislado (LM):** El espasmo debe durar estrictamente entre **0.5s y 10.0s**. Movimientos más cortos (micro-temblores) o más largos (cambios de postura) se descartan.
4. **Agrupación Periódica (Serie PLM):** * Se requiere un mínimo de **4 LMs consecutivos**.
   * **Periodicidad:** El inicio de un LM y el siguiente deben estar separados por **5.0 a 90.0 segundos**.
   * **Excepción de Movimiento Intercalado (iLM):** Si un espasmo ocurre a menos de 5.0 segundos del anterior, el sistema *no* lo suma a la serie, pero *tampoco la rompe*, midiendo el tiempo contra el siguiente evento válido para mantener la cadena clínica.
5. **Correlación Autonómica:** Referencia cruzada con SpO2 y BPM para aislar LMs secundarios a eventos respiratorios.

---

## Estructura del Repositorio

* `/Firmware`: Código fuente en C++ para los nodos ESP32 con algoritmos *Drift-Free* y auto-calibración.
* `/Dashboard`: Archivo fuente principal `AVA_Core_System.m` que contiene la interfaz gráfica, el motor de adquisición UDP, el convertidor EDF y el procesador AASM.

---

## Respaldo y Estandarización

Pensado para la usabilidad en entornos domiciliarios e investigativos, el sistema incluye un mecanismo de **Backup Incremental Oculto** (`.cache_incremental`) que salva los datos cada pocos minutos. Los datos procesados se exportan como **CSV** (con formato estandarizado), permitiendo la fácil integración con herramientas de ciencia de datos como Pandas (Python) o R, y facilitando la validación del diagnóstico de SPI por parte de los neurólogos.

---
*Desarrollado como solución tecnológica integral para la democratización del diagnóstico avanzado en medicina del sueño.*

---

## Licencia

Este proyecto está bajo la [Apache License 2.0]. Consulta el archivo [LICENSE](LICENSE) para más detalles.

---

## Aviso Legal (Disclaimer)
Este software se proporciona con fines de investigación académica en el área del Síndrome de Piernas Inquietas (SPI). 
**IMPORTANTE:** No es un dispositivo médico certificado. Los autores no asumen responsabilidad por diagnósticos o decisiones clínicas tomadas con base en el análisis de estas señales biométricas. El uso en entornos médicos debe ser supervisado por personal de salud certificado.
