// Flight control

#include "vector.h"
#include "quaternion.h"
#include "pid.h"
#include "lpf.h"
#include "util.h"

#if WEB_RC_ENABLED
#include "control.h"
#endif

// ============== Rate loop (inner loop) parameters ==============
#define PITCHRATE_P 0.05 // higher P for faster response
#define PITCHRATE_I 0.2 // moderate I to compensate motor differences
#define PITCHRATE_D 0.001 // small D to damp oscillation
#define PITCHRATE_I_LIM 0.35 // limit integral windup
#define ROLLRATE_P 0.06 // roll and pitch use the same parameters
#define ROLLRATE_I PITCHRATE_I
#define ROLLRATE_D 0.002
#define ROLLRATE_I_LIM PITCHRATE_I_LIM
#define YAWRATE_P 0.3 // yaw needs higher P (less inertia)
#define YAWRATE_I 0.01 // moderate I compensation
#define YAWRATE_D 0.01 // small D
#define YAWRATE_I_LIM 0.3
// ============== Angle loop (outer loop) parameters ==============
#define ROLL_P 7 // high P for fast response
#define ROLL_I 0 // angle loop usually needs no I term
#define ROLL_D 0 // angle loop usually needs no D term
#define PITCH_P ROLL_P // same as roll
#define PITCH_I ROLL_I
#define PITCH_D ROLL_D
#define YAW_P 3 // yaw responds slightly slower
// ============== Limits ==============
#define PITCHRATE_MAX radians(360) // high rate limit (1000 deg/s)
#define ROLLRATE_MAX radians(360)
#define YAWRATE_MAX radians(300) // yaw rate slightly lower
#define TILT_MAX radians(30) // max tilt angle 30 deg
#define ALTHOLD_HOVER_THRUST 0.5f   // alt-hold base hover thrust (stub, replace once barometer is implemented)
#define ARM_THROTTLE_LIMIT   0.05f  // max throttle allowed for arming (normalized 0~1), 5%; arming refused above this
#define RATES_D_LPF_ALPHA 0.2 // cutoff frequency ~ 40 Hz

float motThrMin = 0.10f;  // min thrust (output at lowest stick position), set via parameter MOT_THR_MIN
float motThrMax = 1.0f;   // max thrust (output at highest stick position), set via parameter MOT_THR_MAX

const int RAW = 0, ACRO = 1, STAB = 2, ALTHOLD = 3, AUTO = 4; // flight modes
int mode = STAB;
bool armed = false;
int flightModes[] = {STAB, STAB, STAB}; // flight modes for the 3 positions of the RC mode switch, set via parameters CTL_FLT_MODE_0/1/2

#if WEB_RC_ENABLED
extern uint16_t webRCButtons;
#endif

PID rollRatePID(ROLLRATE_P, ROLLRATE_I, ROLLRATE_D, ROLLRATE_I_LIM, RATES_D_LPF_ALPHA);
PID pitchRatePID(PITCHRATE_P, PITCHRATE_I, PITCHRATE_D, PITCHRATE_I_LIM, RATES_D_LPF_ALPHA);
PID yawRatePID(YAWRATE_P, YAWRATE_I, YAWRATE_D);
PID rollPID(ROLL_P, ROLL_I, ROLL_D);
PID pitchPID(PITCH_P, PITCH_I, PITCH_D);
PID yawPID(YAW_P, 0, 0);
Vector maxRate(ROLLRATE_MAX, PITCHRATE_MAX, YAWRATE_MAX);
float tiltMax = TILT_MAX;

Quaternion attitudeTarget;
Vector ratesTarget;
Vector ratesExtra; // feedforward rates
Vector torqueTarget;
float thrustTarget;

extern const int MOTOR_REAR_LEFT, MOTOR_REAR_RIGHT, MOTOR_FRONT_RIGHT, MOTOR_FRONT_LEFT;
extern float motors[4];
extern float controlRoll, controlPitch, controlThrottle, controlYaw, controlMode;
extern float batteryVoltage;  // battery.ino

