// Wi-Fi support

#if WIFI_ENABLED

#include <WiFi.h>
#include <WiFiAP.h>
#include <WiFiUdp.h>
#include "Preferences.h"

extern Preferences storage; // Reuse main storage

const int W_DISABLED = 0, W_AP = 1, W_STA = 2;
int wifiMode = W_AP; // stored as WIFI_MODE, changed by the ap/sta commands
int udpLocalPort = 14550;
int udpRemotePort = 14550;
IPAddress udpRemoteIP = "255.255.255.255"; // broadcast until a GCS talks to us, so it can find the drone

#define WIFI_HOSTNAME          "xw-drone"
#define WIFI_STA_FALLBACK_TIME 30 // start the recovery AP if the router isn't reached in this time, s

WiFiUDP udp;

String getStoredString(const char *key, const char *defaultValue) {
	return storage.isKey(key) ? storage.getString(key, defaultValue) : String(defaultValue);
}

void startAP() {
	WiFi.softAP(getStoredString("WIFI_AP_SSID", "XW_Drone_WiFi").c_str(),
		getStoredString("WIFI_AP_PASS", "12345678").c_str());
}

void setupWiFi() {
	print("Setup Wi-Fi\n");
	// wifiMode is the WIFI_MODE parameter (loaded by setupParameters as a float).
	// An earlier build stored it as an int under the same key; migrate that once.
	if (storage.getType("WIFI_MODE") == PT_I32) {
		wifiMode = storage.getInt("WIFI_MODE");
		storage.remove("WIFI_MODE");
		storage.putFloat("WIFI_MODE", wifiMode);
	}
	String ssid = getStoredString("WIFI_STA_SSID", "");
	if (wifiMode == W_STA && ssid.isEmpty()) wifiMode = W_AP;

	if (wifiMode == W_AP) {
		WiFi.mode(WIFI_AP);
		startAP();
		print("Wi-Fi AP \"%s\" IP %s\n", WiFi.softAPSSID().c_str(), WiFi.softAPIP().toString().c_str());
	} else if (wifiMode == W_STA) {
		WiFi.mode(WIFI_STA);
		WiFi.setHostname(WIFI_HOSTNAME);
		WiFi.begin(ssid.c_str(), getStoredString("WIFI_STA_PASS", "").c_str());
		print("Connecting to Wi-Fi \"%s\"...\n", ssid.c_str());
	}
	WiFi.setSleep(false); // disable power save
	udp.begin(udpLocalPort);
}

// Report STA connection changes; open the recovery AP if the router can't be reached
void handleWiFi() {
	static Rate rate(2);
	static bool wasConnected = false;
	static bool fallbackAP = false;
	if (wifiMode != W_STA || !rate) return;

	bool connected = WiFi.isConnected();
	if (connected && !wasConnected) {
		print("Wi-Fi connected: \"%s\" IP %s\n", WiFi.SSID().c_str(), WiFi.localIP().toString().c_str());
#if WEB_RC_ENABLED
		print("Web RC address: http://%s:8080\n", WiFi.localIP().toString().c_str());
#endif
	} else if (!connected && wasConnected) {
		print("Wi-Fi disconnected, reconnecting...\n");
	}
	wasConnected = connected;

	if (!connected && !fallbackAP && t > WIFI_STA_FALLBACK_TIME) {
		fallbackAP = true;
		WiFi.mode(WIFI_AP_STA);
		startAP();
		print("Router not reached, recovery AP started: %s (192.168.4.1)\n", WiFi.softAPSSID().c_str());
	}
}

void sendWiFi(const uint8_t *buf, int len) {
	if (WiFi.softAPgetStationNum() == 0 && !WiFi.isConnected()) return;
	udp.beginPacket(udpRemoteIP, udpRemotePort);
	udp.write(buf, len);
	udp.endPacket();
}

int receiveWiFi(uint8_t *buf, int len) {
	udp.parsePacket();
	if (udp.remoteIP()) udpRemoteIP = udp.remoteIP();
	return udp.read(buf, len);
}

void printWiFiInfo() {
	if (WiFi.getMode() == WIFI_MODE_AP) {
		print("Mode: Access Point (AP)\n");
		print("MAC: %s\n", WiFi.softAPmacAddress().c_str());
		print("SSID: %s\n", WiFi.softAPSSID().c_str());
		print("Password: ***\n");
		print("Clients: %d\n", WiFi.softAPgetStationNum());
		print("IP: %s\n", WiFi.softAPIP().toString().c_str());
	} else if (WiFi.getMode() & WIFI_MODE_STA) {
		print("Mode: Client (STA)\n");
		print("Connected: %d\n", WiFi.isConnected());
		print("MAC: %s\n", WiFi.macAddress().c_str());
		print("SSID: %s\n", WiFi.SSID().c_str());
		print("Password: ***\n");
		print("IP: %s\n", WiFi.localIP().toString().c_str());
	} else {
		print("Mode: Disabled\n");
		return;
	}
	print("Remote IP: %s\n", udpRemoteIP.toString().c_str());
	print("MAVLink connected: %d\n", mavlinkConnected);
}

// ap/sta commands: select the Wi-Fi mode; with arguments also store the SSID and password
void configWiFi(bool ap, const char *ssid, const char *password) {
	if (strlen(ssid) > 0) {
		storage.putString(ap ? "WIFI_AP_SSID" : "WIFI_STA_SSID", ssid);
		storage.putString(ap ? "WIFI_AP_PASS" : "WIFI_STA_PASS", password);
	} else if (!ap && getStoredString("WIFI_STA_SSID", "").isEmpty()) {
		print("Usage: sta <ssid> <password>\n");
		return;
	}
	wifiMode = ap ? W_AP : W_STA;
	storage.putFloat("WIFI_MODE", wifiMode); // save now: a reboot usually follows before syncParameters() runs
	print("Wi-Fi mode: %s. Reboot to apply\n", ap ? "AP" : "STA (router)");
}

#endif
