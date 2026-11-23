// VL53L1X ToF rangefinder (facing down) for altitude

#include <Wire.h>
#include <VL53L1X.h>
#include "board_config.h"
#include "util.h"

#define TOF_DISTANCE_MODE    VL53L1X::Medium // Max ~3m; better ambient light immunity indoors than Long
#define TOF_TIMING_BUDGET_US 33000           // Single measurement time
#define TOF_PERIOD_MS        33              // Continuous measurement period ~30Hz; must not be less than measurement time
#define TOF_TIMEOUT          0.2f            // No valid data for longer than this = invalid (s)

VL53L1X tof;
bool tofEnabled = false;
float tofRange = NAN;     // latest valid distance, m
float tofTime = NAN;      // time of latest valid distance, s
uint8_t tofStatus = 255;  // latest VL53L1X range status
float tofSignal = NAN;    // peak signal rate, MCPS

void setupToF() {
#if BOARD_I2C_SDA >= 0
	print("Setup ToF\n");
	Wire.begin(BOARD_I2C_SDA, BOARD_I2C_SCL, 400000);
	Wire.setTimeOut(5); // Prevent I2C from blocking the main loop for long if the sensor drops out
	tof.setBus(&Wire);
	tof.setTimeout(50);
	if (!tof.init()) {
		print("VL53L1X not found! check wiring SDA=%d SCL=%d\n", BOARD_I2C_SDA, BOARD_I2C_SCL);
		return;
	}
	tof.setDistanceMode(TOF_DISTANCE_MODE);
	tof.setMeasurementTimingBudget(TOF_TIMING_BUDGET_US);
	tof.startContinuous(TOF_PERIOD_MS);
	tofEnabled = true;
#endif
}

void readToF() {
	static Rate pollRate(200); // Limit I2C polling rate; do not access the sensor every 1kHz loop
	if (!tofEnabled || !pollRate) return;
	if (!tof.dataReady()) return;
	tof.read(false);
	tofStatus = tof.ranging_data.range_status;
	tofSignal = tof.ranging_data.peak_signal_count_rate_MCPS;
	switch (tofStatus) {
		case VL53L1X::RangeValid:
		case VL53L1X::RangeValidMinRangeClipped: // sitting on the ground: the sensor is ~2.5 cm above it, below its 4 cm minimum
		case VL53L1X::RangeValidNoWrapCheckFail:
			tofRange = tof.ranging_data.range_mm / 1000.0f;
			tofTime = t;
			break;
		case VL53L1X::MinRangeFail: // target closer than the minimum: on the ground
			tofRange = 0;
			tofTime = t;
			break;
		default: // sigma/signal/phase failures: no usable distance
			break;
	}
}

bool tofValid() {
	return tofEnabled && t - tofTime < TOF_TIMEOUT;
}

void printToFInfo() {
	if (!tofEnabled) {
		print("ToF: not available\n");
		return;
	}
	print("range: %.3f m  valid: %d  age: %.3f s\n", tofRange, tofValid(), t - tofTime);
	print("status: %s  signal: %.2f MCPS\n",
		VL53L1X::rangeStatusToString((VL53L1X::RangeStatus)tofStatus), tofSignal);
}
