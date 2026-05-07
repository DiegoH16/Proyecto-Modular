/*
 * DISPOSITIVO BÍCEPS: MAX30105 PPG Sensor (V3.4 OFFLINE CLIENT - BROADCAST)
 */
#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

// --- CONFIGURACIÓN DE RED (MODO CLIENTE) ---
const char* ssid = "AVA_NEXUS";        // Se conecta a la red del Tobillo
const char* password = "ava_password"; 

const char* ip_broadcast = "192.168.4.255"; 

const int puerto_datos = 8889;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
MAX30105 particleSensor;

// --- BATCHING ESTÁTICO ---
const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; 
int payload_len = 0;

// Cálculo de CRC16 (Modbus 0xA001)
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
  WiFi.mode(WIFI_STA); // Modo cliente (Station)
  WiFi.begin(ssid, password);
  
  int intentos = 0;
  // Esperamos hasta conectar (máximo ~20 segundos)
  while (WiFi.status() != WL_CONNECTED && intentos < 40) {
    delay(500); 
    Serial.print("."); 
    intentos++;
  }
  
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\n[ERROR] No se pudo encontrar al Tobillo. Asegúrate de encender el Tobillo primero. Reiniciando...");
    delay(2000);
    ESP.restart();
  }
  
  Serial.println("\n[OK] Conectado al Tobillo!");
  Serial.print("IP Asignada al Bíceps: "); 
  Serial.println(WiFi.localIP());

  // --- INICIALIZACIÓN DE HARDWARE ---
  Wire.begin(21, 22);
  Wire.setClock(100000); // 100kHz I2C Estándar para estabilidad del MAX30105

  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("[ERROR] MAX30105 no encontrado! Revisa conexiones I2C.");
    delay(1000); 
    ESP.restart();
  }

  // Configuración de grado médico
  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  // --- SYNC INICIAL A MATLAB (Vía Broadcast) ---
  struct timeval tv; 
  gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,BICEPS,%lld,%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_broadcast, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();

  payload_len = 0; 
  memset(payload, 0, sizeof(payload));
}

void loop() {
  // Autoreconexión si el tobillo se apaga o reinicia
  if(WiFi.status() != WL_CONNECTED) {
      Serial.println("[WARN] Conexión perdida con el Tobillo. Reconectando...");
      WiFi.disconnect();
      WiFi.reconnect();
      delay(2000);
      return;
  }

  // --- VERIFICACIÓN DE SALUD I2C ---
  static int health_check = 0;
  if (++health_check >= 100) {
    Wire.beginTransmission(0x57); // Dirección I2C del MAX30105
    if (Wire.endTransmission() != 0) {
      Serial.println("[WARN] I2C check failed! Posible desconexión física del sensor.");
      udp_control.beginPacket(ip_broadcast, puerto_control);
      udp_control.print("ERROR,I2C_LOST,BICEPS\n");
      udp_control.endPacket();
      
      if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
        ESP.restart();
      }
    }
    health_check = 0;
  }

  particleSensor.check();

  // ✅ MEJORA CRÍTICA: Límite de lectura por ciclo para prevenir reinicios por el Watchdog
  int samplesToRead = particleSensor.available();
  if (samplesToRead > 10) samplesToRead = 10; // Cap a 10 muestras por iteración de loop

  while (samplesToRead--) {
    struct timeval tv;
    gettimeofday(&tv, NULL);

    uint32_t red_raw = particleSensor.getFIFORed();
    uint32_t ir_raw = particleSensor.getFIFOIR();

    // ✅ MEJORA CRÍTICA: Capping en lugar de descarte para mantener linealidad temporal (DSP)
    red_raw = min(red_raw, (uint32_t)300000);
    ir_raw = min(ir_raw, (uint32_t)300000);

    // Formateo (Separado por coma)
    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%lu,%lu", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, red_raw, ir_raw);

    // Calcular CRC16
    uint16_t crc = crc16(linea, len);
    
    // Añadir línea + CRC al payload estático
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0 && added < (sizeof(payload) - payload_len)) {
        payload_len += added;
    }

    contador++;

    // Enviar lote (Batching a Broadcast)
    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_broadcast, puerto_datos);
      udp_datos.write((const uint8_t*)payload, payload_len);
      udp_datos.endPacket();

      payload_len = 0; 
      contador = 0; 
    }
    
    // Avanzar al siguiente dato en el FIFO
    particleSensor.nextSample();
  }
  
  // Yield para permitir que el stack de red WiFi procese en background
  yield(); 
}
