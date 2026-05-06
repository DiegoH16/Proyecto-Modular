/*
 * ========================================================================
 * DISPOSITIVO BÍCEPS: Sensor Óptico Fotopletismográfico (MAX30102/MAX30105)
 * TARGET: ESP32
 * ========================================================================
 */

#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <time.h>

// ─────────────────────────────────────────────────────────────────
// CONFIGURACIÓN WI-FI Y RED (⚠️ MODIFICAR AQUÍ)
// ─────────────────────────────────────────────────────────────────
const char* ssid = "TU_SSID";              
const char* password = "TU_PASSWORD";      
const char* ip_computadora = "192.168.1.100";  // IP de la PC con MATLAB
const int puerto_udp = 8889;

// Configuración NTP (Opcional, para timestamps absolutos)
const char* ntpServer = "pool.ntp.org";
const long gmtOffset_sec = -21600;      // UTC-6 (Ej. México CST)
const int daylightOffset_sec = 0;

WiFiUDP udp;
MAX30105 particleSensor;

// ─────────────────────────────────────────────────────────────────
// VARIABLES GLOBALES DE ESTADO
// ─────────────────────────────────────────────────────────────────
uint32_t lastRed = 0;
uint32_t lastIR = 0;
bool use_ntp = false;

// Control de reinicios y desbordamiento de millis()
unsigned long ultimo_millis_valido = 0;
unsigned long time_offset_ms = 0;
const unsigned long MAX_MILLIS = 4294967295UL;

// Umbrales clínicos de contacto
struct {
    uint32_t umbral_minimo = 3000;      // Mínimo IR para detectar dedo
    bool contacto_actual = false;
    bool contacto_anterior = false;
} SENSOR_STATE;

// ─────────────────────────────────────────────────────────────────
// FUNCIONES DE INICIALIZACIÓN
// ─────────────────────────────────────────────────────────────────

void setupWiFi() {
    Serial.print("[SETUP] Conectando a WiFi: ");
    Serial.println(ssid);
    
    WiFi.begin(ssid, password);
    int retries = 0;
    
    // Timeout de 15 segundos para no quedarse colgado
    while (WiFi.status() != WL_CONNECTED && retries < 30) {
        delay(500);
        Serial.print(".");
        retries++;
    }
    
    if (WiFi.status() == WL_CONNECTED) {
        Serial.println("\n[SETUP] WiFi OK. IP: " + WiFi.localIP().toString());
        use_ntp = true;
    } else {
        Serial.println("\n[WARN] WiFi FALLÓ. Ejecutando offline mode.");
        use_ntp = false;
    }
}

void setupNTP() {
    if (!use_ntp) return;
    
    Serial.print("[SETUP] Sincronizando Reloj NTP...");
    configTime(gmtOffset_sec, daylightOffset_sec, ntpServer);
    
    time_t now = time(nullptr);
    int ntp_retries = 0;
    
    // Esperar hasta que el año sea > 2020
    while (now < 1577836800 && ntp_retries < 20) {  
        delay(200);
        Serial.print(".");
        now = time(nullptr);
        ntp_retries++;
    }
    
    if (now > 1577836800) {
        Serial.printf("\n[SETUP] NTP OK. TS: %lu\n", now);
    } else {
        use_ntp = false;
        Serial.println("\n[WARN] NTP Timeout. Usando reloj interno.");
    }
}

void setupMAX30102() {
    Serial.println("[SETUP] Inicializando MAX30102...");
    
    // IMPORTANTE: I2C a 100kHz para prevenir I2C bus lockups en ESP32
    Wire.begin(21, 22);
    Wire.setClock(100000); 
    
    if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
        Serial.println("[ERROR CRÍTICO] MAX30102 no detectado.");
        while (1) { yield(); } // Detener ejecución
    }
    
    // Configuración Clínica:
    // ledBrightness=60, sampleAverage=4, ledMode=2 (Red+IR)
    // sampleRate=50 (Alineado con MATLAB), pulseWidth=411, adcRange=16384
    particleSensor.setup(60, 4, 2, 50, 411, 16384);
    particleSensor.setPulseAmplitudeRed(0x7A);
    particleSensor.setPulseAmplitudeIR(0x3F);
    
    Serial.println("[SETUP] Sensor configurado a 50 Hz estrictos.");
}

// ─────────────────────────────────────────────────────────────────
// RUTINAS DE PROCESAMIENTO
// ─────────────────────────────────────────────────────────────────

uint32_t getTimestampMs() {
    unsigned long t_now = millis();
    
    // Protección contra el desbordamiento de millis() (cada ~50 días)
    if (t_now < ultimo_millis_valido) {
        Serial.println("[INFO] Overflow de millis() detectado y corregido.");
        time_offset_ms += MAX_MILLIS;
    }
    ultimo_millis_valido = t_now;
    
    return t_now + time_offset_ms;
}

void evaluarContacto() {
    SENSOR_STATE.contacto_actual = (lastIR > SENSOR_STATE.umbral_minimo);
    
    if (SENSOR_STATE.contacto_actual != SENSOR_STATE.contacto_anterior) {
        if (SENSOR_STATE.contacto_actual) {
            Serial.println("[SENSOR] ✓ Dedo posicionado.");
        } else {
            Serial.println("[SENSOR] ✗ Dedo retirado.");
        }
        SENSOR_STATE.contacto_anterior = SENSOR_STATE.contacto_actual;
    }
}

// ─────────────────────────────────────────────────────────────────
// BUCLE PRINCIPAL
// ─────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(1000);
    
    Serial.println("\n╔════════════════════════════════════════════╗");
    Serial.println("║  AVA NEXUS | NODO BÍCEPS V2.2 (CLINICAL)   ║");
    Serial.println("╚════════════════════════════════════════════╝\n");
    
    setupWiFi();
    setupNTP();
    setupMAX30102();
    
    Serial.println("\n[SISTEMA] Iniciando transmisión UDP a 50Hz...\n");
}

void loop() {
    // Escanear el bus I2C por nuevos datos
    particleSensor.check();
    
    // VACIADO DEL FIFO (Hardware-Timed)
    // Este bucle se ejecuta EXACTAMENTE a 50 Hz porque el hardware
    // del MAX30102 escupe una muestra nueva cada 20 milisegundos.
    while (particleSensor.available()) {
        
        lastRed = particleSensor.getFIFORed();
        lastIR = particleSensor.getFIFOIR();
        
        // Avanzar el puntero del buffer I2C
        particleSensor.nextSample(); 
        
        // Validar si hay dedo presente
        evaluarContacto();
        
        // Empaquetamiento y envío UDP (Tiempo, Rojo, Infrarrojo)
        uint32_t t_send = getTimestampMs();
        
        udp.beginPacket(ip_computadora, puerto_udp);
        udp.print(t_send);   udp.print(",");
        udp.print(lastRed);  udp.print(",");
        udp.print(lastIR);   udp.print("\n");
        udp.endPacket();
        
        // Debug por puerto serial (1 vez cada ~2 segundos = 100 muestras)
        static int debug_counter = 0;
        if (debug_counter++ >= 100) {
            debug_counter = 0;
            Serial.printf("[UDP] T: %lu ms | Red: %u | IR: %u | Estado: %s\n", 
                          t_send, lastRed, lastIR, 
                          SENSOR_STATE.contacto_actual ? "CONECTADO" : "DESCONECTADO");
        }
    }
    
    // Mantiene estable el watchdog del ESP32
    yield();
}
