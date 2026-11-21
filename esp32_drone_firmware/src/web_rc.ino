// Web RC server

#if WEB_RC_ENABLED

#include <WebServer.h>
#include <ESPmDNS.h>
#include <WiFi.h>
#include "web_rc_html.h"

// Unified FC control variables (written by protocol adapters; shared with SBUS/MAVLink)
extern float t;
extern float controlTime;
extern float controlRoll, controlPitch, controlYaw, controlThrottle, controlMode;

// ==================== Config constants ====================
#define WEB_RC_TIMEOUT_MS    10000          // Connection timeout: no packet for this long (ms) = disconnected; must exceed heartbeat interval
// VBAT_ADC_PIN / VBAT_ADC_SAMPLES / VBAT_DIVIDER moved to battery.ino

// ==================== Connection state flags ====================
bool webRCEnabled    = false;  // Web RC has an active connection (updated every loop by readWebRC())
bool useWebRC        = false;  // Web RC is currently in control (kept in sync with webRCEnabled)
bool webRCUpdated    = false;  // At least one packet received (false before first connection)
bool webConsoleEnabled = false; // Web debug console switch: enabled by POST /console/enable; print() then writes to the buffer
static char webRCWarnMsg[64] = ""; // Pending warning for the frontend; cleared after being sent once

// ==================== Cached stick values (read by status endpoint) ====================
// Units: throttle 0~100 (%), attitude axes +/-30 (deg), buttons pressed=1/released=0
float webRCRoll     = 0.0f;
float webRCPitch    = 0.0f;
float webRCYaw      = 0.0f;
float webRCThrottle = 0.0f;
uint16_t webRCButtons    = 0;       // 16-bit button mask: bit0=arm bit1=disarm bit2=e-stop bit6=STAB bit7=ACRO bit8=ALTHOLD
unsigned long webRCLastUpdate = 0;  // millis() timestamp of last received packet

// ==================== Sensitivity scaling ====================
// Final output = processed angle * scale / STICK_MAX, written to control* ([-1,1])
// Lower scale -> softer response; higher -> more sensitive
float webRCThrottleScale = 1.0f;    // Max throttle limit: 1.0=100%, 0.8=throttle capped at 80%
float webRCStickScale    = 0.85f;   // Roll/pitch sensitivity, suggested 0.5~1.0
float webRCYawScale      = 0.68f;   // Yaw sensitivity, lower because yaw inertia is small; suggested 0.3~0.8

// ==================== Deadzone ====================
// In normalized space (0~1 ratio); stick centering error within the deadzone outputs 0
// Larger -> wider neutral zone, fewer accidental inputs; smaller -> more responsive but may drift
float stickDeadzone    = 0.06f;     // Shared by roll/pitch/yaw, 6% normalized deadzone
float throttleDeadzone = 0.06f;     // Throttle low-end deadzone: below this ratio output is 0% (debounce)

// ==================== Input ranges (do not change casually; must match frontend) ====================
static const float THROTTLE_MIN = 0.0f;    // Throttle output min (%)
static const float THROTTLE_MAX = 100.0f;  // Throttle output max (%)
static const float STICK_MAX    = 30.0f;   // Max attitude angle (deg) at full stick; changing it requires adjusting PID TILT_MAX
static const float RAW_MAX      = 100.0f;  // Frontend full-scale stick value; frontend JS always outputs +/-100

// ==================== Internal state (runtime, do not modify manually) ====================
static float lastValidThrottle = 0.0f;     // Last validated throttle, used as fallback on bad data
static float lastValidRoll     = 0.0f;     // Last validated roll
static float lastValidPitch    = 0.0f;     // Last validated pitch
static float lastValidYaw      = 0.0f;     // Last validated yaw
static unsigned long lastDataErrorTime = 0; // Time of last bad data, used to rate-limit error logs

// ==================== Web server ====================
WebServer webRCServer(8080);

// ==================== Console log buffer ====================
#define CONSOLE_LINES    50
#define CONSOLE_LINE_LEN 240
static char consoleBuf[CONSOLE_LINES][CONSOLE_LINE_LEN];
static int  consoleTail   = 0;
static int  consoleFilled = 0;
static int  consoleTotal  = 0;   // Monotonic total line count, for incremental fetch

#define CONSOLE_CMD_QUEUE_SIZE 4
#define CONSOLE_CMD_LEN 64
static char consoleCmdQueue[CONSOLE_CMD_QUEUE_SIZE][CONSOLE_CMD_LEN];
static int  consoleCmdHead  = 0;
static int  consoleCmdTail  = 0;
static int  consoleCmdCount = 0;

