// Gyroscope and accelerometer setup
// Work with the IMU sensor

#include <SPI.h>
#include <FlixPeriph.h>
#include "vector.h"
#include "lpf.h"
#include "util.h"
#include "board_config.h"

MPU9250 imu(SPI, BOARD_SPI_CS);

// IMU mounting orientation (Euler angles, rad). Default (0, 0, -PI/2) matches this PCB:
// chip face up, X silkscreen -> drone right, Y silkscreen -> drone front -> conversion Vector(data.y, -data.x, data.z)
// For other orientations, change this value and run `preset` to reset parameter storage.
Vector imuRotation(0, 0, -PI / 2);

Vector accBias;
Vector accScale(1, 1, 1);
Vector accMax, accMin; // accelerometer extremes collected during calibration
Vector gyroBias;
LowPassFilter<Vector> gyroBiasFilter(0.001); // Gyro bias low-pass estimation filter

void setupIMU() {
	print("Setup IMU\n");
	SPI.begin(BOARD_SPI_SCK, BOARD_SPI_MISO, BOARD_SPI_MOSI, BOARD_SPI_CS);
	imu.begin();
	configureIMU();
}

void configureIMU() {
	imu.setAccelRange(imu.ACCEL_RANGE_4G);
	imu.setGyroRange(imu.GYRO_RANGE_2000DPS);
	imu.setDLPF(imu.DLPF_MAX);
	imu.setRate(imu.RATE_1KHZ_APPROX);
	imu.setupInterrupt();
}

void readIMU() {
	imu.waitForData();
	imu.getGyro(gyro.x, gyro.y, gyro.z);
	imu.getAccel(acc.x, acc.y, acc.z);
	calibrateGyroOnce();
	// apply scale and bias
	acc = (acc - accBias) / accScale;
	gyro = gyro - gyroBias;
	// rotate to body frame using imuRotation Euler angles
	Quaternion rotation = Quaternion::fromEuler(imuRotation);
	acc  = Quaternion::rotateVector(acc,  rotation.inversed());
	gyro = Quaternion::rotateVector(gyro, rotation.inversed());
}

void calibrateGyroOnce() {
	static Delay landedDelay(2);
	if (!landedDelay.update(landed)) return; // calibrate only if definitely stationary

	gyroBias = gyroBiasFilter.update(gyro);
}

void calibrateAccel() {
	print("Calibrating accelerometer\n");
	imu.setAccelRange(imu.ACCEL_RANGE_2G); // the most sensitive mode
	accMax = Vector(-INFINITY, -INFINITY, -INFINITY); // forget extremes from a previous run
	accMin = Vector(INFINITY, INFINITY, INFINITY);
	Vector prevBias = accBias, prevScale = accScale;

	print("1/6 Level: nose forward (normal flight direction), bottom down on a flat surface, perfectly level. Keep still, calibration starts in 8 s;\n");
	pause(8);
	calibrateAccelOnce();
	print("Level calibration done. Continue.\n");
	pause(1);
	print("2/6 Nose up: point the nose at the sky, tail down touching the surface, vertical to the ground. Keep still, calibration starts in 8 s;\n");
	pause(8);
	calibrateAccelOnce();
	print("Nose-up calibration done. Continue.\n");
	pause(1);
	print("3/6 Nose down: point the nose at the ground touching the surface, tail up, vertical to the ground. Keep still, calibration starts in 8 s;\n");
	pause(8);
	calibrateAccelOnce();
	print("Nose-down calibration done. Continue.\n");
	pause(1);
	print("4/6 Right side down: drone right side down touching the surface, left arms up, vertical to the ground. Keep still, calibration starts in 8 s;\n");
	pause(8);
	calibrateAccelOnce();
	print("Right-side-down calibration done. Continue.\n");
	pause(1);
	print("5/6 Left side down: drone left side down touching the surface, right arms up, vertical to the ground. Keep still, calibration starts in 8 s;\n");
	pause(8);
	calibrateAccelOnce();
	print("Left-side-down calibration done. Continue.\n");
	pause(1);
	print("6/6 Upside down: flip the drone completely, top down and bottom up, level and inverted. Keep still, calibration starts in 8 s;\n");
	pause(8);
	calibrateAccelOnce();

	// Each axis must have seen +1 g and -1 g; a repeated pose leaves an axis with scale ~0
	auto scaleOk = [](float s) { return isfinite(s) && s > 0.5f && s < 1.5f; };
	if (!scaleOk(accScale.x) || !scaleOk(accScale.y) || !scaleOk(accScale.z)) {
		print("Calibration failed: scale %.3f %.3f %.3f. Each of the 6 poses must face a different side down. Previous values kept.\n",
			accScale.x, accScale.y, accScale.z);
		accBias = prevBias;
		accScale = prevScale;
		printIMUCalibration();
		configureIMU();
		return;
	}
	printIMUCalibration();
	print("✓ All calibration done! Put the drone upright and run the ps command to view results.\n");
	configureIMU();
	attitude = Quaternion(); // restart the estimate with the new calibration
}

void calibrateAccelOnce() {
	const int samples = 1000;

	// Compute the average of the accelerometer readings
	acc = Vector(0, 0, 0);
	for (int i = 0; i < samples; i++) {
		imu.waitForData();
		Vector sample;
		imu.getAccel(sample.x, sample.y, sample.z);
		acc = acc + sample;
	}
	acc = acc / samples;

	// Update the maximum and minimum values
	if (acc.x > accMax.x) accMax.x = acc.x;
	if (acc.y > accMax.y) accMax.y = acc.y;
	if (acc.z > accMax.z) accMax.z = acc.z;
	if (acc.x < accMin.x) accMin.x = acc.x;
	if (acc.y < accMin.y) accMin.y = acc.y;
	if (acc.z < accMin.z) accMin.z = acc.z;
	// Compute scale and bias
	accScale = (accMax - accMin) / 2 / ONE_G;
	accBias = (accMax + accMin) / 2;
}

void printIMUCalibration() {
	print("gyro bias: %f %f %f\n", gyroBias.x, gyroBias.y, gyroBias.z);
	print("accel bias: %f %f %f\n", accBias.x, accBias.y, accBias.z);
	print("accel scale: %f %f %f\n", accScale.x, accScale.y, accScale.z);
}

void printIMUInfo() {
	imu.status() ? print("status: ERROR %d\n", imu.status()) : print("status: OK\n");
	print("model: %s\n", imu.getModel());
	print("who am I: 0x%02X\n", imu.whoAmI());
	print("rate: %.0f\n", loopRate);
	print("gyro: %f %f %f\n", gyro.x, gyro.y, gyro.z);
	print("acc: %f %f %f\n", acc.x, acc.y, acc.z);
	imu.waitForData();
	Vector rawGyro, rawAcc;
	imu.getGyro(rawGyro.x, rawGyro.y, rawGyro.z);
	imu.getAccel(rawAcc.x, rawAcc.y, rawAcc.z);
	print("raw gyro: %f %f %f\n", rawGyro.x, rawGyro.y, rawGyro.z);
	print("raw acc: %f %f %f\n", rawAcc.x, rawAcc.y, rawAcc.z);
}
