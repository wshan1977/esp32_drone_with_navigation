// Fail-safe functions

bool isInverted = false;  // whether the airframe is currently inverted (Z-axis cos < INVERTED_COS_THRESHOLD)

float rcLossTimeout = 1;        // RC loss timeout (s), set via parameter SF_RC_LOSS_TIME
float descendTime = 10;         // time to descend to motor stop (s), set via parameter SF_DESCEND_TIME
#define WEB_RC_LOSS_TIMEOUT_MS 8000UL  // Web RC link-loss threshold (ms), must be greater than the 2000 ms heartbeat interval

// Inversion protection parameters
#define INVERTED_COS_THRESHOLD -0.7f   // cos(134 deg); tilt beyond 134 deg counts as inverted (leaves margin for gyro drift)
#define INVERTED_TIMEOUT        1.5f   // stop motors if inverted for more than 1.5 s

extern float controlTime;
extern float controlRoll, controlPitch, controlThrottle, controlYaw;

#if WEB_RC_ENABLED
// Web RC variable declarations
extern bool webRCEnabled;
extern bool useWebRC;
extern unsigned long webRCLastUpdate;
bool isUsingWebRC();
#endif

extern bool armed;
extern int mode;
extern float dt;
extern float thrustTarget;
extern float t;
extern float batteryVoltage, batteryRestVoltage;  // battery.ino
extern Quaternion attitudeTarget;
extern Quaternion attitude;

void failsafe() {
	rcLossFailsafe();
#if WEB_RC_ENABLED
	webRCLossFailsafe();
#endif
	autoFailsafe();
	invertedFailsafe();
	batteryFailsafe();
	altitudeFailsafe();
}

// RC loss failsafe
void rcLossFailsafe() {
	if (controlTime == 0) return; // no RC at all
	if (!armed) return;
	if (mode == ALTHOLD) return; // altitude hold doesn't need the sticks; it has its own GCS link check
#if WEB_RC_ENABLED
	if (isUsingWebRC()) return; // WebRC handles its own timeout (webRCLossFailsafe)
#endif
	if (t - controlTime > rcLossTimeout) {
		descend();
	}
}

// Smooth descend on RC lost
void descend() {
	mode = AUTO;
	attitudeTarget = Quaternion();
	thrustTarget -= dt / descendTime;
	if (thrustTarget < 0) {
		thrustTarget = 0;
		if (armed) print("Descend finished: disarmed (control link lost or battery critical)\n");
		armed = false;
	}
}

// Allow pilot to interrupt automatic flight
void autoFailsafe() {
	static float roll, pitch, yaw, throttle;

	// control* already unifies SBUS/MAVLink/WebRC input, so check it directly
	if (roll != controlRoll || pitch != controlPitch || yaw != controlYaw || abs(throttle - controlThrottle) > 0.05) {
		if (mode == AUTO) mode = STAB;
	}

	roll = controlRoll;
	pitch = controlPitch;
	yaw = controlYaw;
	throttle = controlThrottle;
}

#if WEB_RC_ENABLED
// Web RC loss failsafe
void webRCLossFailsafe() {
	if (!webRCEnabled || !useWebRC) return;
	if (!armed) return;

	// Compare in milliseconds directly, avoiding up to 1 s error from integer division
	if (millis() - webRCLastUpdate > WEB_RC_LOSS_TIMEOUT_MS) {
		print("Web RC link lost, descending\n");
		descend();
		webRCEnabled = false;
		useWebRC = false;
	}
}
#endif

// Inversion protection: stop motors if the angle between body Z and world Z exceeds 120 deg for 1.5 s
void invertedFailsafe() {
	if (!armed) {
		isInverted = false;
		return;
	}

	// World-frame Z component of the body Z axis: ~+1 upright, ~-1 inverted
	Vector worldUp = Quaternion::rotateVector(Vector(0, 0, 1), attitude);

	static float invertedStartTime = 0;
	if (worldUp.z < INVERTED_COS_THRESHOLD) {
		isInverted = true;
		if (invertedStartTime == 0) invertedStartTime = t;
		if (t - invertedStartTime > INVERTED_TIMEOUT) {
			armed = false;
			thrustTarget = 0.0f;
			invertedStartTime = 0;
			print("Inversion protection: motors stopped\n");
		}
	} else {
		isInverted = false;
		invertedStartTime = 0;
	}
}

// Battery voltage protection
// L1 (3.5V, rest voltage): arming refused (control.ino gesture, mavlink.ino GCS arm)
// L2 (3.3V): in flight, LED fast-blink warning only
// L3 (3.0V, under load): armed at idle -> auto-disarm; in flight -> auto-land (descend(), SF_DESCEND_TIME)
void batteryFailsafe() {
	static bool l3Latched = false;
	static float lowSince = 0.0f;
	static float l3LastNotify = 0.0f;

	if (batteryVoltage < VBAT_ABSENT_THRESHOLD) return; // no battery connected, ignore
	if (!armed) {
		l3Latched = false;
		lowSince = 0.0f;
		l3LastNotify = 0.0f;
		return;
	}

	// Once L3 triggers, keep descending until disarmed, to avoid toggling around the threshold
	if (l3Latched) {
		if (t - l3LastNotify >= 2.0f) {
			print("Battery critical (%.2fV), still descending, thrust %.0f%%\n",
			      batteryVoltage, thrustTarget * 100.0f);
#if WEB_RC_ENABLED
			char warnBuf[64];
			snprintf(warnBuf, sizeof(warnBuf),
			         "Battery critical (%.2fV) descending, thrust %.0f%%",
			         batteryVoltage, thrustTarget * 100.0f);
			setWebRCWarn(warnBuf);
#endif
			l3LastNotify = t;
		}
		descend();
		return;
	}

	bool flying = thrustTarget >= BATTERY_FLYING_THRUST_MIN;

	bool actionCondition = false;
	bool criticalAction = false;

	// In flight: only L3 triggers a hard action; L2 is still handled by LED warning
	if (flying) {
		if (batteryVoltage < VBAT_CRITICAL_THRESHOLD) {
			actionCondition = true;
			criticalAction = true;
		}
	} else {
		// Armed at idle: the motors already load the battery (idle spin sags it ~0.5-0.7 V),
		// so the rest-voltage L1 limit doesn't apply here; L1 is checked before arming instead
		if (batteryVoltage < VBAT_CRITICAL_THRESHOLD) {
			actionCondition = true;
		}
	}

	if (!actionCondition) {
		lowSince = 0.0f;
		return;
	}

	if (lowSince == 0.0f) lowSince = t;
	if (t - lowSince < BATTERY_ACTION_DEBOUNCE_TIME) return;

	lowSince = 0.0f;
	if (criticalAction) {
		l3Latched = true;
		l3LastNotify = 0.0f;
		print("Battery critical (%.2fV), auto-landing\n", batteryVoltage);
#if WEB_RC_ENABLED
		char warnBuf[64];
		snprintf(warnBuf, sizeof(warnBuf),
		         "Battery critical (%.2fV) auto-landing",
		         batteryVoltage);
		setWebRCWarn(warnBuf);
#endif
		descend();
		return;
	}

	armed = false;
	thrustTarget = 0.0f;
	print("Low battery (%.2fV, %.2fV before arming), auto-disarmed\n", batteryVoltage, batteryRestVoltage);
#if WEB_RC_ENABLED
	char warnBuf[64];
	snprintf(warnBuf, sizeof(warnBuf), "Low battery (%.2fV) auto-disarmed", batteryVoltage);
	setWebRCWarn(warnBuf);
#endif
}
