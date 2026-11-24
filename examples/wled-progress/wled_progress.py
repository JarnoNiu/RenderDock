#!/usr/bin/env python3
"""An LED strip as a progress bar for RenderDock.

Reads RenderDock's local API on this computer and fills a WLED strip to match: so far along the shot in
front, so much of the strip lit. Amber when something is waiting for you, red when something failed, all
lit for a while when the queue is done, and handed back to WLED when nothing is going on.

    python3 wled_progress.py 192.168.1.50              run until stopped (Ctrl-C hands the strip back)
    python3 wled_progress.py 192.168.1.50 --once       set the strip once and exit
    python3 wled_progress.py --self-test               try it against stand-ins for both ends; needs nothing

Needs RenderDock's local API switched on (menu-bar icon -> Local API), and a strip running WLED on your
network. Python 3.8 or later, nothing to install. This script is the only thing here that talks to the
network: RenderDock itself still does not.
"""
import argparse
import json
import os
import signal
import sys
import threading
import time
import urllib.request

MINT, AQUA, AMBER, CORAL, OFF = '4FEDB0', '42C2FF', 'FFBD45', 'FF6E69', '000000'
DISCOVERY = os.path.expanduser('~/Library/Application Support/RenderDock/api.json')


def get_json(url, timeout=3):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode('utf-8'))


def post_json(url, body, timeout=3):
    request = urllib.request.Request(url, data=json.dumps(body).encode('utf-8'), headers={'Content-Type': 'application/json'}, method='POST')
    with urllib.request.urlopen(request, timeout=timeout) as response:
        response.read()


def api_url(given):
    """Where RenderDock's API is: the address given, or the one the running app wrote down."""
    if given:
        return given.rstrip('/')
    try:
        with open(DISCOVERY, encoding='utf-8') as f:
            return json.load(f)['url'].rstrip('/')
    except (OSError, ValueError, KeyError):
        return None


def frame(summary, count):
    """What the strip should show for a state: None to hand it back to WLED, else the `i` list for its segment.

    The list is WLED's range form: start, stop (not included), colour.
    """
    state = summary.get('state', 'idle')
    if state == 'error':
        return [0, count, CORAL]
    if state == 'waiting':
        return [0, count, AMBER]
    if state == 'done':
        return [0, count, MINT]
    if state != 'working':
        return None
    focus = summary.get('focus') or {}
    fraction = focus.get('fraction')
    if fraction is None:
        fraction = (summary.get('top') or {}).get('fraction')
    if fraction is None:
        return [0, count, AQUA]            # something is going on, and it does not say how far along it is
    lit = max(0, min(count, round(count * float(fraction))))
    if lit == 0:
        return [0, count, OFF]
    if lit == count:
        return [0, count, MINT]
    return [0, lit, MINT, lit, count, OFF]


class Strip:
    """One WLED strip. Sends only what changed, and remembers whether it has taken the strip over."""

    def __init__(self, host):
        self.base = host if host.startswith('http') else 'http://' + host
        self.count = None
        self.shown = 'unknown'
        self.taken = False

    def leds(self):
        if self.count is None:
            self.count = int(get_json(self.base + '/json/info')['leds']['count'])
        return self.count

    def show(self, summary):
        wanted = frame(summary, self.leds())
        if wanted == self.shown:
            return False
        if wanted is None:
            self.release()
        else:
            if not self.taken:
                # Switched on first, in a request of its own: WLED does not take both in one.
                post_json(self.base + '/json/state', {'on': True})
                self.taken = True
            post_json(self.base + '/json/state', {'seg': {'i': wanted}})
        self.shown = wanted
        return True

    def release(self):
        """Hands the strip back: the effect it was running carries on."""
        if self.taken:
            post_json(self.base + '/json/state', {'seg': {'frz': False}})
            self.taken = False


def run(strip, api, interval, once):
    stopping = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopping.set())
    told = None
    while not stopping.is_set():
        try:
            strip.show(get_json(api + '/v1/state').get('summary', {}))
            problem = None
        except Exception as error:   # the app is not running, the strip is off: say so once, and keep trying
            problem = str(error)
        if problem != told:
            if problem:
                print('wled_progress: ' + problem, file=sys.stderr)
            told = problem
        if once:
            return 1 if problem else 0
        stopping.wait(interval)
    try:
        strip.release()
    except Exception:
        pass
    return 0


def self_test():
    """Both ends replaced by stand-ins on this computer: checks what would be sent to a strip, in order."""
    from http.server import BaseHTTPRequestHandler, HTTPServer

    states = [{'state': 'working', 'focus': {'fraction': 0.5}}, {'state': 'working', 'focus': {'fraction': 0.5}},
              {'state': 'working', 'focus': {'fraction': 1.0}}, {'state': 'working', 'focus': {}, 'top': {'kind': 'agent'}},
              {'state': 'waiting'}, {'state': 'error'}, {'state': 'done'}, {'state': 'idle'}, {'state': 'working', 'focus': {'fraction': 0.02}}]
    sent, served = [], {'n': 0}

    class Handler(BaseHTTPRequestHandler):
        def answer(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == '/json/info':
                self.answer({'name': 'stand-in', 'leds': {'count': 30}})
            elif self.path == '/v1/state':
                self.answer({'summary': states[min(served['n'], len(states) - 1)]})
                served['n'] += 1
            else:
                self.send_error(404)

        def do_POST(self):
            sent.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.answer({'success': True})

        def log_message(self, *args):
            pass

    server = HTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    here = 'http://127.0.0.1:%d' % server.server_port
    strip = Strip(here)
    for _ in states:
        strip.show(get_json(here + '/v1/state')['summary'])
    strip.release()
    server.shutdown()
    expected = [
        {'on': True},
        {'seg': {'i': [0, 15, MINT, 15, 30, OFF]}},      # half way; the same state again sends nothing
        {'seg': {'i': [0, 30, MINT]}},                   # all the way
        {'seg': {'i': [0, 30, AQUA]}},                   # working, no percentage
        {'seg': {'i': [0, 30, AMBER]}},                  # waiting for you
        {'seg': {'i': [0, 30, CORAL]}},                  # failed
        {'seg': {'i': [0, 30, MINT]}},                   # done
        {'seg': {'frz': False}},                         # idle: handed back
        {'on': True},                                    # taken over again
        {'seg': {'i': [0, 1, MINT, 1, 30, OFF]}},        # 2% of 30 is one light
        {'seg': {'frz': False}},                         # stopped: handed back
    ]
    if sent != expected:
        print('self-test FAILED. Sent:', *sent, sep='\n  ')
        return 1
    print('self-test passed: %d requests, as expected' % len(sent))
    return 0


def main():
    parser = argparse.ArgumentParser(description='An LED strip (WLED) as a progress bar for RenderDock.')
    parser.add_argument('host', nargs='?', help="the strip's address, e.g. 192.168.1.50")
    parser.add_argument('--api', help="RenderDock's local API, if not the one the running app announces")
    parser.add_argument('--interval', type=float, default=2.0, help='seconds between looks (default 2)')
    parser.add_argument('--once', action='store_true', help='set the strip once and exit')
    parser.add_argument('--self-test', action='store_true', help='try it against stand-ins; needs no strip and no app')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.host:
        parser.error("give the strip's address, or --self-test")
    api = api_url(args.api)
    if not api:
        print("wled_progress: RenderDock's local API is not on. Switch it on: menu-bar icon -> Local API.", file=sys.stderr)
        return 3
    return run(Strip(args.host), api, max(0.5, args.interval), args.once)


if __name__ == '__main__':
    sys.exit(main())
