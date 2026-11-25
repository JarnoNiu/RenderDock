#include "net.h"
#include <ArduinoJson.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>

#if RD_DEBUG_SERIAL
// What happens, never what was set: no name, no password, no token, no address.
extern volatile bool g_dumpingFrame;   // hw.cpp: a frame is going out over the console, and nothing may cut into it
#define NET_LOG(...) do { if (!g_dumpingFrame) Serial.printf(__VA_ARGS__); } while (0)
#else
#define NET_LOG(...) do { } while (0)
#endif

static Preferences s_kept;
static String s_ssid, s_pass, s_host, s_ip, s_token;
static uint16_t s_port = 47600;
static volatile bool s_set = false;         // there are settings (the strings themselves are read under the lock)
static volatile bool s_wanted = false;
static volatile bool s_changed = false;     // the settings changed: whatever is open is dropped
static volatile NetState s_state = NET_UNSET;
static volatile uint32_t s_lineAt = 0;
static SemaphoreHandle_t s_lock = nullptr;

// Lines waiting for the main loop. A snapshot is a kilobyte or two; a handful is plenty, and when the loop falls
// behind the oldest go, since each snapshot says everything again.
static const int WAITING = 6;
static String s_lines[WAITING];
static int s_count = 0;

static void push(const String& line) {
  if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(200)) != pdTRUE) return;
  if (s_count == WAITING) {
    for (int i = 1; i < WAITING; i++) s_lines[i - 1] = s_lines[i];
    s_count--;
  }
  s_lines[s_count++] = line;
  s_lineAt = millis() ? millis() : 1;
  xSemaphoreGive(s_lock);
}

bool netReadLine(String& line) {
  if (!s_lock || s_count == 0 || xSemaphoreTake(s_lock, 0) != pdTRUE) return false;
  bool got = s_count > 0;
  if (got) {
    line = s_lines[0];
    for (int i = 1; i < s_count; i++) s_lines[i - 1] = s_lines[i];
    s_lines[--s_count] = "";
  }
  xSemaphoreGive(s_lock);
  return got;
}

bool netConfigured() { return s_set; }
bool netLive() { return s_state == NET_READING && s_lineAt != 0 && millis() - s_lineAt < 30000; }
NetState netState() { return s_state; }
void netWanted(bool wanted) { s_wanted = wanted; }

// Waits, in small steps, for as long as Wi-Fi is still wanted and the settings are the same. False if it was cut short.
static bool pause(uint32_t ms) {
  uint32_t until = millis() + ms;
  while ((int32_t)(until - millis()) > 0) {
    if (!s_wanted || s_changed) return false;
    vTaskDelay(pdMS_TO_TICKS(100));
  }
  return true;
}

static void radioOff() {
  if (WiFi.getMode() != WIFI_OFF) {
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
  }
}

// Where the computer is: by its name on the local network if that can be found, else at the address it gave.
static bool find(const String& host, const String& ip, IPAddress& address) {
  if (host.endsWith(".local")) {
    String name = host.substring(0, host.length() - 6);
    if (MDNS.begin("renderdock-display")) {
      IPAddress found = MDNS.queryHost(name.c_str(), 2500);
      MDNS.end();
      if (found != IPAddress((uint32_t)0)) {
        address = found;
        return true;
      }
    }
  } else if (host.length() && address.fromString(host)) {
    return true;
  }
  return ip.length() && address.fromString(ip);
}

// Looking for the networks in range: asked for from the main loop, done here, answered there.
static volatile bool s_scanAsked = false;
static volatile bool s_scanReady = false;
static String s_scanLine;

