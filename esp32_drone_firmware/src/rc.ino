// Work with the RC receiver

#include <SBUS.h>
#include "util.h"
#include "board_config.h"

SBUS rc(BOARD_RC_SERIAL); // Serial2 on ESP32, Serial1 on ESP32-C3
int rcRxPin = BOARD_RC_RX_PIN; // SBUS RX pin, -1 disables RC, set via parameter RC_RX_PIN
uint16_t channels[16]; // raw rc channels
float controlTime; // time of the last controls update
float channelZero[16]; // calibration zero values
float channelMax[16]; // calibration max values

// Channels mapping (using float to store in parameters):
float rollChannel = NAN, pitchChannel = NAN, throttleChannel = NAN, yawChannel = NAN, modeChannel = NAN;

void setupRC() {
	if (rcRxPin < 0) return; // skip RC init if pin not configured
	print("Setup RC\n");
	rc.begin(rcRxPin);
}

bool readRC() {
	if (rcRxPin < 0) return false; // RC disabled
	if (rc.read()) {
		SBUSData data = rc.data();
		for (int i = 0; i < 16; i++) channels[i] = data.ch[i]; // copy channels data
		normalizeRC();
		controlTime = t;
		return true;
	}
	return false;
}

void normalizeRC() {
	float controls[16];
	for (int i = 0; i < 16; i++) {
		controls[i] = mapf(channels[i], channelZero[i], channelMax[i], 0, 1);
	}
	// Update control values
	controlRoll = rollChannel >= 0 ? controls[(int)rollChannel] : NAN;
	controlPitch = pitchChannel >= 0 ? controls[(int)pitchChannel] : NAN;
	controlYaw = yawChannel >= 0 ? controls[(int)yawChannel] : NAN;
	controlThrottle = throttleChannel >= 0 ? controls[(int)throttleChannel] : NAN;
	controlMode = modeChannel >= 0 ? controls[(int)modeChannel] : NAN;
}

void calibrateRC() {
	uint16_t zero[16];
	uint16_t center[16];
	uint16_t max[16];
	print("1/8 RC calibration: center all sticks [3s]\n");
	pause(8);
	calibrateRCChannel(NULL, zero, zero, "2/8 Left stick: down, right stick: center [3s]\n...     ...\n...     .o.\n.o.     ...\n");
	calibrateRCChannel(NULL, center, center, "3/8 Left stick: center, right stick: center [3s]\n...     ...\n.o.     .o.\n...     ...\n");
	calibrateRCChannel(&throttleChannel, zero, max, "4/8 Throttle channel: left stick fully up (max throttle), right stick: center [3s]\n.o.     ...\n...     .o.\n...     ...\n");
	calibrateRCChannel(&yawChannel, center, max, "5/8 Yaw channel: left stick fully right (yaw right), right stick: center [3s]\n...     ...\n..o     .o.\n...     ...\n");
	calibrateRCChannel(&pitchChannel, zero, max, "6/8 Pitch channel: left stick fully down, right stick fully up (pitch forward) [3s]\n...     .o.\n...     ...\n.o.     ...\n");
	calibrateRCChannel(&rollChannel, zero, max, "7/8 Roll channel: left stick fully down, right stick fully right (roll right) [3s]\n...     ...\n...     ..o\n.o.     ...\n");
	calibrateRCChannel(&modeChannel, zero, max, "8/8 Mode channel: first set the arm switch back to disarmed, then set the mode switch to its highest position (e.g. manual mode) [3s]\n");
	printRCCalibration();
}

// Step 1: initial position:
// - Center all sticks
// - Set all switches to default (usually disarmed/middle position)
// - Hold still for 3 s
// Step 2: basic stick movement:
// - Left stick: down
// - Right stick: center
// - Hold for 3 s
// Step 3: sticks centered:
// - Left stick: center
// - Right stick: center
// - Hold for 3 s
// Step 4: throttle channel detection:
// - Left stick: fully up (max throttle)
// - Right stick: center
// - Hold for 3 s
// -> throttle channel detected automatically
// Step 5: yaw channel detection:
// - Left stick: fully right (yaw right)
// - Right stick: center
// - Hold for 3 s
// -> yaw channel detected automatically
// Step 6: pitch channel detection:
// - Left stick: fully down
// - Right stick: fully up (pitch forward)
// - Hold for 3 s
// -> pitch channel detected automatically
// Step 7: roll channel detection:
// - Left stick: fully down
// - Right stick: fully right (roll right)
// - Hold for 3 s
// -> roll channel detected automatically
// Step 8: mode channel detection:
// - First set the arm switch back to disarmed
// - Then set the mode switch to its highest position (e.g. manual mode)
// - Hold for 3 s
// -> mode channel detected automatically

void calibrateRCChannel(float *channel, uint16_t in[16], uint16_t out[16], const char *str) {
	print("%s", str);
	pause(8);
	for (int i = 0; i < 30; i++) readRC(); // try update 30 times max
	memcpy(out, channels, sizeof(channels));

	if (channel == NULL) return; // no channel to calibrate

	// Find channel that changed the most between in and out
	int ch = -1, diff = 0;
	for (int i = 0; i < 16; i++) {
		if (abs(out[i] - in[i]) > diff) {
			ch = i;
			diff = abs(out[i] - in[i]);
		}
	}
	if (ch >= 0 && diff > 10) { // difference threshold is 10
		*channel = ch;
		channelZero[ch] = in[ch];
		channelMax[ch] = out[ch];
	} else {
		*channel = NAN;
	}
}

void printRCCalibration() {
	print("Control   Ch     Zero   Max\n");
	print("Roll      %-7g%-7g%-7g\n", rollChannel, rollChannel >= 0 ? channelZero[(int)rollChannel] : NAN, rollChannel >= 0 ? channelMax[(int)rollChannel] : NAN);
	print("Pitch     %-7g%-7g%-7g\n", pitchChannel, pitchChannel >= 0 ? channelZero[(int)pitchChannel] : NAN, pitchChannel >= 0 ? channelMax[(int)pitchChannel] : NAN);
	print("Yaw       %-7g%-7g%-7g\n", yawChannel, yawChannel >= 0 ? channelZero[(int)yawChannel] : NAN, yawChannel >= 0 ? channelMax[(int)yawChannel] : NAN);
	print("Throttle  %-7g%-7g%-7g\n", throttleChannel, throttleChannel >= 0 ? channelZero[(int)throttleChannel] : NAN, throttleChannel >= 0 ? channelMax[(int)throttleChannel] : NAN);
	print("Mode      %-7g%-7g%-7g\n", modeChannel, modeChannel >= 0 ? channelZero[(int)modeChannel] : NAN, modeChannel >= 0 ? channelMax[(int)modeChannel] : NAN);
}
