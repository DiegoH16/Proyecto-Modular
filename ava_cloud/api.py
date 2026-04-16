import os
import numpy as np
import tensorflow as tf
from fastapi import FastAPI
from pydantic import BaseModel
from scipy.signal import resample

app = FastAPI()

def construir_modelo():
    inputs = tf.keras.Input(shape=(None, 1))
    x = tf.keras.layers.Conv1D(filters=32, kernel_size=3, padding='same', activation='relu')(inputs)
    x = tf.keras.layers.MaxPooling1D(pool_size=2)(x)
    x = tf.keras.layers.BatchNormalization()(x)
    x = tf.keras.layers.Dropout(0.2)(x)
    x = tf.keras.layers.Conv1D(filters=64, kernel_size=3, padding='same', activation='relu')(x)
    x = tf.keras.layers.MaxPooling1D(pool_size=2)(x)
    x = tf.keras.layers.BatchNormalization()(x)
    x = tf.keras.layers.Dropout(0.2)(x)
    lstm_out = tf.keras.layers.Bidirectional(tf.keras.layers.LSTM(64, return_sequences=True))(x)
    att_scores = tf.keras.layers.TimeDistributed(tf.keras.layers.Dense(1, activation='tanh'))(lstm_out)
    att_weights = tf.keras.layers.Softmax(axis=1)(att_scores)
    ctx = tf.keras.layers.Multiply()([lstm_out, att_weights])
    ctx = tf.keras.layers.Lambda(lambda x: tf.reduce_sum(x, axis=1))(ctx)
    x = tf.keras.layers.Dense(units=64, activation='relu')(ctx)
    x = tf.keras.layers.Dropout(0.3)(x)
    outputs = tf.keras.layers.Dense(units=1, activation='sigmoid')(x)
    model = tf.keras.Model(inputs=inputs, outputs=outputs)
    model.load_weights('ava_campeon_pesos.keras')
    return model

# Cargar el modelo al iniciar el servidor
model = construir_modelo()

class SignalData(BaseModel):
    samples: list[float]

@app.post("/predict")
async def predict(data: SignalData):
    # Procesamiento a 50Hz (igual que en el entrenamiento)
    raw = np.array(data.samples)
    norm = (raw - np.mean(raw)) / (np.std(raw) + 1e-8)
    # Re-ajustar a 500 muestras por si el ESP32 mandó de más o de menos
    if len(norm) != 500:
        norm = resample(norm, 500)
    
    tensor = np.expand_dims(np.expand_dims(norm, axis=0), axis=-1)
    pred = model.predict(tensor, verbose=0)[0][0]
    
    # Umbral de 0.85 para evitar falsos positivos
    return {"spasm_detected": bool(pred > 0.85), "confidence": float(pred)}
