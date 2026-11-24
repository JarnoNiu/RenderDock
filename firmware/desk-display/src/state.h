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
