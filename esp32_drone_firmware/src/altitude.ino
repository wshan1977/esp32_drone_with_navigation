// Altitude estimation (downward ToF + accelerometer) and altitude hold (ALTHOLD mode),
// with take-off and landing sequences

#include "vector.h"
#include "quaternion.h"
#include "pid.h"
#include "lpf.h"
#include "util.h"

#define ALT_K_POS            8.0f  // observer gain: ToF height error -> altitude (1/s)
#define ALT_K_VEL            16.0f // observer gain: ToF height error -> climb rate (1/s^2)
#define ALT_TOF_TIMEOUT      0.3f  // altitude is invalid without fresh ToF data for this long, s
#define ALT_COS_TILT_MIN     0.7f  // limit of tilt compensation (~45 deg)
#define ALT_TAKEOFF_MIN      0.2f  // lowest take-off / setpoint height, m
#define ALT_LANDED_HEIGHT    0.06f // below this height while landing the drone is on the ground, m
#define ALT_LANDED_CLIMB     0.15f // and moving slower than this, m/s
#define ALT_LANDED_TIME      1.0f  // for this long, s
#define ALT_GCS_TIMEOUT      1.0f  // land if the GCS that commanded the flight goes silent, s
#define ALT_INPUT_TIMEOUT    0.3f  // level the drone if GCS tilt commands stop for this long, s
#define ALT_AIRBORNE_HEIGHT  0.05f // above this the drone is in the air (control integrators enabled), m
#define ALT_ACC_LIMIT        4.0f  // clamp of the vertical acceleration used for prediction, m/s^2
#define ALT_ACC_CHECK        0.3f  // take-off needs the filtered |acc| within this fraction of 1 g (calibrated accelerometer)

extern bool armed;
extern int mode;
extern const int STAB, ALTHOLD;
extern float thrustTarget, motThrMin;
extern bool tofEnabled;
extern float tofRange, tofTime;
extern float controlTime;

float altitude = NAN;       // height above the take-off surface, m
float climbRate = 0;        // vertical speed, m/s (up +)
float altGround = NAN;      // tilt-compensated ToF reading on the ground, m
float altValidTime = NAN;   // time of the last ToF fusion
float altitudeSetpoint = 0; // commanded height, m
float altitudeTarget = 0;   // rate-limited setpoint followed by the controller, m
bool altHoldActive = false;
bool altRampStart = true;   // next controlAltitude() step starts the thrust ramp
float altLastThrust = 0;
bool landing = false;
bool altLost = false;       // ToF lost in flight: failsafe descend
bool gcsFlight = false;     // flight commanded over MAVLink: GCS link loss lands
float gcsLastSeen = NAN;    // time of the last MAVLink packet, set in mavlink.ino

float altHoverThrust = 0.5; // thrust that holds the drone in the air, set via ALT_HOVER_THR
float altPosP = 1.5;        // altitude error -> climb rate (1/s), ALT_P
float altClimbMax = 0.4;    // m/s, ALT_CLIMB_MAX
float altLandSpeed = 0.25;  // m/s, ALT_LAND_SPD
float altMax = 2.0;         // ceiling, m, ALT_MAX
float altThrMax = 0.85;     // thrust limit in ALTHOLD, ALT_THR_MAX
float altThrSlew = 2.0;     // max thrust increase per second, softens the motor current surge at take-off, ALT_THR_SLEW
float altSpoolThrust = 0.7; // take-off starts at this fraction of hover thrust: a slow spin-up skids the drone sideways, ALT_SPOOL
PID climbPID(0.15, 0.3, 0, 0.25); // climb rate error -> thrust correction, ALT_VEL_P/I

LowPassFilter<float> accVertFilter(0.1);
LowPassFilter<float> accNormFilter(0.001); // ~1.5 s average of |acc|: motor vibration makes single samples swing ±30%

bool altitudeValid() {
	return !isnan(altitude) && t - altValidTime < ALT_TOF_TIMEOUT;
}

// Off the ground. On the ground the attitude controllers can't move the frame, so their integrators
// must not run (they wind up and drive single motors or a diagonal pair to zero)
bool airborne() {
	if (altitudeValid()) return altitude > ALT_AIRBORNE_HEIGHT;
	return thrustTarget > altHoverThrust * 0.8f; // no ToF: assume lift-off near hover thrust
}

float cosTilt() {
	Vector up = Quaternion::rotateVector(Vector(0, 0, 1), attitude); // world up in body frame, as in applyAcc()
	return max(up.z, ALT_COS_TILT_MIN);
}

void estimateAltitude() {
	if (!tofEnabled) return;

	// predict with the vertical acceleration
	Vector up = Quaternion::rotateVector(Vector(0, 0, 1), attitude);
	accNormFilter.update(acc.norm());
	float accVert = accVertFilter.update(constrain(Vector::dot(acc, up) - ONE_G, -ALT_ACC_LIMIT, ALT_ACC_LIMIT));
	if (!isnan(altitude)) {
		climbRate += accVert * dt;
		altitude += climbRate * dt;
	}

	// correct with each new ToF measurement
	static float lastTofTime = NAN;
	if (isnan(tofTime) || tofTime == lastTofTime) return;
	float dtTof = tofTime - lastTofTime; // NAN on the first sample
	lastTofTime = tofTime;
	float height = tofRange * max(up.z, ALT_COS_TILT_MIN);

	if (!armed) { // sitting on the ground: track the ground level
		altGround = isnan(altGround) ? height : altGround + 0.1f * (height - altGround);
		altitude = height - altGround;
		climbRate = 0;
		altValidTime = t;
		return;
	}
	height -= altGround;
	if (isnan(altitude) || !(dtTof > 0 && dtTof < 0.5f)) {
		altitude = height;
		climbRate = 0;
	} else {
		float error = height - altitude;
		altitude += ALT_K_POS * error * dtTof;
		climbRate += ALT_K_VEL * error * dtTof;
	}
	altValidTime = t;
}

