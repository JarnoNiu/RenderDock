// The Bluetooth side of the Hardware Buddy protocol (github.com/anthropics/claude-desktop-buddy, REFERENCE.md):
// advertise the Nordic UART Service under a name that starts with "Claude", and require LE Secure Connections
// bonding with a passkey shown on this device, as that document recommends.
//
// Two layers keep an unpaired computer out. The characteristics are marked as needing an authenticated link,
// which the Bluetooth stack enforces. And this file itself neither accepts a byte nor sends one until the
// link has been reported encrypted and authenticated.
#include "link.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLESecurity.h>
#include <esp_mac.h>
#include <host/ble_gap.h>
#include <host/ble_store.h>

#define NUS_SERVICE "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define NUS_RX "6e400002-b5a3-f393-e0a9-e50e24dcca9e"   // computer -> device
#define NUS_TX "6e400003-b5a3-f393-e0a9-e50e24dcca9e"   // device -> computer

// A line longer than this is not a message this firmware knows; it is thrown away.
static const size_t MAX_LINE = 6144;
static const size_t RING = 8192;

static uint8_t s_ring[RING];
static volatile size_t s_head = 0, s_tail = 0;
static String s_partial;
static bool s_overflow = false;
static volatile bool s_cut = false;   // a piece was dropped; its mark is in the ring

static BLEServer* s_server = nullptr;
static BLECharacteristic* s_tx = nullptr;
static volatile bool s_connected = false;
static volatile bool s_secure = false;
static volatile uint32_t s_passkey = 0;
static volatile uint16_t s_mtu = 23;
static volatile uint16_t s_connection = 0;
static volatile uint32_t s_connectedAt = 0;
static char s_name[16] = "Claude";

// A computer that connects and then never pairs is let go after this long, so that it cannot hold the one
// connection this device has. (While six digits are on the screen the pairing has its own time limit.)
static const uint32_t UNPAIRED_MS = 120000;

// The bring-up build says on the USB port what happens on the link. Never the six digits, and never what a
// line says: only that there was one, and how long it was.
#if RD_DEBUG_SERIAL
#define LINK_LOG(...) Serial.printf(__VA_ARGS__)
#else
#define LINK_LOG(...) do { } while (0)
#endif

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    if (!s_secure) return;   // nothing is taken from a link that is not encrypted
    String value = c->getValue();
    const uint8_t* p = (const uint8_t*)value.c_str();
    // The reader has fallen behind and this piece does not fit: none of it is kept, and a mark goes in instead
    // (a zero byte, which no line of JSON contains), so that the line it belonged to is thrown away whole
    // rather than read with a hole in it. One place is always left free for that mark.
    size_t used = (s_head + RING - s_tail) % RING;
    if (used + value.length() + 2 > RING) {
      if (!s_cut && (s_head + 1) % RING != s_tail) {
        s_ring[s_head] = 0;
        s_head = (s_head + 1) % RING;
      }
      s_cut = true;
      return;
    }
    s_cut = false;
    for (size_t i = 0; i < value.length(); i++) {
      s_ring[s_head] = p[i];
      s_head = (s_head + 1) % RING;
    }
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*, ble_gap_conn_desc* desc) override {
    s_connection = desc->conn_handle;
    s_connectedAt = millis();
    s_connected = true;
    LINK_LOG("link: a computer connected\n");
  }
  void onDisconnect(BLEServer*, ble_gap_conn_desc*) override {
    s_connected = false;
    s_secure = false;
    s_passkey = 0;
    s_mtu = 23;
    LINK_LOG("link: disconnected\n");
  }
  void onMtuChanged(BLEServer*, ble_gap_conn_desc*, uint16_t mtu) override {
    s_mtu = mtu;
    LINK_LOG("link: packet size %u\n", (unsigned)mtu);
  }
};

// This device shows six digits; the computer's user types them. Nothing else is accepted.
class SecurityCallbacks : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override { return 0; }
  bool onConfirmPIN(uint32_t) override { return false; }
  bool onSecurityRequest() override { return true; }
  void onPassKeyNotify(uint32_t passkey) override {
    s_passkey = passkey;
    LINK_LOG("link: pairing, six digits are on the screen\n");
  }
  // Called when pairing ends either way, and again each time a bonded computer reconnects and the link is encrypted.
  void onAuthenticationComplete(ble_gap_conn_desc* desc, int status) override {
    s_passkey = 0;
    s_secure = status == 0 && desc != nullptr && desc->sec_state.encrypted && desc->sec_state.authenticated;
    LINK_LOG("link: pairing ended, status %d, encrypted %d, authenticated %d, bonded %d\n", status,
             desc ? (int)desc->sec_state.encrypted : -1, desc ? (int)desc->sec_state.authenticated : -1,
             desc ? (int)desc->sec_state.bonded : -1);
    if (!s_secure && s_server) s_server->disconnect(desc ? desc->conn_handle : (uint16_t)s_connection);
  }
  void onAuthenticationComplete(ble_gap_conn_desc* desc) override { onAuthenticationComplete(desc, 0); }
};

