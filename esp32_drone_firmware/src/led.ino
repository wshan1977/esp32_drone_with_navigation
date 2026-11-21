// Onboard LED control
// Board's LED control

#include "board_config.h"

#if BOARD_LED_ENABLED

#define BLINK_PERIOD      500000  // Slow blink: 500ms half-period -> 1 Hz
#define BLINK_FAST_PERIOD  62500  // Fast blink: 62.5ms half-period -> 8 Hz

#ifndef LED_BUILTIN
#define LED_BUILTIN 2 // for ESP32 Dev Module
#endif

// ---- External dependencies ----
extern bool armed;
extern float t;
extern float controlTime;
extern float rcLossTimeout;
extern float thrustTarget;    // control.ino
extern float batteryVoltage;  // battery.ino
extern bool isInverted; // safety.ino
#if WEB_RC_ENABLED
extern bool webRCEnabled;
extern bool useWebRC;
bool isUsingWebRC();
#endif

void setupLED() {
	pinMode(LED_BUILTIN, OUTPUT);
}

void setLED(bool on) {
	static bool state = false;
	if (on == state) {
		return; // don't call digitalWrite if the state is the same
	}
	digitalWrite(LED_BUILTIN, on ? HIGH : LOW);
	state = on;
}

void blinkLED() {
	setLED(micros() / BLINK_PERIOD % 2);
}

// Battery alarm: threshold depends on flight state
// Flying (thrustTarget >= 0.15) -> L2 (2.8V); L1 not applied in flight
// Disarmed / armed idle -> L1 (3.4V)
bool batteryAlertActive() {
	if (batteryVoltage <= VBAT_ABSENT_THRESHOLD) return false;
	bool flying = armed && thrustTarget >= 0.15f;
	if (flying) return batteryVoltage < VBAT_LOW_THRESHOLD;   // L2: flying
	else        return batteryVoltage < VBAT_WARN_THRESHOLD;   // L1: disarmed/idle
}

// Check for any alarm (low battery / RC link loss / inverted)
bool ledAlertActive() {
	// Inversion check
	if (isInverted) return true;

	// RC link loss check (SBUS RC, only when armed)
	if (controlTime != 0 && armed && (t - controlTime > rcLossTimeout)) return true;

#if WEB_RC_ENABLED
	// Web RC link loss check: active but timed out
	if (webRCEnabled && useWebRC && !isUsingWebRC()) return true;
#endif

	if (batteryAlertActive()) return true;

	return false;
}

// Called from main loop: drive LED by flight state
void updateLED() {
	if (!armed) {
		if (batteryAlertActive()) {
			setLED(micros() / BLINK_FAST_PERIOD % 2); // Low battery while disarmed: fast blink
		} else {
			setLED(false); // Normal standby: off
		}
		return;
	}
	if (ledAlertActive()) {
		setLED(micros() / BLINK_FAST_PERIOD % 2); // Any alarm: fast blink 8Hz
	} else {
		setLED(micros() / BLINK_PERIOD % 2); // Normal flight: slow blink 1Hz
	}
}

#else // BOARD_LED_ENABLED == 0 (ESP32-C3 has no onboard LED)

void setupLED() {}
void setLED(bool on) {}
void updateLED() {}

#endif // BOARD_LED_ENABLED