void control() {
	interpretControls();
#if WEB_RC_ENABLED
	interpretWebRC();
#endif
	controlAltitude();
	failsafe();
	controlAttitude();
	controlRates();
	controlTorque();
}

void interpretControls() {
	if (controlMode < 0.25) mode = flightModes[0];
	else if (controlMode <= 0.75) mode = flightModes[1];
	else if (controlMode > 0.75) mode = flightModes[2];

	if (mode == AUTO) return; // pilot is not effective in AUTO mode

#if WEB_RC_ENABLED
	if (!isUsingWebRC()) { // SBUS stick-gesture arming only applies when WebRC is not active
#endif
	static bool armWarnNotified = false;  // anti-spam: low-battery arm refusal message
	if (controlThrottle < 0.05 && controlYaw > 0.95) { // arm gesture
		if (batteryVoltage > VBAT_ABSENT_THRESHOLD && batteryVoltage < VBAT_WARN_THRESHOLD) {
			// L1 or below: arming refused, notify on state change
			if (!armWarnNotified) {
				print("Low battery (%.2fV), arming refused\n", batteryVoltage);
#if WEB_RC_ENABLED
				char warnBuf[64];
				snprintf(warnBuf, sizeof(warnBuf), "Low battery (%.2fV), arming refused", batteryVoltage);
				setWebRCWarn(warnBuf);
#endif
				armWarnNotified = true;
			}
		} else {
			armed = true;
			armWarnNotified = false; // reset after battery swap
		}
	}
	if (controlThrottle < 0.05 && controlYaw < -0.95) armed = false; // disarm gesture
#if WEB_RC_ENABLED
	}
#endif

	if (abs(controlYaw) < 0.1) controlYaw = 0; // yaw dead zone

	if (controlThrottle < 0.05f) {
		thrustTarget = 0.0f;   // bottom dead zone -> idle, PID not running
	} else {
		thrustTarget = mapf(controlThrottle, 0.05f, 1.0f, motThrMin, motThrMax);
	}

	if (mode == STAB || mode == ALTHOLD) { // ALTHOLD: sticks set the attitude, thrust comes from controlAltitude()
		float yawTarget = attitudeTarget.getYaw();
		if (!armed || invalid(yawTarget) || controlYaw != 0) yawTarget = attitude.getYaw(); // reset yaw target
		attitudeTarget = Quaternion::fromEuler(Vector(controlRoll * tiltMax, controlPitch * tiltMax, yawTarget));
		ratesExtra = Vector(0, 0, -controlYaw * maxRate.z); // positive yaw stick means clockwise rotation in FLU
	}

	if (mode == ACRO) {
		attitudeTarget.invalidate(); // skip attitude control
		ratesTarget.x = controlRoll * maxRate.x;
		ratesTarget.y = controlPitch * maxRate.y;
		ratesTarget.z = -controlYaw * maxRate.z; // positive yaw stick means clockwise rotation in FLU
	}

	if (mode == RAW) { // direct torque control
		attitudeTarget.invalidate(); // skip attitude control
		ratesTarget.invalidate(); // skip rate control
		torqueTarget = Vector(controlRoll, controlPitch, -controlYaw) * 0.1;
	}
}

void controlAttitude() {
	if (!armed || attitudeTarget.invalid() || thrustTarget < motThrMin) return; // skip attitude control

	const Vector up(0, 0, 1);
	Vector upActual = Quaternion::rotateVector(up, attitude);
	Vector upTarget = Quaternion::rotateVector(up, attitudeTarget);

	Vector error = Vector::rotationVectorBetween(upTarget, upActual);

	ratesTarget.x = rollPID.update(error.x) + ratesExtra.x;
	ratesTarget.y = pitchPID.update(error.y) + ratesExtra.y;

	float yawError = wrapAngle(attitudeTarget.getYaw() - attitude.getYaw());
	ratesTarget.z = yawPID.update(yawError) + ratesExtra.z;
}


