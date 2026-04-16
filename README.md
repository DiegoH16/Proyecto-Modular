# AVA Nexus: Biometric Intelligence System
### *Plataforma de Monitoreo Inteligente para el Diagnóstico del Síndrome de Piernas Inquietas (SPI)*

[cite_start]**AVA Nexus** es un sistema modular integral de grado médico diseñado para la detección y monitoreo del Síndrome de Piernas Inquietas (SPI/RLS). [cite_start]El sistema utiliza una arquitectura distribuida de nodos inteligentes para capturar movimientos periódicos de las extremidades (PLMS) y correlacionarlos con parámetros fisiológicos en tiempo real[cite: 9, 34].

---

## 🚀 Características Principales

* [cite_start]**Monitoreo Multimodal:** Adquisición simultánea de Electromiografía (EMG), Actigrafía (SVM), Frecuencia Cardíaca (BPM) y Saturación de Oxígeno (SpO2)[cite: 164].
* [cite_start]**Telemetría de Alta Fidelidad:** Sincronización de nodos con una latencia inferior a los 20ms para una precisión diagnóstica superior[cite: 183].
* [cite_start]**Algoritmos de Procesamiento (DSP):** Implementación de filtros EMA y detección de envolvente lineal para aislar la actividad del músculo tibial anterior[cite: 141, 184].
* [cite_start]**Reportes de Grado Clínico:** Generación automática de informes detallados en formatos **PDF**, **EDF+ (European Data Format)** y **TXT** para su integración en el seguimiento médico[cite: 83, 84].

---

## 🛠️ Stack Tecnológico

### **Hardware (Nodos Inteligentes)**
* [cite_start]**Unidad Central:** Microcontroladores **ESP32-S3** con conectividad Wi-Fi y Bluetooth[cite: 95, 106].
* [cite_start]**Sensorización Especializada[cite: 106]:**
    * [cite_start]`Tobillo`: Acelerómetro/Giroscopio **MPU6050** de 6 ejes y frontend **AD8232** para biopotenciales de EMG[cite: 98, 99].
    * [cite_start]`Bíceps`: Sensor óptico reflectivo **MAX30102** para fotopletismografía (PPG) de bajo consumo[cite: 97].
* [cite_start]**Autonomía:** Gestión de energía mediante módulos **TP4056** para sesiones de monitoreo nocturno de ≥8 horas[cite: 100, 106].

### **Software & Cloud**
* [cite_start]**Dashboard Central:** Interfaz desarrollada en **MATLAB** para el pre-filtrado de señales, rectificación de ondas y visualización dinámica[cite: 186, 191].
* [cite_start]**Análisis Inteligente:** Algoritmos adaptativos para el cálculo de umbrales de movimiento y detección de microdespertares autonómicos[cite: 136, 165].

---

## 📁 Estructura del Repositorio

* `/Firmware`: Código fuente C++ para los nodos inteligentes (ESP32).
* `/Dashboard`: Script maestro de MATLAB y recursos de la interfaz de usuario (AVA Nexus Dashboard).
* `/ava_cloud`: Modelo de Red Neuronal `.keras` y endpoint de FastAPI para la nube.
* `/Docs`: Documentación técnica, esquemas de conexión y especificaciones del sistema.

## 📊 Metodología de Evaluación

[cite_start]El sistema identifica marcadores objetivos esenciales para evaluar la severidad del SPI[cite: 34]:
* [cite_start]**Actividad Motora:** Detección de picos de aceleración mediante la magnitud del vector total (SVM)[cite: 156, 157].
* [cite_start]**Correlación Autonómica:** Identificación de incrementos súbitos en la FC (≥ 10-15 BPM) asociados a eventos de movimiento[cite: 150].
* [cite_start]**Diferencial Clínico:** Monitoreo de SpO2 (rango normal 95%-100%) para distinguir entre SPI puro y trastornos respiratorios como la Apnea Obstructiva[cite: 159, 160].

---

## 🛡️ Confidencialidad y Estándares
[cite_start]Este proyecto está diseñado bajo los requerimientos de usabilidad clínica, ofreciendo una solución portátil, cómoda y de bajo costo para el monitoreo domiciliario del sueño[cite: 87, 163, 169].

---
[cite_start]*Desarrollado como solución tecnológica para la democratización del diagnóstico avanzado en medicina del sueño[cite: 203].*