bool enqueueConsoleCmd(const char* cmd) {
    if (!cmd || !*cmd) return false;
    if (consoleCmdCount >= CONSOLE_CMD_QUEUE_SIZE) return false;
    strncpy(consoleCmdQueue[consoleCmdTail], cmd, CONSOLE_CMD_LEN - 1);
    consoleCmdQueue[consoleCmdTail][CONSOLE_CMD_LEN - 1] = '\0';
    consoleCmdTail = (consoleCmdTail + 1) % CONSOLE_CMD_QUEUE_SIZE;
    consoleCmdCount++;
    return true;
}

void processConsoleCommandQueue() {
    if (consoleCmdCount <= 0) return;

    String cmd = consoleCmdQueue[consoleCmdHead];
    consoleCmdHead = (consoleCmdHead + 1) % CONSOLE_CMD_QUEUE_SIZE;
    consoleCmdCount--;
    doCommand(cmd, false);
}

void webLog(const char* msg) {
    // Split on \n so newlines don't corrupt the JSON
    const char* start = msg;
    while (*start) {
        const char* end = strchr(start, '\n');
        int len = end ? (int)(end - start) : (int)strlen(start);
        if (len > 0) {
            int copy = (len < CONSOLE_LINE_LEN - 1) ? len : (CONSOLE_LINE_LEN - 1);
            strncpy(consoleBuf[consoleTail], start, copy);
            consoleBuf[consoleTail][copy] = '\0';
            consoleTail = (consoleTail + 1) % CONSOLE_LINES;
            if (consoleFilled < CONSOLE_LINES) consoleFilled++;
            consoleTotal++;
        }
        if (!end) break;
        start = end + 1;
    }
}

// ==================== Stick processing ====================

// Normalized-space deadzone (input/output both in [-1, 1])
// The part beyond the deadzone is linearly remapped to full range; full stick = full output
float applyDeadzone(float norm, float deadzone) {
    if (fabsf(norm) < deadzone) return 0.0f;
    float sign = (norm > 0.0f) ? 1.0f : -1.0f;
    return sign * (fabsf(norm) - deadzone) / (1.0f - deadzone);
}

// Process attitude axis (roll/pitch/yaw)
// Input raw in [-100, +100], output in [-STICK_MAX, +STICK_MAX] (deg)
float processAxis(float raw, float& lastValid) {
    if (isnan(raw) || isinf(raw) || fabsf(raw) > 1000.0f) {
        if (millis() - lastDataErrorTime > 2000) lastDataErrorTime = millis();
        return lastValid;
    }
    float norm = constrain(raw, -RAW_MAX, RAW_MAX) / RAW_MAX;
    norm = applyDeadzone(norm, stickDeadzone);
    lastValid = norm * STICK_MAX;
    return lastValid;
}

// Process throttle axis
// Frontend: left stick Y axis, bottom=-100, top=+100
// Output: pct in [0, 100]
float processThrottle(float raw) {
    if (isnan(raw) || isinf(raw) || fabsf(raw) > 1000.0f) return lastValidThrottle;
    raw = constrain(raw, -RAW_MAX, RAW_MAX);
    // Linear map: -100->0%, 0->50%, +100->100%
    float pct = (raw + RAW_MAX) / (2.0f * RAW_MAX) * THROTTLE_MAX;
    if (pct < throttleDeadzone * THROTTLE_MAX) pct = 0.0f;
    pct = constrain(pct * webRCThrottleScale, THROTTLE_MIN, THROTTLE_MAX);
    lastValidThrottle = pct;
    return pct;
}

// ==================== Core data processing ====================

void setWebRCInput(float roll, float pitch, float yaw, float throttle, uint16_t buttons) {
    float pThrottle = processThrottle(throttle);
    float pYaw      = processAxis(yaw,   lastValidYaw);
    float pPitch    = processAxis(pitch, lastValidPitch);
    float pRoll     = processAxis(roll,  lastValidRoll);

    // Cache processed values (read by status endpoint)
    webRCThrottle = pThrottle;
    webRCYaw      = pYaw;
    webRCPitch    = pPitch;
    webRCRoll     = pRoll;
    webRCButtons  = buttons;
    webRCLastUpdate = millis();
    webRCUpdated  = true;

    // Write unified control variables (same path as SBUS/MAVLink)
    controlRoll     = constrain(pRoll  * webRCStickScale / STICK_MAX, -1.0f, 1.0f);
    controlPitch    = constrain(pPitch * webRCStickScale / STICK_MAX, -1.0f, 1.0f);
    controlYaw      = constrain(pYaw   * webRCYawScale   / STICK_MAX, -1.0f, 1.0f);
    controlThrottle = pThrottle / THROTTLE_MAX;
    controlMode     = NAN;
    controlTime     = t;

    static float lastPrintedThrottle = -1.0f;
    if (fabsf(pThrottle - lastPrintedThrottle) > 5.0f) {
        print("WebRC T=%.0f%% R=%.1f P=%.1f Y=%.1f Btn=0x%04X\n",
              pThrottle, pRoll, pPitch, pYaw, buttons);
        lastPrintedThrottle = pThrottle;
    }
}

