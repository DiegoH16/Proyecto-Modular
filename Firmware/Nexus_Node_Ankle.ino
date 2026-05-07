/*
 * DISPOSITIVO TOBILLO: MPU6050 + EMG
 */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <time.h>
#include <sys/time.h>

// --- CONFIGURACIÓN DE RED ---
const char* ssid = "TU_SSID_AQUI";
const char* password = "TU_PASSWORD_AQUI";
const char* ip_matlab = "192.168.100.30";
const int puerto_datos = 8888;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
Adafruit_MPU6050 mpu;

// --- PINES Y CONSTANTES ---
const int PIN_EMG = 4; // ADC1_CH3 en ESP32

// --- PARÁMETROS DE MUESTREO ---
const int FRECUENCIA_HZ = 50;
const unsigned long INTERVALO_US = 1000000 / FRECUENCIA_HZ; // 20,000 us (20 ms)

// --- NTP SYNC ---
const char* ntpServer = "pool.ntp.org";
const long  gmtOffset_sec = 0; // Guardamos en UTC puro
const int   daylightOffset_sec = 0;

// --- FILTRADO EMA ---
const float ALPHA_IMU = 0.4;  // Filtro rápido para movimiento
const float ALPHA_EMG = 0.15; // Filtro suave para envolvente muscular

struct {
  float ax_last = 0;
  float ay_last = 0;
  float az_last = 0;
  float emg_last = 0;
  bool first_read = true;
} filters;

// --- BATCHING ESTÁTICO (C-Style) ---
const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; // Buffer estático en lugar de String dinámica
int payload_len = 0;
unsigned long ultimo_muestreo_us = 0;

// --- FUNCIONES AUXILIARES ---

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
  
  // --- CONEXIÓN WIFI ---
  WiFi.begin(ssid, password);
  int intentos = 0;
  while (WiFi.status() != WL_CONNECTED && intentos < 20) {
    delay(500);
    Serial.print(".");
    intentos++;
