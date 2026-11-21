#pragma once

// Board hardware configuration
// Board-level hardware configuration
// ESP32, ESP32-C3 and ESP32-S3 selected automatically via conditional compilation; no manual changes needed

#ifdef CONFIG_IDF_TARGET_ESP32C3

// ---- Motor pins (array order: RL, RR, FR, FL, matching constants in motors.ino)----
// FL=GPIO3 (front left), RL=GPIO4 (rear left), RR=GPIO5 (rear right), FR=GPIO8 (front right)
// GPIO8 is a strapping pin (internal pull-up); no external resistor needed, PWM output works normally
#define BOARD_MOTOR_PINS   {4, 5, 8, 3}    // RL=GPIO4, RR=GPIO5, FR=GPIO8, FL=GPIO3

// ---- Battery ADC ----
#define BOARD_VBAT_ADC_PIN 1               // ADC1_CH1 (ESP32-C3 ADC only on GPIO0~4)

// ---- RC serial (SBUS)----
// ESP32-C3 has no Serial2, uses Serial1; pin can be remapped to any GPIO
// GPIO9 is the Boot button (internal pull-up); SBUS is driven by the receiver, so normal use is unaffected
#define BOARD_RC_SERIAL    Serial1
#define BOARD_RC_RX_PIN    9

// ---- IMU SPI (all ESP32-C3 hardware default pins)----
// SCK=6 (default), MISO=2 (default), MOSI=7 (default), CS=10 (default SS)
#define BOARD_SPI_SCK      6
#define BOARD_SPI_MISO     2
#define BOARD_SPI_MOSI     7
#define BOARD_SPI_CS       10

// ---- LED: ESP32-C3 Mini has no onboard LED, disabled to save pins ----
#define BOARD_LED_ENABLED  0
#define BOARD_I2C_SDA      -1               // ToF not connected
#define BOARD_I2C_SCL      -1

#elif defined(CONFIG_IDF_TARGET_ESP32S3)  // ---- ESP32-S3 config ----

// ---- Motor pins: GPIO4-7, away from FSPI (GPIO10-13), no strapping constraints ----
#define BOARD_MOTOR_PINS   {4, 5, 6, 7}    // RL=GPIO4, RR=GPIO5, FR=GPIO6, FL=GPIO7

// ---- Battery ADC: GPIO1 (ADC1_CH0; S3 ADC1 range is GPIO1-10)----
#define BOARD_VBAT_ADC_PIN 1

// ---- RC serial (SBUS): GPIO8, no conflict with FSPI/UART0 ----
#define BOARD_RC_SERIAL    Serial2
#define BOARD_RC_RX_PIN    8

// ---- IMU SPI: ESP32-S3 FSPI default pins ----
// SCK=12 (default), MISO=13 (default), MOSI=11 (default), CS=10 (default SS)
#define BOARD_SPI_SCK      12
#define BOARD_SPI_MISO     13
#define BOARD_SPI_MOSI     11
#define BOARD_SPI_CS       10

// ---- LED: new PCB has a plain LED on GPIO2, driven the same as ESP32 ----
#define BOARD_LED_ENABLED  1
#define BOARD_I2C_SDA      -1               // ToF not connected
#define BOARD_I2C_SCL      -1

#else  // ---- ESP32 default config ----

#define BOARD_MOTOR_PINS   {12, 13, 15, 14}  // RL=GPIO12, RR=GPIO13, FR=GPIO15, FL=GPIO14
#define BOARD_VBAT_ADC_PIN 36
#define BOARD_RC_SERIAL    Serial2
#define BOARD_RC_RX_PIN    -1                // SBUS 수신기 미사용 (PCB 배선은 GPIO4)
#define BOARD_SPI_SCK      18
#define BOARD_SPI_MISO     19
#define BOARD_SPI_MOSI     23
#define BOARD_SPI_CS       5
#define BOARD_LED_ENABLED  1
#define BOARD_I2C_SDA      21                // VL53L1X rangefinder (not broken out on PCB, soldered directly to dev board)
#define BOARD_I2C_SCL      22

#endif