static void scan() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  int found = WiFi.scanNetworks(false, false, false, 200);
  NET_LOG("net: looked around, %d networks\n", found);
  JsonDocument doc;
  doc["ack"] = "wifi";
  doc["ok"] = found >= 0;
  JsonArray nets = doc["nets"].to<JsonArray>();
  // They come strongest first. Each name once (a network with several access points is one network here).
  String seen[12];
  int kept = 0;
  for (int i = 0; i < found && kept < 12; i++) {
    String name = WiFi.SSID(i);
    if (!name.length()) continue;
    bool twice = false;
    for (int k = 0; k < kept; k++) twice = twice || seen[k] == name;
    if (twice) continue;
    seen[kept++] = name;
    JsonObject net = nets.add<JsonObject>();
    net["n"] = name;
    net["r"] = WiFi.RSSI(i);
    net["o"] = WiFi.encryptionType(i) == WIFI_AUTH_OPEN;
  }
  WiFi.scanDelete();
  String line;
  serializeJson(doc, line);
  if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(1000)) == pdTRUE) {
    s_scanLine = line;
    s_scanReady = true;
    xSemaphoreGive(s_lock);
  }
}

void netScanRequest() { s_scanAsked = true; }

bool netScanResult(String& line) {
  if (!s_scanReady || !s_lock || xSemaphoreTake(s_lock, 0) != pdTRUE) return false;
  line = s_scanLine;
  s_scanLine = "";
  s_scanReady = false;
  xSemaphoreGive(s_lock);
  return true;
}

static void run(void*) {
  for (;;) {
    s_changed = false;
    if (!s_wanted || !netConfigured()) {
      if (s_scanAsked) {
        s_scanAsked = false;
        scan();
      }
      radioOff();
      s_state = netConfigured() ? NET_IDLE : NET_UNSET;
      vTaskDelay(pdMS_TO_TICKS(300));
      continue;
    }
    // The settings as they are now, so that a change half-way through cannot mix two sets. (They are changed
    // from the main loop, hence the lock.)
    if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(1000)) != pdTRUE) continue;
    String ssid = s_ssid, pass = s_pass, token = s_token, host = s_host, ip = s_ip;
    uint16_t port = s_port;
    xSemaphoreGive(s_lock);

    s_state = NET_JOINING;
    NET_LOG("net: joining\n");
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(false);
    WiFi.begin(ssid.c_str(), pass.c_str());
    uint32_t started = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - started < 20000 && s_wanted && !s_changed) vTaskDelay(pdMS_TO_TICKS(150));
    if (WiFi.status() != WL_CONNECTED) {
      if (s_wanted && !s_changed) {
        s_state = NET_NO_NETWORK;
        NET_LOG("net: could not join\n");
      }
      radioOff();
      pause(45000);
      continue;
    }
    NET_LOG("net: joined\n");

    // As long as the network holds: find the computer, read its stream, and when the stream ends look again.
    uint32_t wait = 3000;
    while (s_wanted && !s_changed && WiFi.status() == WL_CONNECTED) {
      IPAddress address;
      WiFiClient client;
      if (!find(host, ip, address) || !client.connect(address, port, 4000)) {
        s_state = NET_NO_COMPUTER;
        NET_LOG("net: the computer is not answering\n");
        if (!pause(wait)) break;
        wait = min<uint32_t>(wait * 2, 60000);
        continue;
      }
      client.setTimeout(6000);
      client.printf("GET /v1/device HTTP/1.1\r\nHost: %s:%u\r\nAuthorization: Bearer %s\r\nAccept: text/event-stream\r\n\r\n", host.c_str(), (unsigned)port, token.c_str());
      String status = client.readStringUntil('\n');
      if (!status.startsWith("HTTP/1.1 200")) {
        bool refused = status.indexOf(" 401") > 0;
        s_state = refused ? NET_REFUSED : NET_NO_COMPUTER;
        NET_LOG("net: %s\n", refused ? "the token was refused" : "an answer that is not the stream");
        client.stop();
        // A refused token will be refused again: ask seldom. (It is put right from the computer, over Bluetooth.)
        if (!pause(refused ? 120000 : wait)) break;
        wait = min<uint32_t>(wait * 2, 60000);
        continue;
      }
      while (client.connected()) {
        String header = client.readStringUntil('\n');
        if (header.length() <= 1) break;
      }
      s_state = NET_READING;
      wait = 3000;
      NET_LOG("net: reading the stream\n");
      String partial;
      uint32_t heardAt = millis();
      while (s_wanted && !s_changed && client.connected() && WiFi.status() == WL_CONNECTED) {
        int waiting = client.available();
        if (waiting <= 0) {
          // The computer says everything again every ten seconds. Half a minute of nothing is a dead link.
          if (millis() - heardAt > 35000) break;
          vTaskDelay(pdMS_TO_TICKS(25));
          continue;
        }
        heardAt = millis();
        while (waiting-- > 0) {
          int c = client.read();
          if (c < 0) break;
          if (c == '\n') {
            if (partial.startsWith("data: ")) {
              NET_LOG("net: line in, %u bytes\n", (unsigned)partial.length() - 6);
              push(partial.substring(6));
            }
            partial = "";
          } else if (c != '\r' && partial.length() < 6200) {
            partial += (char)c;
          }
        }
      }
      client.stop();
      NET_LOG("net: the stream ended\n");
      if (s_wanted && !s_changed) s_state = NET_NO_COMPUTER;
      if (!pause(wait)) break;
    }
    radioOff();
  }
}

