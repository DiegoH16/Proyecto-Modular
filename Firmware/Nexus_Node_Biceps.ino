/*
 * DISPOSITIVO BÍCEPS: Sensor RAW (Luz Pura) a máxima velocidad
 * Modificado: Implementación de "Batching" para evitar saturación UDP en MATLAB
 * Envía: Tiempo (ms), Rojo Crudo, IR Crudo
 */
#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>

// --- CONFIGURACIÓN WI-FI ---
const char* ssid = "MEGACABLE-2.4G-CCAB"; // Corregido: faltaba punto y coma
const char* password = ""; 

// --- CONFIGURACIÓN UDP ---
const char* ip_computadora = "192.168.100.30"; // ¡Asegúrate de que no haya cambiado!
const int puerto_udp = 8889; 

WiFiUDP udp;
MAX30105 particleSensor;
unsigned long tiempoInicio = 0;

// --- OPTIMIZACIÓN DE ENVÍO (BATCHING) ---
const int TAMANO_LOTE = 5; // Agrupar 5 muestras por cada paquete UDP
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

  Wire.begin(21, 22);
  // Velocidad I2C Estándar para EVITAR CONGELAMIENTOS
  Wire.setClock(100000); 

  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("Error: Sensor no encontrado.");
    while (1) { yield(); }
  }

  // Configuración de grado médico (Rango 16384, 100 Muestras/s)
  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  // Reservar memoria para el String para evitar fragmentación de RAM en el ESP32
  payloadUDP.reserve(250); 
  tiempoInicio = millis();
}

void loop() {
  particleSensor.check();

  // Leer el buffer del sensor
  while (particleSensor.available()) {
 
    // 1. Concatenar la muestra actual al payload
    payloadUDP += String(millis() - tiempoInicio) + ",";
    payloadUDP += String(particleSensor.getFIFORed()) + ",";
    payloadUDP += String(particleSensor.getFIFOIR()) + "\n";

    particleSensor.nextSample();
    contadorMuestras++;

    // 2. Si ya juntamos el lote completo, lo enviamos de un solo golpe
    if (contadorMuestras >= TAMANO_LOTE) {
      udp.beginPacket(ip_computadora, puerto_udp);
      udp.print(payloadUDP);
      udp.endPacket();

      // 3. Reiniciar las variables para el siguiente paquete
      payloadUDP = "";
      contadorMuestras = 0;
    }
  }
}
