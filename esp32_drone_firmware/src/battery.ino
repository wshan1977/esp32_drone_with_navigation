// Battery voltage monitoring
// Battery voltage monitoring

#include "board_config.h"

#define VBAT_ADC_PIN       BOARD_VBAT_ADC_PIN  // Battery voltage ADC pin
#define VBAT_ADC_SAMPLES   16               // ADC samples averaged; more = less noise, slower response
#define VBAT_DIVIDER       (43.0f / 33.0f)  // Divider ratio: high side 10kΩ + low side 33kΩ, Vbat = Vadc × 43/33
#define VBAT_WARN_THRESHOLD     3.5f  // L1: no-load/idle warning threshold (V)
#define VBAT_LOW_THRESHOLD      3.3f  // L2: in-flight low battery alarm threshold (V)
#define VBAT_CRITICAL_THRESHOLD 3.0f  // L3: in-flight critical threshold, auto-land (V)
#define VBAT_ABSENT_THRESHOLD   0.5f  // Below this, battery considered absent; all alarms ignored

#define BATTERY_FLYING_THRUST_MIN    0.15f  // Thrust >= this is considered flying; L1 not applied
#define BATTERY_ACTION_DEBOUNCE_TIME  0.9f  // Low-voltage debounce time (s)

extern float t;
extern bool armed;
float batteryVoltage = 0.0f;  // Latest voltage, refreshed periodically by updateBatteryVoltage()
float batteryRestVoltage = 0.0f; // Last voltage measured while disarmed (motors off), to show the sag under load

void updateBatteryVoltage() {
	static float lastCheck = 0;
	if (t - lastCheck < 0.5f) return;  // Sample every 0.5 s
	lastCheck = t;
	batteryVoltage = readBatteryVoltage();
	if (!armed) batteryRestVoltage = batteryVoltage;
}

float readBatteryVoltage() {
	long sum = 0;
	for (int i = 0; i < VBAT_ADC_SAMPLES; i++) sum += analogReadMilliVolts(VBAT_ADC_PIN);
	return (sum / (float)VBAT_ADC_SAMPLES / 1000.0f) * VBAT_DIVIDER;
}