// ==================== JSON protocol handler ====================

const char* findJsonValue(const char* json, const char* key) {
    const char* p = strstr(json, key);
    if (!p) return nullptr;
    p = strchr(p, ':');
    if (!p) return nullptr;
    p++;
    while (*p == ' ' || *p == '"') p++;
    return p;
}

bool handleJSONProtocol(String& body) {
    if (body.length() == 0 || body.indexOf('{') == -1) return false;
    const char* json = body.c_str();
    const char* typePos = strstr(json, "\"t\":");
    if (!typePos) return false;
    int type = atoi(typePos + 4);
    const char* v;

    switch (type) {
        case 1: { // stick data
            float th = 0, r = 0, p = 0, y = 0;
            uint32_t ts = 0;
            if ((v = findJsonValue(json, "\"th\""))) th = atof(v);
            if ((v = findJsonValue(json, "\"r\"")))  r  = atof(v);
            if ((v = findJsonValue(json, "\"p\"")))  p  = atof(v);
            if ((v = findJsonValue(json, "\"y\"")))  y  = atof(v);
            if ((v = findJsonValue(json, "\"ts\""))) ts = atol(v);
            setWebRCInput(r, p, y, th, webRCButtons);
            break;
        }
        case 2: { // button event
            int idx = 0, state = 0;
            uint32_t ts = 0;
            if ((v = findJsonValue(json, "\"b\"")))  idx   = atoi(v);
            if ((v = findJsonValue(json, "\"s\"")))  state = atoi(v);
            if ((v = findJsonValue(json, "\"ts\""))) ts    = atol(v);
            if (idx >= 0 && idx < 16) {
                if (state) webRCButtons |=  (1 << idx);
                else       webRCButtons &= ~(1 << idx);
                webRCLastUpdate = millis();
                webRCUpdated    = true;
            }
            break;
        }
        case 4: // heartbeat
            webRCLastUpdate = millis();
            webRCUpdated    = true;
            break;
    }
    return true;
}

void setWebRCWarn(const char* msg) {
    strncpy(webRCWarnMsg, msg, sizeof(webRCWarnMsg) - 1);
    webRCWarnMsg[sizeof(webRCWarnMsg) - 1] = '\0';
}

// ==================== HTTP request handling ====================

void handleWebRCRequest() {
    if (!webRCServer.hasArg("plain")) {
        webRCServer.send(400, "application/json", "{\"e\":\"no data\"}");
        return;
    }
    String body = webRCServer.arg("plain");
    if (handleJSONProtocol(body)) {
        char resp[256];
        if (webRCWarnMsg[0]) {
            snprintf(resp, sizeof(resp),
                "{\"s\":\"ok\",\"m\":%d,\"arm\":%d,\"warn\":\"%s\"}",
                mode, (int)armed, webRCWarnMsg);
            webRCWarnMsg[0] = '\0'; // clear right after sending
        } else {
            snprintf(resp, sizeof(resp),
                "{\"s\":\"ok\",\"m\":%d,\"arm\":%d}",
                mode, (int)armed);
        }
        webRCServer.send(200, "application/json", resp);
    } else {
        webRCServer.send(400, "application/json", "{\"e\":\"parse failed\"}");
    }
}

// ==================== Battery voltage ====================
// readBatteryVoltage() moved to battery.ino; just call it here

// ==================== Connection state ====================

bool isWebRCEnabled() {
    return webRCUpdated && (millis() - webRCLastUpdate < WEB_RC_TIMEOUT_MS);
}

bool isUsingWebRC() {
    return useWebRC && isWebRCEnabled();
}

// ==================== Setup ====================