void linkBegin() {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  snprintf(s_name, sizeof(s_name), "Claude-%02X%02X", mac[4], mac[5]);

  BLEDevice::init(s_name);
  BLEDevice::setMTU(517);

  BLESecurity* security = new BLESecurity();
  security->setPassKey(false);                        // a random passkey…
  security->regenPassKeyOnConnect(true);              // …and a new one for every pairing
  security->setCapability(ESP_IO_CAP_OUT);            // this device displays it, the computer types it
  security->setAuthenticationMode(true, true, true);  // bond, protect against a man in the middle, LE Secure Connections
  BLEDevice::setSecurityCallbacks(new SecurityCallbacks());

  s_server = BLEDevice::createServer();
  s_server->setCallbacks(new ServerCallbacks());
  s_server->advertiseOnDisconnect(true);
  BLEService* service = s_server->createService(NUS_SERVICE);

  s_tx = service->createCharacteristic(
    NUS_TX, BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_READ_AUTHEN);
  BLECharacteristic* rx = service->createCharacteristic(
    NUS_RX, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR | BLECharacteristic::PROPERTY_WRITE_AUTHEN);
  rx->setCallbacks(new RxCallbacks());
  service->start();

  // The advertisement proper has room for the service and eight more characters. A computer filters on the
  // service and on a name that starts with "Claude", and not every scan waits for the second packet, so the
  // short name goes in the first packet and the whole name in the scan response.
  BLEAdvertisementData packet;
  packet.setFlags(0x06);   // general discovery, Bluetooth LE only
  packet.setCompleteServices(BLEUUID(NUS_SERVICE));
  packet.setShortName("Claude");
  BLEAdvertisementData response;
  response.setName(s_name);
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->setAdvertisementData(packet);
  advertising->setScanResponseData(response);
  BLEDevice::startAdvertising();
}

void linkTick() {
  if (s_connected && !s_secure && s_passkey == 0 && s_server && millis() - s_connectedAt > UNPAIRED_MS) {
    LINK_LOG("link: never paired, letting it go\n");
    s_connectedAt = millis();   // not again on the next pass, while the disconnect is on its way
    s_server->disconnect((uint16_t)s_connection);
  }
}

bool linkConnected() { return s_connected; }
bool linkSecure() { return s_connected && s_secure; }
uint32_t linkPasskey() { return s_passkey; }
const char* linkName() { return s_name; }

bool linkReadLine(String& line) {
  while (s_tail != s_head) {
    char c = (char)s_ring[s_tail];
    s_tail = (s_tail + 1) % RING;
    if (c == 0) {
      // Part of this line never arrived: skip to its end.
      s_partial = "";
      s_overflow = true;
      continue;
    }
    if (c == '\n') {
      bool usable = !s_overflow && s_partial.length() > 0;
      if (usable) line = s_partial;
      if (usable || s_overflow) LINK_LOG("link: line in, %u bytes%s\n", (unsigned)s_partial.length(), s_overflow ? ", too long, dropped" : "");
      s_partial = "";
      s_overflow = false;
      if (usable) return true;
      continue;
    }
    if (s_overflow) continue;
    if (s_partial.length() >= MAX_LINE) {
      s_partial = "";
      s_overflow = true;   // skip to the end of this over-long line
      continue;
    }
    s_partial += c;
  }
  return false;
}

void linkSendLine(const String& line) {
  if (!s_connected || !s_secure || !s_tx) return;   // nothing is sent over a link that is not encrypted
  String out = line + "\n";
  LINK_LOG("link: line out, %u bytes\n", (unsigned)line.length());
  size_t chunk = s_mtu > 3 ? (size_t)s_mtu - 3 : 20;
  if (chunk > 180) chunk = 180;
  for (size_t sent = 0; sent < out.length();) {
    size_t n = min(chunk, (size_t)out.length() - sent);
    s_tx->setValue((const uint8_t*)(out.c_str() + sent), n);
    s_tx->notify();
    sent += n;
    delay(4);   // let the stack flush before the next piece
  }
}

void linkForgetAll() {
  ble_store_clear();
}
