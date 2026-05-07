/*
 * DISPOSITIVO BÍCEPS: MAX30105 PPG Sensor
 * V3.0 PRODUCTION: Sincronización robusta, checksum, manejo de overflow
 * Envía: Tiempo_ms,Red_RAW,IR_RAW,CRC16\n
 */
#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>

// --- CONFIGURACIÓN ---
const char* ssid = "MEGACABLE-2.4G-CCAB";
const char* password = "TU_PASSWORD_AQUI";
const char* ip_matlab = "192.168.100.30";
const int puerto_datos = 8889;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
MAX30105 particleSensor;

// --- GESTIÓN DE TIEMPO ROBUSTO ---
struct {
  uint64_t ms_total = 0;
  uint32_t ms_last = 0;
  
  uint64_t getTotalMs() {
    uint32_t ms_now = millis();
    if (ms_now < ms_last) ms_total += 4294967296ULL;
    ms_last = ms_now;
    return ms_total + ms_now;
  }
} timeManager;

// --- BATCHING Y VALIDACIÓN ---
const int TAMANO_LOTE = 5;
int contador = 0;
String payload = "";
bool sensor_ok = true;

// --- CRC16 CALCULATION ---
uint16_t crc16(String data) {
  uint16_t crc = 0xFFFF;
  for (int i = 0; i < data.length(); i++) {
    crc ^= (uint16_t)data[i];
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
  
  // Conectar WiFi
  WiFi.begin(ssid, password);
  int intentos = 0;
  while (WiFi.status() != WL_CONNECTED && intentos < 20) {
    delay(500);
    Serial.print(".");
    intentos++;
  }
  
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\n[ERROR] WiFi no conectado. Reiniciando...");
    ESP.restart();
  }
  Serial.println("\n[OK] WiFi Conectado!");
  Serial.print("IP: "); Serial.println(WiFi.localIP());

  // Inicializar I2C y sensor
  Wire.begin(21, 22);
  Wire.setClock(100000);

  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("[ERROR] MAX30105 no encontrado!");
    sensor_ok = false;
    delay(1000);
    ESP.restart();
  }

  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  payload.reserve(300);
  
  // Enviar SYNC a MATLAB
  delay(500);
  udp_control.beginPacket(ip_matlab, puerto_control);
  udp_control.print("SYNC,BICEPS,");
  udp_control.print(timeManager.getTotalMs());
  udp_control.print("\n");
  udp_control.endPacket();
  Serial.println("[OK] SYNC enviado a MATLAB");
}

void loop() {
  particleSensor.check();

  // Verificación de salud I2C cada 100 muestras
  static int health_check = 0;
  if (++health_check >= 100) {
    Wire.beginTransmission(0x57);
    if (Wire.endTransmission() != 0) {
      Serial.println("[WARN] I2C check failed!");
      udp_control.beginPacket(ip_matlab, puerto_control);
      udp_control.print("ERROR,I2C_LOST\n");
      udp_control.endPacket();
      // Intentar reconectar
      if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
        ESP.restart();
      }
    }
    health_check = 0;
  }

  while (particleSensor.available()) {
    uint64_t t_ms = timeManager.getTotalMs();
    uint32_t red_raw = particleSensor.getFIFORed();
    uint32_t ir_raw = particleSensor.getFIFOIR();

    // Validar rango (MAX30105: típicamente 0-262144)
    if (red_raw > 300000 || ir_raw > 300000) {
      Serial.println("[WARN] Valor fuera de rango detectado, descartando");
      particleSensor.nextSample();
      continue;
    }

    // Construir línea CSV
    String linea = String(t_ms) + "," + String(red_raw) + "," + String(ir_raw);
    String linea_con_crc = linea + "," + String(crc16(linea), HEX) + "\n";
    
    payload += linea_con_crc;
    contador++;

    if (contador >= TAMANO_LOTE) {
      // Enviar paquete
      udp_datos.beginPacket(ip_matlab, puerto_datos);
      udp_datos.print(payload);
      udp_datos.endPacket();

      payload = "";
      contador = 0;
    }

    particleSensor.nextSample();
  }

  delay(1); // Yield to WiFi stack
}
