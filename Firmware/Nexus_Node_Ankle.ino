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
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>
#include <math.h> 

const char* ssid = "AVA_NEXUS";        
const char* password = "ava_password"; 
const char* ip_broadcast = "192.168.4.255"; 

const int puerto_datos = 8888;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
Adafruit_MPU6050 mpu;

// --- PINES Y MUESTREO (100 Hz) ---
const int PIN_EMG = 4; 
const int FRECUENCIA_HZ = 100;
const unsigned long INTERVALO_US = 1000000 / FRECUENCIA_HZ; // 10ms exactos

const int TAMANO_LOTE = 5; 
int contador = 0;
char payload[512]; 
int payload_len = 0;
unsigned long ultimo_muestreo_us = 0;

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
  delay(2000); 
  
  Serial.println("\n\n--- INICIANDO DIAGNÓSTICO DE SETUP ---");
  
  Serial.println("[Paso 1] Encendiendo Antena Wi-Fi...");
  WiFi.mode(WIFI_AP);
  delay(100);
  WiFi.softAP(ssid, password);
  delay(1000); 
  Serial.print("[Paso 1 OK] IP del Router: "); 
  Serial.println(WiFi.softAPIP());

  Serial.println("[Paso 2] Iniciando bus I2C (Pines 21 y 22)...");
  Wire.begin(21, 22);
  Wire.setClock(100000); 
  Serial.println("[Paso 2 OK] Bus I2C iniciado.");

  Serial.println("[Paso 3] Conectando con MPU6050...");
  if (!mpu.begin()) {
    Serial.println("   -> [ADVERTENCIA] MPU6050 NO ENCONTRADO. Saltando...");
    mpu_ok = false;
  } else {
    mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_44_HZ);
    mpu_ok = true;
    Serial.println("   -> [Paso 3 OK] MPU6050 Configurado.");
  }

  analogReadResolution(12);

  Serial.println("[Paso 4] Configurando red UDP...");
  struct timeval tv; gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,TOBILLO,%lld,%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_broadcast, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();
  Serial.println("[Paso 4 OK] Mensaje SYNC enviado.");

  payload_len = 0; memset(payload, 0, sizeof(payload));
  ultimo_muestreo_us = micros();
  
  Serial.println(">>> TOBILLO INICIADO - MONITOR DE RED ACTIVO <<<");
}

void loop() {
  unsigned long t_actual = micros();

  if (t_actual - ultimo_muestreo_us >= INTERVALO_US) {
    ultimo_muestreo_us = t_actual;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    float ax = a.acceleration.x;
    float ay = a.acceleration.y;
    float az = a.acceleration.z;
    int emg_raw = analogRead(PIN_EMG);

    if (fabsf(ax) > 50.0f || fabsf(ay) > 50.0f || fabsf(az) > 50.0f) return;

    struct timeval tv; gettimeofday(&tv, NULL);

    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%.2f,%.2f,%.2f,%d", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, ax, ay, az, emg_raw);

    uint16_t crc = crc16(linea, len);
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0 && added < (sizeof(payload) - payload_len)) payload_len += added;

    contador++;

    if (contador >= TAMANO_LOTE) {
      if (WiFi.softAPgetStationNum() > 0) {
        udp_datos.beginPacket(ip_broadcast, puerto_datos);
        udp_datos.write((const uint8_t*)payload, payload_len);
        udp_datos.endPacket();
        
        // --- TELEMETRÍA EN TERMINAL ---
        Serial.println("\n[TX TOBILLO] Enviando lote UDP:");
        Serial.print(payload);
      }
      payload_len = 0; contador = 0; 
    }
  }
  yield(); 
}