void controlRates() {
	if (!armed || ratesTarget.invalid() || thrustTarget < motThrMin) return; // skip rates control

	Vector error = ratesTarget - rates;

	// Calculate desired torque, where 0 - no torque, 1 - maximum possible torque
	torqueTarget.x = rollRatePID.update(error.x);
	torqueTarget.y = pitchRatePID.update(error.y);
	torqueTarget.z = yawRatePID.update(error.z);
}

void controlTorque() {
	if (!torqueTarget.valid()) return; // skip torque control

	if (!armed) {
		memset(motors, 0, sizeof(motors)); // stop motors if disarmed
		return;
	}

	if (thrustTarget < motThrMin) {
		for (int i = 0; i < 4; i++) motors[i] = motThrMin; // idle thrust
		return;
	}

	motors[MOTOR_FRONT_LEFT] = thrustTarget + torqueTarget.x - torqueTarget.y + torqueTarget.z;
	motors[MOTOR_FRONT_RIGHT] = thrustTarget - torqueTarget.x - torqueTarget.y - torqueTarget.z;
	motors[MOTOR_REAR_LEFT] = thrustTarget + torqueTarget.x + torqueTarget.y - torqueTarget.z;
	motors[MOTOR_REAR_RIGHT] = thrustTarget - torqueTarget.x + torqueTarget.y + torqueTarget.z;

	motors[0] = constrain(motors[0], 0, 1);
	motors[1] = constrain(motors[1], 0, 1);
	motors[2] = constrain(motors[2], 0, 1);
	motors[3] = constrain(motors[3], 0, 1);
}

const char* getModeName() {
	switch (mode) {
		case RAW:     return "RAW";
		case ACRO:    return "ACRO";
		case STAB:    return "STAB";
		case ALTHOLD: return "ALTHOLD";
		case AUTO:    return "AUTO";
		default:      return "UNKNOWN";
	}
}

#if WEB_RC_ENABLED
// Web RC button handling (only ARM/DISARM and mode switching)
void interpretWebRC() {
	if (!isUsingWebRC()) return;

	// Arm/disarm buttons (rising-edge detection, avoids re-triggering every control cycle)
	static uint16_t lastWebRCButtons = 0;
	uint16_t risingEdge = webRCButtons & ~lastWebRCButtons;
	lastWebRCButtons = webRCButtons;

	// Log arm/disarm state changes
	static bool lastArmedState = false;
	if (armed != lastArmedState) {
		print(armed ? "Web RC: armed\n" : "Web RC: disarmed\n");
		lastArmedState = armed;
	}

	// Button 0: arm (rising edge)
	if (risingEdge & 0x0001) {
		if (controlThrottle < ARM_THROTTLE_LIMIT) {
			armed = true;
		} else {
			setWebRCWarn("Throttle too high, cannot arm");
		}
	}

	// Button 1: disarm (rising edge)
	if (risingEdge & 0x0002) {
		armed = false;
	}

	// Button 2: emergency stop (rising edge)
	if (risingEdge & 0x0004) {
		armed = false;
		thrustTarget = 0.0f;
	}

	// Button 6: STAB mode (rising edge)
	if (risingEdge & 0x0040) {
		mode = STAB;
	}

	// Button 7: ACRO mode (rising edge)
	if (risingEdge & 0x0080) {
		mode = ACRO;
	}

	// Button 8: ALTHOLD mode (rising edge) - not implemented yet; switch to STAB instead so the frontend mode cycle doesn't get stuck
	if (risingEdge & 0x0100) {
		mode = STAB;
		setWebRCWarn("Alt-hold not supported yet, switched to STAB");
	}

	// Mode change log
	static int lastMode = STAB;
	if (mode != lastMode) {
		print("Web RC: mode changed to %s\n", getModeName());
		lastMode = mode;
	}
}
#endif
