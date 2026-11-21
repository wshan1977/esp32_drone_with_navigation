ESP32 Drone Flight Controller Firmware

# Hardware

## Supported Hardware
Supports ESP32/ESP32-S3/ESP32-C3
Supports MPU6500/MPU9250 IMUs

Fully compatible with the Chenguang E1 series drones. JLCPCB OSHW Hub project link: https://oshwhub.com/songge8/project_qqqyfdkm

# Changelog

## 20260515
* Improved battery voltage measurement accuracy
* More reasonable low-battery protection thresholds

## 20260430
* Improved low-battery alarm logic: arming blocked on low battery, auto-disarm, auto-land
* Optimized throttle/thrust control logic; added throttle thrust limit parameters MOT_THR_MIN and MOT_THR_MAX
* Improved the web RC interface

## 20260428
* Added support for ESP32-C3 and ESP32-S3

## 20260417
* Fixed a bug where debug logs were displayed incompletely; improved command hint display

## 20260416
* Reduced the print rate of routine RC debug logs
* The server could not accurately monitor network signal quality (the frontend already does this accurately), so server-side network monitoring was removed

## 20260415
* Added LED status indication: board status LED blinks slowly when armed, fast on warnings (low battery, link loss, etc.)
* Motor pins are now parameters, configurable via the debug console
* Wi-Fi SSID and password are now parameters, configurable via the debug console
* Fixed network latency calculation bug
* Raised web RC packet rate to 20Hz; to avoid performance impact, do not exceed 20Hz
* Miscellaneous general updates

## 20260328
* Refactored the web RC core logic
* Removed redundancy from the web RC server side

## 20260327
* Major web RC improvements
* Added web RC debugging features
* Added inverted-flight protection: prolonged inversion is treated as a fault and motors stop to limit damage