bool startTakeoff(float height) {
	if (!armed) {
		print("Take-off refused: not armed\n");
		return false;
	}
	if (!altitudeValid() || isnan(altGround)) {
		print("Take-off refused: no ToF altitude\n");
		return false;
	}
	float accNorm = accNormFilter.output;
	if (abs(accNorm - ONE_G) > ONE_G * ALT_ACC_CHECK) {
		print("Take-off refused: accelerometer reads %.1f m/s^2, calibrate it (ca)\n", accNorm);
		return false;
	}
	altitudeTarget = altitude;
	altitudeSetpoint = constrain(height, ALT_TAKEOFF_MIN, altMax);
	climbPID.reset();
	landing = false;
	altLost = false;
	altHoldActive = true;
	altRampStart = true;
	mode = ALTHOLD;
	print("Take-off to %.2f m\n", altitudeSetpoint);
	return true;
}

bool startLanding() {
	if (mode != ALTHOLD || !armed) return false;
	if (!landing) print("Landing\n");
	landing = true;
	altitudeSetpoint = -0.3; // below the ground: keep descending until touchdown is detected
	return true;
}

void setAltitudeSetpoint(float height) {
	if (mode != ALTHOLD || landing) return;
	altitudeSetpoint = constrain(height, ALT_TAKEOFF_MIN, altMax);
}

void controlAltitude() {
	if (mode != ALTHOLD) {
		altHoldActive = false;
		landing = false;
		return;
	}
	if (!armed) {
		mode = STAB;
		return;
	}
	if (!altitudeValid()) {
		print("ToF altitude lost, descending\n");
		altLost = true; // handled by altitudeFailsafe()
		mode = STAB;
		return;
	}
	if (!altHoldActive) { // switched to ALTHOLD in flight: hold the current height
		altitudeTarget = altitudeSetpoint = altitude;
		climbPID.reset();
		altHoldActive = true;
		altRampStart = true;
	}
	if (gcsFlight && !landing && t - gcsLastSeen > ALT_GCS_TIMEOUT) {
		print("GCS link lost, landing\n");
		startLanding();
	}

	// move the target toward the setpoint at a limited speed
	float downSpeed = landing ? altLandSpeed : altClimbMax;
	altitudeTarget += constrain(altitudeSetpoint - altitudeTarget, -downSpeed * dt, altClimbMax * dt);

	float climbTarget = constrain(altPosP * (altitudeTarget - altitude), -downSpeed, altClimbMax);
	float thrust = (altHoverThrust + climbPID.update(climbTarget - climbRate)) / cosTilt();
	// thrustTarget still holds the stick thrust here (idle on the ground), so the ramp starts from the current thrust
	if (altRampStart) {
		altLastThrust = max(thrustTarget, motThrMin);
		if (!airborne()) altLastThrust = max(altLastThrust, altHoverThrust * altSpoolThrust); // jump close to lift-off
	}
	altRampStart = false;
	thrust = min(thrust, altLastThrust + altThrSlew * dt); // only increases are rate limited
	thrustTarget = constrain(thrust, motThrMin, altThrMax);
	altLastThrust = thrustTarget;

	// touchdown detection
	static float landedSince = NAN;
	if (landing && altitude < ALT_LANDED_HEIGHT && abs(climbRate) < ALT_LANDED_CLIMB) {
		if (isnan(landedSince)) landedSince = t;
		if (t - landedSince > ALT_LANDED_TIME) {
			print("Landed, disarmed\n");
			armed = false;
			mode = STAB;
			gcsFlight = false;
			landedSince = NAN;
		}
	} else {
		landedSince = NAN;
	}
}

// In ALTHOLD the GCS position controller streams roll/pitch as MANUAL_CONTROL. If that stream stops,
// level the drone instead of keeping the last tilt (the GCS link check lands it later)
void altHoldInputTimeout() {
	if (mode != ALTHOLD || t - controlTime < ALT_INPUT_TIMEOUT) return;
	controlRoll = 0;
	controlPitch = 0;
	controlYaw = 0;
}

// Called from failsafe(): descend open-loop when the altitude source is gone
void altitudeFailsafe() {
	if (!altLost) return;
	if (!armed) {
		altLost = false;
		gcsFlight = false;
		return;
	}
	descend();
}

void printAltitudeInfo() {
	print("altitude: %.3f m  climb: %.2f m/s  valid: %d\n", altitude, climbRate, altitudeValid());
	print("target: %.2f m  setpoint: %.2f m  landing: %d\n", altitudeTarget, altitudeSetpoint, landing);
	print("ground: %.3f m  hover thrust: %.2f  thrust: %.2f\n", altGround, altHoverThrust, thrustTarget);
}
