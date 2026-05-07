/*
 * DISPOSITIVO BÍCEPS: MAX30105 PPG Sensor (V3.2 OFFLINE CLIENT MODE)
 * Se conecta a la red creada por el Tobillo.
 * Envía: Timestamp_UNIX, Red_RAW, IR_RAW, CRC16\n
 */
#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

// --- CONFIGURACIÓN DE RED (MODO CLIENTE) ---
const char* ssid = "AVA_NEXUS";       // Se conecta al Tobillo
const char* password = "ava_password"; 

// ⚠️ LA MISMA IP DE TU COMPUTADORA EN LA RED AVA_NEXUS ⚠️
const char* ip_matlab = "192.168.4.2"; 

const int puerto_datos = 8889;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
MAX30105 particleSensor;

// --- BATCHING ESTÁTICO ---
const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; 
int payload_len = 0;

// Cálculo de CRC16
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
  
  // --- CONEXIÓN A LA RED DEL TOBILLO ---
  Serial.println("\n[SETUP] Buscando red AVA_NEXUS...");
  WiFi.mode(WIFI_STA); // Modo cliente
  WiFi.begin(ssid, password);
  
  int intentos = 0;
  // Esperamos hasta conectar
  while (WiFi.status() != WL_CONNECTED && intentos < 40) {
    delay(500); Serial.print("."); intentos++;
  }
  
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\n[ERROR] No se pudo encontrar al Tobillo. Reiniciando...");
    ESP.restart();
  }
  Serial.println("\n[OK] Conectado al Tobillo!");

  // --- INICIALIZACIÓN DE HARDWARE ---
  Wire.begin(21, 22);
  Wire.setClock(100000); 

  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("[ERROR] MAX30105 no encontrado!");
    delay(1000); ESP.restart();
  }

  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  // --- SYNC INICIAL A MATLAB ---
  struct timeval tv; gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,BICEPS,%lld.%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_matlab, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();

  payload_len = 0; memset(payload, 0, sizeof(payload));
}

void loop() {
  // Autoreconexión si el tobillo se apaga
  if(WiFi.status() != WL_CONNECTED) {
      Serial.println("Conexión perdida. Reconectando...");
      WiFi.disconnect();
      WiFi.reconnect();
      delay(2000);
      return;
  }

  particleSensor.check();

  // Vaciar el FIFO del sensor
  while (particleSensor.available()) {
    struct timeval tv;
    gettimeofday(&tv, NULL);

    uint32_t red_raw = particleSensor.getFIFORed();
    uint32_t ir_raw = particleSensor.getFIFOIR();

    if (red_raw > 300000 || ir_raw > 300000) {
      particleSensor.nextSample(); continue;
    }

    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld.%06ld,%lu,%lu", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, red_raw, ir_raw);

    uint16_t crc = crc16(linea, len);
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    
    if (added > 0 && added < (sizeof(payload) - payload_len)) {
        payload_len += added;
    }

    contador++;

    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_matlab, puerto_datos);
      udp_datos.write((const uint8_t*)payload, payload_len);
      udp_datos.endPacket();

      payload_len = 0; contador = 0; 
    }
    particleSensor.nextSample();
  }
  delay(1); 
}
