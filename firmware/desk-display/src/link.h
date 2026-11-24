// The Bluetooth link: the Nordic UART Service, one line of JSON at a time, over an encrypted, bonded connection.
#pragma once
#include <Arduino.h>

void linkBegin();
// Call often from loop(): lets go of a computer that connected and never paired.
void linkTick();

bool linkConnected();
// The connection is encrypted: the computer has typed this device's passkey, now or on an earlier day.
bool linkSecure();
// The six digits to type on the computer while pairing; 0 when not pairing.
uint32_t linkPasskey();
// The name this device advertises: "Claude-" and the last four digits of its address.
const char* linkName();

// Fills `line` with the next complete line the computer sent, without its newline. False if there is none yet.
bool linkReadLine(String& line);
// Sends one line; the newline is added here.
void linkSendLine(const String& line);
// Forgets every computer this device has been paired with.
void linkForgetAll();