void setupWebRC() {
    lastValidThrottle = THROTTLE_MIN;
    lastValidRoll = lastValidPitch = lastValidYaw = 0.0f;

    webRCServer.on("/", HTTP_GET, []() {
        webRCServer.send(200, "text/html", webRCIndexHtml);
    });
    webRCServer.on("/web_rc",           HTTP_POST, handleWebRCRequest);
    webRCServer.on("/web_rc/heartbeat", HTTP_POST, handleWebRCRequest);

    webRCServer.on("/console", HTTP_GET, []() {
        int since = -1;
        int limit = 20;
        if (webRCServer.hasArg("since")) since = webRCServer.arg("since").toInt();
        if (webRCServer.hasArg("limit")) limit = webRCServer.arg("limit").toInt();
        if (limit <= 0) limit = 20;
        if (limit > CONSOLE_LINES) limit = CONSOLE_LINES;

        int availableFrom = max(0, consoleTotal - consoleFilled);
        int sendFrom = (since >= 0) ? since : availableFrom;
        if (sendFrom < availableFrom) sendFrom = availableFrom;
        if (sendFrom > consoleTotal) sendFrom = consoleTotal;
        int sendTo = min(consoleTotal, sendFrom + limit);

        String json = "{\"total\":";
        json += consoleTotal;
        json += ",\"next\":";
        json += sendTo;
        json += ",\"has_more\":";
        json += (sendTo < consoleTotal) ? "true" : "false";
        json += ",\"lines\":[";

        bool first = true;
        for (int i = sendFrom; i < sendTo; i++) {
            int idx = i % CONSOLE_LINES;
            if (!first) json += ",";
            first = false;
            json += "\"";
            String line = consoleBuf[idx];
            line.replace("\\", "\\\\");  // \ -> \\
            line.replace("\"", "\\\"");  // " -> \"
            line.replace("\n", "\\n");    // fallback: newline -> \n
            line.replace("\r", "\\r");    // fallback: CR      -> \r
            json += line + "\"";
        }
        json += "]}";
        webRCServer.send(200, "application/json", json);
    });

    webRCServer.on("/console/cmd", HTTP_POST, []() {
        String cmd = webRCServer.arg("plain");
        cmd.trim();
        if (cmd.length() == 0) {
            webRCServer.send(400, "application/json", "{\"ok\":0,\"e\":\"empty command\"}");
            return;
        }

        char buf[CONSOLE_LINE_LEN];
        snprintf(buf, sizeof(buf), "> %s", cmd.c_str());
        webLog(buf);

        if (!enqueueConsoleCmd(cmd.c_str())) {
            webLog("! command queue is full");
            webRCServer.send(503, "application/json", "{\"ok\":0,\"e\":\"queue full\"}");
            return;
        }

        webRCServer.send(200, "application/json", "{\"ok\":1,\"queued\":1}");
    });

    webRCServer.on("/console/enable", HTTP_POST, []() {
        webConsoleEnabled = true;
        webRCServer.send(200, "application/json", "{\"ok\":1}");
    });

    webRCServer.on("/console/disable", HTTP_POST, []() {
        webConsoleEnabled = false;
        webRCServer.send(200, "application/json", "{\"ok\":1}");
    });

    webRCServer.on("/web_rc/status", HTTP_GET, []() {
        float vbat = readBatteryVoltage();
        if (isnan(vbat) || vbat < 0.0f) vbat = 0.0f;
        char json[384];
        snprintf(json, sizeof(json),
            "{\"enabled\":%s,\"active\":%s,"
            "\"voltage\":%.2f,"
            "\"throttle\":%.1f,\"roll\":%.1f,\"pitch\":%.1f,\"yaw\":%.1f}",
            isWebRCEnabled() ? "true" : "false",
            isUsingWebRC()   ? "true" : "false",
            vbat,
            webRCThrottle, webRCRoll, webRCPitch, webRCYaw);
        webRCServer.send(200, "application/json", json);
    });

    webRCServer.begin();
    print("✓ Web RC started on port 8080\n");
    print("  Deadzone stick=%.0f%% thr=%.0f%% | Scale stick=%.2f yaw=%.2f\n",
          stickDeadzone * 100.0f, throttleDeadzone * 100.0f,
          webRCStickScale, webRCYawScale);
}

// ==================== Main loop ====================

void readWebRC() {
    webRCServer.handleClient();
    if (isWebRCEnabled()) {
        webRCEnabled = useWebRC = true;
    } else {
        webRCEnabled = useWebRC = false;
    }
}

#else
void setupWebRC() { print("Web RC disabled\n"); }
void readWebRC()  {}
void processConsoleCommandQueue() {}
#endif
