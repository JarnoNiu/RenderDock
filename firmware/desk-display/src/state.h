// What the computer last said, and what this device says back.
#pragma once
#include <Arduino.h>

enum Overall { OV_IDLE, OV_WORKING, OV_WAITING, OV_DONE, OV_ERROR };

// Text is UTF-8, and the computer's limits are in characters: a buffer has room for that many characters of three
// bytes each. What still does not fit is cut between characters, never inside one (see `copy` in state.cpp).
struct Row {
  char name[124];   // a project, a shot, or a task another program reports on
  char tool[76];    // "Claude Code", "Codex", whoever reports on the task, or "" for a render
  char state[10];   // error | waiting | working | done
  int age;          // seconds in that state, -1 if unknown
  int percent;      // progress, -1 if none
};

// One side of what the computer is doing, each with a page of its own: its renders, or its agents' sessions
// together with the tasks other programs report on. What is most urgent on that side, and its list.
struct Side {
  Overall overall;
  char topKind[8];      // "render" | "agent" | "task" | ""
  char topName[124];
  char topTool[76];
  char topWait[124];
  int topPercent;       // -1 if none
  bool topExact;
  int topEta;           // seconds, -1 if none
  int topAge;           // seconds in its state, -1 if not said
  Row rows[6];
  int rowCount;
};

// The computer itself, as it says it is doing. Sent apart from the snapshots, a few times a minute.
struct Mac {
  bool have;
  uint32_t at;          // millis() when this last arrived
  int cpu, cores;       // percent busy; how many cores (0 if not said)
  int gpu;              // percent busy, -1 if the computer cannot read it
  float vram;           // GB in use by the graphics chip, negative if not said
  float memUsed, memTotal;   // GB
  int memPressure;      // the system's own level: 1 normal, 2 warning, 4 critical
  float swap;           // GB of swap in use
  int temp, tempMax;    // °C on the chip, average and hottest sensor; -1 if not said
  int thermal;          // the system's own word: 0 fine, 1 warm, 2 slowed down for heat, 3 critical
  int diskFree;         // GB, -1 if not said
  int onAC;             // 1 on the adapter, 0 on the battery, -1 if not said
  int battery;          // percent, -1 if there is none or it is not said
  bool awake;           // something is keeping it from going to sleep when idle
};

struct State {
  bool have;       // a snapshot has arrived on this connection
  uint32_t at;     // millis() when the last one did

  // The Hardware Buddy protocol's own fields
  int total, running, waiting;
  char msg[32];
  char entries[4][96];
  int entryCount;

  // A request the user may answer here
  bool prompt;
  char promptId[40];
  char promptTool[80];
  char promptHint[484];
  bool promptWhole;     // all of it arrived and was kept. If not, it cannot be allowed here.
  char promptBy[124];   // whose request it is: the session's project, and the agent's name. Empty when the
  char promptAgent[76]; // computer did not say (then the screen names nobody, rather than somebody else)
  int promptLeft;       // seconds left to answer when it arrived, -1 if not said
  uint32_t promptAt;    // millis() when this prompt first arrived
  bool answered;        // an answer for this prompt has been sent
  bool promptLocal;     // it came from the bring-up console, not from a computer: its answer is sent nowhere

  // RenderDock's additions (absent when the other end is the Claude desktop app)
  bool extended;
  Overall overall;
  char topKind[8];      // "render" | "agent" | "task" | ""
  char topName[124];
  char topTool[76];
  char topWait[124];
  int topPercent;       // -1 if none
  bool topExact;
  int topEta;           // seconds, -1 if none
  char jobTitle[124];
  int jobDone, jobTotal;
  int agentsError, agentsWaiting, agentsWorking, agentsDone, agentsIdle;
  Row rows[6];
  int rowCount;

  // The same, taken apart: the renders on one page, the agents and other programs' tasks on another. Filled from
  // what the computer says about each side when it does ("rd" 3), and worked out from the fields above when it
  // does not, so that an older RenderDock still gets both pages.
  Side r, a;
  int rendering, queued;   // how many shots are being rendered, and how many wait their turn
  int queueEta;            // seconds until the top render's whole queue is through, -1 if not said

  // A question another program is asking, to answer here by picking one of its answers. It is not a request for
  // permission: nothing is allowed by answering it.
  bool ask;
  char askId[12];
  char askFrom[76];
  char askText[364];
  char askChoices[4][44];
  int askChoiceCount;
  bool askWhole;        // all of it arrived and was kept. If not, it is answered on the computer.
  int askLeft;          // seconds left to answer when it arrived, -1 if not said
  uint32_t askAt;       // millis() when it first arrived
  int askPicked;        // the answer picked here, -1 while none has been
  bool askLocal;        // it came from the bring-up console: the pick is sent nowhere

  // A notice another program sent, while it is new
  bool note;
  char noteId[12];
  char noteFrom[76];
  char noteTitle[124];
  char noteBody[424];
  char noteLevel[8];    // info | done | error
  uint32_t noteAt;      // millis() when it first arrived
};

extern State g_state;
// Kept apart from g_state: it arrives on lines of its own, and a snapshot does not empty it.
extern Mac g_mac;

#if RD_DEBUG_SERIAL
// Set while a line from the bring-up console is being read, so that a request in it is known to be made up.
extern bool g_protoFromConsole;
#endif

// Reads one line from the computer: updates g_state, or answers a command.
void protoHandle(const String& line);
// Sends the user's answer to the request on screen. Only once per request.
void protoAnswer(bool allow);
// Sends which answer the user picked for the question on screen (counted from 0). Only once per question.
void protoChoose(int index);
// Forgets everything the computer said (on disconnect).
void protoReset();

// The wall clock, once the computer has sent the time. False before that.
bool protoClock(int& hour, int& minute);
// The date by the same clock. `weekday` is 0 for Sunday.
bool protoDate(int& month, int& day, int& weekday);
