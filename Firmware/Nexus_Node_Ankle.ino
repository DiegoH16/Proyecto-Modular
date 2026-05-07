/*
 * DISPOSITIVO TOBILLO: Movimientos (MPU6050) + EMG (Muestreo Continuo)
 * Hardware: ESP32 + MPU6050 (I2C) + Sensor EMG (Pin Analógico 4)
 * Modificado: Implementación de "Batching" y corrección de sintaxis.
 */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>

// --- CONFIGURACIÓN WI-FI ---
// CORREGIDO: Faltaban las comillas y los puntos y coma.
const char* ssid = "TU_SSID_AQUI"; 
const char* password = "TU_PASSWORD_AQUI"; 

// --- CONFIGURACIÓN UDP ---
const char* ip_computadora = "192.168.100.30";
const int puerto_udp = 8888; 

WiFiUDP udp;
Adafruit_MPU6050 mpu;

// --- PINES Y CONSTANTES ---
const int PIN_EMG = 4;                     // Pin ADC válido para el ESP32
const int FRECUENCIA_MUESTREO_HZ = 50;      // Coincide con la lectura en MATLAB
const unsigned long INTERVALO_MS = 1000 / FRECUENCIA_MUESTREO_HZ;

// --- VARIABLES DE FILTRADO (EMA) ---
float axFiltro = 0, ayFiltro = 0, azFiltro = 0, emgFiltro = 0;
const float ALPHA_IMU = 0.4;  // Filtro rápido para movimiento
const float ALPHA_EMG = 0.15; // Filtro suave para crear envolvente muscular
bool primeraLectura = true;   // Bandera para inicializar los filtros

// --- CONTROL DE TIEMPO ---
unsigned long tiempoInicio = 0;
unsigned long ultimoMuestreo = 0;

// --- OPTIMIZACIÓN DE ENVÍO (BATCHING) ---
const int TAMANO_LOTE = 5; // Agrupar 5 muestras por cada paquete UDP (10 Hz de envío)
int contadorMuestras = 0;
String payloadUDP = "";

void setup() {
  Serial.begin(115200);
  WiFi.begin(ssid, password);
  
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWi-Fi Conectado!");
  
  if (!mpu.begin()) {
    Serial.println("Error: MPU6050 no detectado. Revisa I2C.");
    while (1) { delay(10); } // Detener si falla
  }

  // Configuración de Hardware
  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ); // Filtro DLPF nativo (Anti-temblores)
  
  analogReadResolution(12); // Asegurar rango 0-4095 en ESP32

  // Reservar memoria para evitar fragmentación en el ESP32
  payloadUDP.reserve(300); // 5 líneas por paquete, aprox 40-50 caracteres por línea

  tiempoInicio = millis();
}

void loop() {
  unsigned long t_actual = millis();

  // Ejecución estricta a 50Hz (No bloqueante)
  if (t_actual - ultimoMuestreo >= INTERVALO_MS) {
    ultimoMuestreo = t_actual;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);
    
    int emgCrudo = analogRead(PIN_EMG);

    // Compuerta física: Ignorar picos anómalos (aceleración > 40 m/s^2)
    if (abs(a.acceleration.x) < 40.0 && abs(a.acceleration.y) < 40.0 && abs(a.acceleration.z) < 40.0) {
      
      if (primeraLectura) {
        axFiltro = a.acceleration.x;
        ayFiltro = a.acceleration.y;
        azFiltro = a.acceleration.z;
        emgFiltro = emgCrudo;
        primeraLectura = false;
      } else {
        // Aplicar Filtro EMA
        axFiltro = (ALPHA_IMU * a.acceleration.x) + ((1.0 - ALPHA_IMU) * axFiltro);
        ayFiltro = (ALPHA_IMU * a.acceleration.y) + ((1.0 - ALPHA_IMU) * ayFiltro);
        azFiltro = (ALPHA_IMU * a.acceleration.z) + ((1.0 - ALPHA_IMU) * azFiltro);
        emgFiltro = (ALPHA_EMG * emgCrudo)   + ((1.0 - ALPHA_EMG) * emgFiltro);
      }

      // 1. Concatenar los datos al payload en formato CSV
      payloadUDP += String(t_actual - tiempoInicio) + ",";
      payloadUDP += String(axFiltro, 2) + ",";
      payloadUDP += String(ayFiltro, 2) + ",";
      payloadUDP += String(azFiltro, 2) + ",";
      payloadUDP += String((int)emgFiltro) + "\n";
      
      contadorMuestras++;

      // 2. Enviar el lote si ya se juntaron suficientes muestras
      if (contadorMuestras >= TAMANO_LOTE) {
        udp.beginPacket(ip_computadora, puerto_udp);
        udp.print(payloadUDP);
        udp.endPacket();

        // 3. Limpiar variables para el siguiente lote
        payloadUDP = "";
        contadorMuestras = 0;
      }
    }
  }
}
