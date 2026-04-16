# AVA Nexus: Biometric Intelligence System
### *Intelligent Sleep Monitoring Platform for Restless Legs Syndrome (RLS) Diagnosis*

**AVA Nexus** es un ecosistema integral de grado médico diseñado para la detección y monitoreo del Síndrome de Piernas Inquietas (SPI). El sistema combina hardware embebido de alta velocidad, telemetría inalámbrica y análisis predictivo mediante Redes Neuronales Secuenciales (LSTM) en la nube.

---

## 🚀 Características Principales

* **Telemetría de Alta Fidelidad:** Muestreo estricto a **50Hz** para señales EMG, IMU y PPG.
* **Agente AVA (AI Core):** Motor de inteligencia basado en una arquitectura **LSTM + Attention Mechanism** entrenada para identificar patrones de espasticidad con alta confianza probabilística.
* **Arquitectura Híbrida:** Procesamiento local en MATLAB sincronizado con microservicios en **Google Cloud Platform (GCP)**.
* **Reportes de Grado Clínico:** Generación automática de informes en formato **PDF (Vectorial)**, **EDF+ (Estándar Médico)** y **TXT (Data Cruda)**.

---

## 🛠️ Stack Tecnológico

### **Hardware (Nodes)**
* **Nodos Inteligentes:** ESP32 (Dual-Core) con transmisión de datagramas vía UDP/Wi-Fi.
* **Sensores:** * `Ankle Node`: MPU6050 (6-DOF) + EMG Superficial (Rectificación y Envolvente).
  * `Biceps Node`: MAX30105 (Fotopletismografía de alta sensibilidad para SpO2 y BPM).

### **Software & Cloud**
* **Dashboard Central:** MATLAB (App Designer) para procesamiento digital de señales (DSP) y visualización en tiempo real.
* **IA & Backend:** Python 3.x con FastAPI, TensorFlow/Keras para inferencia de modelos y despliegue en **Cloud Run (Docker Containers)**.

---

## 📁 Estructura del Repositorio

* `/Firmware`: Código fuente C++ para los nodos inteligentes (ESP32).
* `/Dashboard`: Script maestro de MATLAB y recursos de la interfaz de usuario (AVA Nexus Dashboard).
* `/Cloud-IA`: Modelo de Red Neuronal `.keras` y endpoint de FastAPI para la nube.
* `/Docs`: Documentación técnica, esquemas de conexión y especificaciones del sistema.

---

## 📊 Metodología de Diagnóstico

El sistema captura el **Vector de Magnitud (SVM)** y la activación muscular (**EMG**). Estos datos se empaquetan en tensores secuenciales de 500 muestras que son analizados por el **Agente AVA**. El sistema no solo detecta la anomalía, sino que calcula la confianza del diagnóstico en tiempo real, permitiendo un seguimiento objetivo y cuantitativo de la evolución del trastorno de piernas inquietas.

---

## 🛡️ Confidencialidad y Estándares
Este proyecto está diseñado siguiendo los principios de exportación de datos médicos estándares (**European Data Format - EDF+**), garantizando que la información capturada sea compatible con software de análisis clínico especializado y mantenga la integridad de los datos del paciente.

---
*Desarrollado como solución tecnológica para el diagnóstico avanzado de trastornos del sueño.*
