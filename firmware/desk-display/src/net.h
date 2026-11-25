// The same lines as over Bluetooth, read over Wi-Fi instead: from RenderDock's API on the local network
// (GET /v1/device, docs/DEVICES.md). For a display that stands where Bluetooth does not reach.
//
// What it is told (the network's name and password, where the computer is, the token) comes from a paired
// computer over the encrypted Bluetooth link and from nowhere else, and is kept on this device. Nothing is
// sent back over Wi-Fi: this way round the display only shows.
#pragma once
#include <Arduino.h>

// Loads what was kept. Starts no radio by itself.
void netBegin();
// Takes new settings and keeps them. An empty `ssid` forgets everything and switches Wi-Fi off.
// `host` is the computer's name (ending in ".local") or address; `ip` is tried when the name cannot be found.
void netConfigure(const char* ssid, const char* pass, const char* host, const char* ip, uint16_t port, const char* token);
// Where the computer is now, for a device that already has a network: the network stays as it was. Does nothing
// when nothing has been set, or when nothing differs.
void netPlace(const char* host, const char* ip, uint16_t port, const char* token);
bool netConfigured();
// Looks for the networks in range, so that one can be picked on the computer instead of typed. Asked for by a
// paired computer over Bluetooth; the answer comes a few seconds later, as one line for that computer:
// {"ack":"wifi","ok":true,"nets":[{"n":"name","r":-48,"o":false},…]}, strongest first, each name once, twelve
// at most ("o": the network asks for no password). Not while Wi-Fi is in use.
void netScanRequest();
bool netScanResult(String& line);
// Wi-Fi is used only while this is true (the main loop says so once Bluetooth has been away for a while).
void netWanted(bool wanted);
// The next complete line from the stream, if one is waiting.
bool netReadLine(String& line);
// Lines are arriving: the last one came less than half a minute ago.
bool netLive();

enum NetState {
  NET_UNSET,       // nothing has been set
  NET_IDLE,        // set, and not wanted now (Bluetooth is up)
  NET_JOINING,     // looking for the network
  NET_READING,     // on the network and reading the stream
  NET_NO_NETWORK,  // could not join: wrong name or password, or out of range
  NET_REFUSED,     // the computer answered and would not have the token
  NET_NO_COMPUTER  // on the network, and the computer is not answering there
};
NetState netState();
