// Main program
// Compile with Arduino IDE 2.3.x or later; old version 1.8.19 is not supported!
// Requires the ESP32 board core (esp32 by Espressif Systems) and dependencies (MAVLink, etc.)
// Board: ESP32 Dev Module or WeMOS D1 MINI ESP32

#include "vector.h"
#include "quaternion.h"
#include "util.h"

#define WIFI_ENABLED 1
#define WEB_RC_ENABLED 1  // Enable web RC

float t = NAN; // current step time, s
float dt; // time delta from previous step, s
float controlRoll, controlPitch, controlYaw, controlThrottle; // pilot's inputs, range [-1, 1]
float controlMode = NAN;
Vector gyro; // gyroscope data
Vector acc; // accelerometer data, m/s/s
Vector rates; // filtered angular rates, rad/s
Quaternion attitude; // estimated attitude
bool landed; // are we landed and stationary

void setup() {
	Serial.begin(115200);
	print("Initializing...\n");
	printResetReason();
	disableBrownOut();
	setupParameters();
	setupLED();
	setupMotors();
	setLED(true);
#if WIFI_ENABLED
	setupWiFi();
#endif
#if WEB_RC_ENABLED
	setupWebRC();  // Init web RC
#endif
	setupIMU();
	setupToF();
	setupRC();
	setLED(false);
	print("Init done!\n");
}

// A reset during flight usually means the supply sagged (brownout detector is disabled, so it shows as power-on/other)
void printResetReason() {
	const char *reason;
	switch (esp_reset_reason()) {
		case ESP_RST_POWERON:  reason = "power-on"; break;
		case ESP_RST_SW:       reason = "software (reboot command)"; break;
		case ESP_RST_PANIC:    reason = "crash (panic)"; break;
		case ESP_RST_INT_WDT:
		case ESP_RST_TASK_WDT:
		case ESP_RST_WDT:      reason = "watchdog"; break;
		case ESP_RST_BROWNOUT: reason = "brownout (supply voltage dropped)"; break;
		case ESP_RST_DEEPSLEEP: reason = "deep sleep"; break;
		default:               reason = "other / supply glitch"; break;
	}
	print("Reset reason: %s\n", reason);
}

void loop() {
	readIMU();
	step();
	readToF();
	readRC();
#if WEB_RC_ENABLED
	readWebRC();  // Read web RC input
	processConsoleCommandQueue(); // Run web commands in the main loop to avoid blocking HTTP callbacks
#endif
	estimate();
	estimateAltitude();
	updateBatteryVoltage();
	control();
	sendMotors();
	handleInput();
#if WIFI_ENABLED
	handleWiFi();
	processMavlink();
#endif
	logData();
	syncParameters();
	updateLED();
}
