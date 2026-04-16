# AVA Nexus: Biometric Intelligence System
### *Plataforma de Monitoreo Inteligente para el Diagnóstico del Síndrome de Piernas Inquietas (SPI)*

**AVA Nexus** es un sistema modular integral de grado médico diseñado para la detección y monitoreo del Síndrome de Piernas Inquietas (SPI/RLS). El sistema utiliza una arquitectura distribuida de nodos inteligentes para capturar movimientos periódicos de las extremidades (PLMS) y correlacionarlos con parámetros fisiológicos en tiempo real.

---

## 🚀 Características Principales

* **Monitoreo Multimodal:** Adquisición simultánea de Electromiografía (EMG), Actigrafía (SVM), Frecuencia Cardíaca (BPM) y Saturación de Oxígeno (SpO2).
* **Telemetría de Alta Fidelidad:** Sincronización de nodos con una latencia inferior a los 20ms para una precisión diagnóstica superior.
* **Algoritmos de Procesamiento (DSP):** Implementación de filtros EMA y detección de envolvente lineal para aislar la actividad del músculo tibial anterior.
* **Reportes de Grado Clínico:** Generación automática de informes detallados en formatos **PDF**, **EDF+ (European Data Format)** y **TXT** para su integración en el seguimiento médico.

---

## 🛠️ Stack Tecnológico

### **Hardware (Nodos Inteligentes)**

* **Unidad Central:** Microcontroladores **ESP32-S3** con conectividad Wi-Fi y Bluetooth.
* **Sensorización Especializada:**
    * **Nodo Tobillo:** Acelerómetro/Giroscopio **MPU6050** de 6 ejes y frontend **AD8232** para biopotenciales de EMG.
    * **Nodo Bíceps:** Sensor óptico reflectivo **MAX30102** para fotopletismografía (PPG) de bajo consumo.
* **Autonomía:** Gestión de energía mediante módulos **TP4056** para sesiones de monitoreo nocturno de ≥8 horas.

### **Software & Cloud**
* **Dashboard Central:** Interfaz desarrollada en **MATLAB** para el pre-filtrado de señales, rectificación de ondas y visualización dinámica.
* **Análisis Inteligente:** Algoritmos adaptativos para el cálculo de umbrales de movimiento y detección de microdespertares autonómicos.

---

## 📁 Estructura del Repositorio

* `/Firmware`: Código fuente C++ para los nodos inteligentes (ESP32).
* `/Dashboard`: Script maestro de MATLAB y recursos de la interfaz de usuario.
* `/ava_cloud`: Modelo de Red Neuronal `.keras` y endpoint de FastAPI para la nube.
* `/Docs`: Documentación técnica, esquemas de conexión y especificaciones del sistema.

---

## 📊 Metodología de Evaluación

El sistema identifica marcadores objetivos esenciales para evaluar la severidad del SPI:

1. **Actividad Motora:** Detección de picos de aceleración mediante la magnitud del vector total (SVM).
2. **Correlación Autonómica:** Identificación de incrementos súbitos en la frecuencia cardíaca (≥ 10-15 BPM) asociados a eventos de movimiento.
3. **Diferencial Clínico:** Monitoreo de SpO2 (rango normal 95%-100%) para distinguir entre SPI puro y trastornos respiratorios como la Apnea Obstructiva.

---

## 🛡️ Confidencialidad y Estándares
Este proyecto está diseñado bajo los requerimientos de usabilidad clínica, ofreciendo una solución portátil, cómoda y de bajo costo para el monitoreo domiciliario del sueño. El uso del formato **EDF+** asegura la compatibilidad con los estándares internacionales de polisomnografía.



---
*Desarrollado como solución tecnológica para la democratización del diagnóstico avanzado en medicina del sueño.*

---

## 🛡️ Confidencialidad y Estándares
[cite_start]Este proyecto está diseñado bajo los requerimientos de usabilidad clínica, ofreciendo una solución portátil, cómoda y de bajo costo para el monitoreo domiciliario del sueño[cite: 87, 163, 169].

---
[cite_start]*Desarrollado como solución tecnológica para la democratización del diagnóstico avanzado en medicina del sueño[cite: 203].*
