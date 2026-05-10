/* Copyright 2026 Diego Gutiérrez Hermosillo Medina, Obed Simón Aceves Gutiérrez
    
     Licensed under the Apache License, Version 2.0 (the "License");
     you may not use this file except in compliance with the License.
     You may obtain a copy of the License at
    
         http://www.apache.org/licenses/LICENSE-2.0
    
     Unless required by applicable law or agreed to in writing, software
     distributed under the License is distributed on an "AS IS" BASIS,
     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
     See the License for the specific language governing permissions and
     limitations under the License.
 */
#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

const char* ssid = "AVA_NEXUS";        
const char* password = "ava_password"; 
const char* ip_broadcast = "192.168.4.255"; 

const int puerto_datos = 8889;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
MAX30105 particleSensor;

// 1 muestra a 100 Hz = Envío inmediato sin latencia añadida (100 paquetes UDP por segundo)
const int TAMANO_LOTE = 1;
int contador = 0;
char payload[512]; // Buffer devuelto a 512 (suficiente para lotes pequeños)
int payload_len = 0;

uint16_t crc16(const char* data, int len) {
  uint16_t crc = 0xFFFF;
  for (int i = 0; i < len; i++) {
    crc ^= (uint8_t)data[i];
    for (int j = 0; j < 8; j++) {
      if (crc & 0x0001) crc = (crc >> 1) ^ 0xA001;
      else crc >>= 1;
    }
  }
  return crc;
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("\n[SETUP] Conectando a red AVA_NEXUS...");
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  
  int intentos = 0;
  while (WiFi.status() != WL_CONNECTED && intentos < 40) {
    delay(500); Serial.print("."); intentos++;
  }
  if (WiFi.status() != WL_CONNECTED) ESP.restart();

  Wire.begin(21, 22);
  Wire.setClock(100000); // 100kHz I2C Estándar (Más estable a 100Hz)

  // Iniciar MAX30105 en modo de velocidad estándar
  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("[ERROR] MAX30105 no encontrado.");
    delay(1000); ESP.restart();
  }

  // Configuración a 100Hz estables
  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  // Mensaje SYNC
  struct timeval tv; gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,BICEPS,%lld,%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_broadcast, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();

  payload_len = 0; memset(payload, 0, sizeof(payload));
  Serial.println("\n>>> BICEPS CONECTADO - MONITOR DE RED ACTIVO (100 Hz) <<<");
  Serial.print("IP Asignada: "); Serial.println(WiFi.localIP());
}

void loop() {
  if(WiFi.status() != WL_CONNECTED) {
      WiFi.disconnect(); WiFi.reconnect(); delay(2000); return;
  }

  static int health_check = 0;
  if (++health_check >= 200) { // Chequeo adaptado a 100Hz (cada ~2 segundos)
    Wire.beginTransmission(0x57); 
    if (Wire.endTransmission() != 0) {
      if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) ESP.restart();
    }
    health_check = 0;
  }

  particleSensor.check();

  int samplesToRead = particleSensor.available();
  if (samplesToRead > 10) samplesToRead = 10; // Reducido para 100Hz

  while (samplesToRead--) {
    struct timeval tv; gettimeofday(&tv, NULL);

    uint32_t red_raw = particleSensor.getFIFORed();
    uint32_t ir_raw = particleSensor.getFIFOIR();

    red_raw = min(red_raw, (uint32_t)300000);
    ir_raw = min(ir_raw, (uint32_t)300000);

    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%lu,%lu", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, red_raw, ir_raw);

    uint16_t crc = crc16(linea, len);
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0 && added < (sizeof(payload) - payload_len)) payload_len += added;

    contador++;

    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_broadcast, puerto_datos);
      udp_datos.write((const uint8_t*)payload, payload_len);
      udp_datos.endPacket();
      
      // Indicador ligero de actividad (imprime 1 vez por segundo a 100Hz)
      static int lotesEnviados = 0;
      lotesEnviados++;
      if (lotesEnviados % 100 == 0) {
        Serial.printf("[BICEPS] %d lotes enviados (100 Hz)\n", lotesEnviados);
      }
      
      payload_len = 0; contador = 0; 
    }
    particleSensor.nextSample();
  }
  yield(); 
}