void netBegin() {
  s_lock = xSemaphoreCreateMutex();
  s_kept.begin("net", false);
  s_ssid = s_kept.getString("ssid", "");
  s_pass = s_kept.getString("pass", "");
  s_host = s_kept.getString("host", "");
  s_ip = s_kept.getString("ip", "");
  s_token = s_kept.getString("token", "");
  s_port = s_kept.getUShort("port", 47600);
  s_set = s_ssid.length() > 0;
  s_state = netConfigured() ? NET_IDLE : NET_UNSET;
  // Its own task: joining a network and waiting for a computer take seconds, and the screen and the touch must
  // not wait with them.
  xTaskCreatePinnedToCore(run, "net", 8192, nullptr, 1, nullptr, 0);
}

void netConfigure(const char* ssid, const char* pass, const char* host, const char* ip, uint16_t port, const char* token) {
  bool forget = !ssid || !*ssid;
  xSemaphoreTake(s_lock, portMAX_DELAY);
  s_ssid = forget ? "" : ssid;
  s_pass = forget ? "" : (pass ? pass : "");
  s_host = forget ? "" : (host ? host : "");
  s_ip = forget ? "" : (ip ? ip : "");
  s_token = forget ? "" : (token ? token : "");
  s_port = forget || port == 0 ? 47600 : port;
  s_set = !forget;
  xSemaphoreGive(s_lock);
  if (forget) {
    s_kept.clear();
  } else {
    s_kept.putString("ssid", s_ssid);
    s_kept.putString("pass", s_pass);
    s_kept.putString("host", s_host);
    s_kept.putString("ip", s_ip);
    s_kept.putString("token", s_token);
    s_kept.putUShort("port", s_port);
  }
  s_changed = true;
  NET_LOG("net: settings %s\n", forget ? "forgotten" : "taken");
}

void netPlace(const char* host, const char* ip, uint16_t port, const char* token) {
  if (!s_set || !host || !token) return;
  if (port == 0) port = 47600;
  xSemaphoreTake(s_lock, portMAX_DELAY);
  bool same = s_host == host && s_ip == (ip ? ip : "") && s_port == port && s_token == token;
  if (!same) {
    s_host = host;
    s_ip = ip ? ip : "";
    s_port = port;
    s_token = token;
  }
  xSemaphoreGive(s_lock);
  if (same) return;
  s_kept.putString("host", s_host);
  s_kept.putString("ip", s_ip);
  s_kept.putString("token", s_token);
  s_kept.putUShort("port", s_port);
  s_changed = true;
  NET_LOG("net: the computer's place taken\n");
}
