// The sounds: a few notes each, worked out here as they are played. There are no sound files.
#pragma once
#include <Arduino.h>

enum Sound {
  SOUND_REQUEST,   // a request to answer: two notes going up
  SOUND_WAITING,   // a session needs the user, somewhere else: one soft note
  SOUND_DONE,      // something long has finished: three notes going up
  SOUND_FAILED,    // something failed: two notes going down
  SOUND_TAP,       // an answer was given with a finger: a small tick
  SOUND_COUNT
};

// Starts the playback chip and the amplifier's switch. False if the chip does not answer; then nothing sounds.
bool soundBegin();
// Plays one. Returns at once: a task of its own does the playing, and a sound asked for while another plays
// follows it. Whether a sound should be made at all (muted, do not disturb, night) is the caller's business.
void soundPlay(Sound sound);
// How loud, 0…100; 70 to begin with. This sits on a desk next to someone: enough to notice, no more.
void soundVolume(int percent);
int soundVolumeNow();

#if RD_DEBUG_SERIAL
// Bring-up only: plays a steady tone and listens to it through the board's microphone chip, all four of its
// inputs, and prints how much of the tone each one heard. The third input is wired to the playback chip's own
// output (the schematic's echo-reference loop), so it hears the tone whether or not a speaker is connected; the
// first two are the microphones, which hear it only if one is.
void soundSelfTest();
// Plays one of the sounds as it is normally played while a microphone listens, and prints what it heard.
void soundHear(int which);
#endif
