/*
 * DISPOSITIVO BÍCEPS: Sensor RAW (Luz Pura) a máxima velocidad
 * Envía: Tiempo (ms), Rojo Crudo, IR Crudo
 */

#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>

// --- CONFIGURACIÓN WI-FI ---
const char* ssid = "MEGACABLE-2.4G-CCAB";     
const char* password = "tqnfTMn8dR"; 

// --- CONFIGURACIÓN UDP ---
const char* ip_computadora = "192.168.100.30";
const int puerto_udp = 8889; 

WiFiUDP udp;

MAX30105 particleSensor;
unsigned long tiempoInicio = 0;

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
    while (1) { yield(); }
  }

  // Configuración de grado médico (Rango 16384, 100 Muestras/s)
  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  tiempoInicio = millis();
}

void loop() {
  particleSensor.check();

  // Vaciar el buffer continuamente hacia MATLAB
  while (particleSensor.available()) {
 
  udp.beginPacket(ip_computadora, puerto_udp);

    udp.print(millis() - tiempoInicio); 
    udp.print(",");
    udp.print(particleSensor.getFIFORed());
    udp.print(",");
    udp.print(particleSensor.getFIFOIR());    
    udp.print("\n");

    udp.endPacket();

    particleSensor.nextSample();
  }
}
