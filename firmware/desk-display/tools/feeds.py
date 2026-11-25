"""Writes made-up snapshots, one per file, for checking the desk display's screens over USB.

  feeds.py OUT_DIR        then, for one of them:  console.py PORT wait:4 sendfile:OUT_DIR/working.json wait:2 shot:working.png
"""
import json
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def save(name, doc):
    with open(os.path.join(out, name + '.json'), 'w', encoding='utf-8') as f:
        f.write(json.dumps(doc, ensure_ascii=False, separators=(',', ':')))


def base(total, running, waiting, msg, **more):
    doc = {'total': total, 'running': running, 'waiting': waiting, 'msg': msg, 'entries': [], 'tokens': 0, 'tokens_today': 0}
    doc.update(more)
    return doc


agents = {'error': 0, 'waiting': 0, 'working': 2, 'done': 1, 'idle': 3}
rows = [
    {'n': 's040_explode', 't': '', 's': 'working', 'p': 62},
    {'n': 'billing-api', 't': 'Codex', 's': 'working', 'a': 913},
    {'n': 'docs', 't': 'Claude Code', 's': 'done', 'a': 120},
]

save('working', base(5, 3, 0, 'render 62% | 2 working', rd={
    'state': 'working', 'top': {'kind': 'render', 'name': 's040_explode', 'pct': 62, 'exact': True, 'eta': 1500},
    'job': {'title': '产品片', 'done': 3, 'total': 8}, 'agents': agents, 'rows': rows}))

save('working100', base(1, 1, 0, 'render 100%', rd={
    'state': 'working', 'top': {'kind': 'render', 'name': 's070_packshot_final_long_name_v12', 'pct': 100, 'exact': False, 'eta': 40},
    'job': {'title': '产品片', 'done': 7, 'total': 8}, 'agents': {'error': 0, 'waiting': 0, 'working': 0, 'done': 0, 'idle': 0}, 'rows': rows[:1]}))

save('working7', base(1, 1, 0, 'render 7%', rd={
    'state': 'working', 'top': {'kind': 'render', 'name': 's010_open', 'pct': 7, 'exact': True, 'eta': 5400},
    'agents': {'error': 0, 'waiting': 0, 'working': 1, 'done': 0, 'idle': 0}, 'rows': rows[:2]}))

save('agents', base(5, 2, 0, '2 working', rd={
    'state': 'working', 'top': {'kind': 'agent', 'name': 'billing-api', 'tool': 'Codex'},
    'agents': agents, 'rows': rows[1:]}))

save('waiting', base(5, 2, 1, 'docs waiting', rd={
    'state': 'waiting', 'top': {'kind': 'agent', 'name': 'docs', 'tool': 'Claude Code', 'wait': 'permission'},
    'agents': {'error': 0, 'waiting': 1, 'working': 2, 'done': 0, 'idle': 2},
    'rows': [{'n': 'docs', 't': 'Claude Code', 's': 'waiting', 'a': 42}] + rows[:2] + [
        {'n': 'landing-page', 't': 'Claude Code', 's': 'working', 'a': 15},
        {'n': 'data-import', 't': 'Hermes', 's': 'working', 'a': 300}]}))

save('request', base(5, 2, 1, 'approve: Read', prompt={'id': 'req_demo_0001', 'tool': 'Read', 'hint': 'src/config/settings.json'}, rd={
    'state': 'waiting', 'top': {'kind': 'agent', 'name': 'docs', 'tool': 'Claude Code', 'wait': 'permission'},
    'agents': {'error': 0, 'waiting': 1, 'working': 2, 'done': 0, 'idle': 2}, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))

save('request2', base(5, 2, 1, 'approve: Grep', prompt={'id': 'req_demo_0002', 'tool': 'Grep', 'hint': '在 src/ 里查找 “渲染进度” 出现的位置，共 3 个文件夹'}, rd={
    'state': 'waiting', 'top': {'kind': 'agent', 'name': 'docs', 'tool': 'Claude Code', 'wait': 'permission'},
    'agents': {'error': 0, 'waiting': 1, 'working': 2, 'done': 0, 'idle': 2}, 'rows': rows, 'left': 60, 'by': {'n': 'docs', 't': 'Claude Code'}}))

save('request-long', base(5, 2, 1, 'approve: Read', prompt={'id': 'req_demo_0003', 'tool': 'Read', 'hint': 'packages/very/deep/folder/structure/that/keeps/going/and/going/until/it/no/longer/fits/on/a/small/round/screen/file.json'}, rd={
    'state': 'waiting', 'top': {'kind': 'agent', 'name': 'docs', 'tool': 'Claude Code', 'wait': 'permission'},
    'agents': {'error': 0, 'waiting': 1, 'working': 2, 'done': 0, 'idle': 2}, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))

# Requests that must not be allowable on the device, and one whose asker is not the most urgent thing going on.
waiting_agents = {'error': 1, 'waiting': 1, 'working': 1, 'done': 0, 'idle': 2}
save('request-other-top', base(5, 1, 2, 'approve: Read', prompt={'id': 'req_demo_0010', 'tool': 'Read', 'hint': 'docs/install.md'}, rd={
    'state': 'error', 'top': {'kind': 'agent', 'name': 'billing-api', 'tool': 'Codex'},
    'agents': waiting_agents, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))
save('request-noby', base(5, 1, 2, 'approve: Read', prompt={'id': 'req_demo_0011', 'tool': 'Read', 'hint': 'docs/install.md'}, rd={
    'state': 'error', 'top': {'kind': 'agent', 'name': 'billing-api', 'tool': 'Codex'}, 'agents': waiting_agents, 'rows': rows, 'left': 80}))
save('request-dots', base(5, 1, 1, 'approve: Grep', prompt={'id': 'req_demo_0012', 'tool': 'Grep', 'hint': 'password|secret' + '。' * 40}, rd={
    'state': 'waiting', 'agents': waiting_agents, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))
save('request-nul', base(5, 1, 1, 'approve: Read', prompt={'id': 'req_demo_0013', 'tool': 'Read', 'hint': 'README.md\u0000 and what follows'}, rd={
    'state': 'waiting', 'agents': waiting_agents, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))
save('request-tool', base(5, 1, 1, 'approve: Read', prompt={'id': 'req_demo_0014', 'tool': 'ReadTheWholeOfIt' * 3, 'hint': 'docs/install.md'}, rd={
    'state': 'waiting', 'agents': waiting_agents, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))
save('request-fresh', base(5, 1, 1, 'approve: Read', prompt={'id': 'req_demo_0015', 'tool': 'Read', 'hint': 'docs/usage.md'}, rd={
    'state': 'waiting', 'agents': waiting_agents, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))
save('request-fresh2', base(5, 1, 1, 'approve: Read', prompt={'id': 'req_demo_0016', 'tool': 'Read', 'hint': 'docs/faq.md'}, rd={
    'state': 'waiting', 'agents': waiting_agents, 'rows': rows, 'left': 80, 'by': {'n': 'docs', 't': 'Claude Code'}}))

save('done', base(3, 0, 0, 'render done', rd={
    'state': 'done', 'top': {'kind': 'render', 'name': 's040_explode'},
    'agents': {'error': 0, 'waiting': 0, 'working': 0, 'done': 2, 'idle': 1}, 'rows': []}))

save('done-agent', base(3, 0, 0, 'docs done', rd={
    'state': 'done', 'top': {'kind': 'agent', 'name': 'docs', 'tool': 'Claude Code'},
    'agents': {'error': 0, 'waiting': 0, 'working': 1, 'done': 1, 'idle': 1}, 'rows': []}))

save('error', base(3, 0, 0, 'render failed', rd={
    'state': 'error', 'top': {'kind': 'render', 'name': 's050_turntable'},
    'agents': {'error': 0, 'waiting': 0, 'working': 0, 'done': 0, 'idle': 3}, 'rows': []}))

save('idle', base(3, 0, 0, 'idle', rd={
    'state': 'idle', 'agents': {'error': 0, 'waiting': 0, 'working': 0, 'done': 0, 'idle': 3}, 'rows': []}))

# From other programs, through RenderDock's entry (renderdock notify | progress | ask): questions, notices, tasks.
none = {'error': 0, 'waiting': 0, 'working': 0, 'done': 0, 'idle': 2}


def idle_with(**more):
    rd = {'state': 'idle', 'agents': none, 'rows': []}
    rd.update(more)
    return base(2, 0, 1 if 'ask' in more else 0, 'a question is waiting' if 'ask' in more else 'idle', rd=rd)


save('ask2', idle_with(ask={'id': 'qaaaa', 'from': 'Codex · billing-api', 'text': '测试全过了，现在提交吗？', 'choices': ['提交', '先不提交'], 'left': 110}))
save('ask3', idle_with(ask={'id': 'qbbbb', 'from': 'Codex · billing-api', 'text': '发票导出做好了。要我顺手把旧的导出接口也删掉吗？',
                            'choices': ['删掉', '先留着', '我来看看'], 'left': 114}))
save('ask4', idle_with(ask={'id': 'qcccc', 'from': '部署脚本', 'text': '预览环境和正式环境的配置不一样：正式环境少了两个开关。这次发布按哪一边的来？',
                            'choices': ['按预览', '按正式', '两边都留', '先停下'], 'left': 300}))
save('ask4-stacked', idle_with(ask={'id': 'qdddd', 'from': 'backup', 'text': 'Disk is 92% full. What now?',
                                    'choices': ['Delete old ones', 'Skip tonight', 'Use the other disk', 'Stop'], 'left': 60}))
save('ask-long', idle_with(ask={'id': 'qeeee', 'from': '部署脚本', 'text': '预览环境和正式环境的配置不一样：正式环境少了两个开关，预览环境多了一个只在测试时用的地址。这次发布按哪一边的来，还是我先停下等你看？',
                                'choices': ['按预览环境的配置来', '按正式环境的配置来', '两边的开关都保留', '先停下等我看'], 'left': 300}))
save('ask-latin', idle_with(ask={'id': 'qffff', 'from': 'planner', 'text': 'Which branch should the fix go on?', 'choices': ['main', 'release'], 'left': 45}))
save('ask-blank', idle_with(ask={'id': 'qgggg', 'from': 'planner', 'text': 'Pick one', 'choices': ['Yes', ''], 'left': 60}))
save('ask-gone', idle_with())

save('note-done', idle_with(note={'id': 'naaaa', 'from': '部署脚本', 'title': '预览环境已更新', 'body': '3 个页面有改动，用时 48 秒。', 'level': 'done'}))
save('note-error', idle_with(note={'id': 'nbbbb', 'from': '夜间备份', 'title': '', 'body': '外接硬盘没插上，这次跳过了。', 'level': 'error'}))
save('note-info', idle_with(note={'id': 'ncccc', 'from': 'crawler', 'title': 'Weekly numbers are in and the report has been rebuilt from scratch', 'level': 'info',
                                  'body': 'Plays are up by a fifth on last week, saves are flat, and two of the five new episodes account for most of it. The full table is in the usual folder, with the per-episode curves next to it.'}))

task_rows = [{'n': '导入商品目录', 't': '导入脚本', 's': 'working', 'a': 130, 'p': 48}]
save('task', base(1, 1, 0, 'idle', rd={'state': 'working', 'top': {'kind': 'task', 'name': '导入商品目录', 'tool': '导入脚本', 'pct': 48, 'exact': True, 'eta': 140},
                                      'agents': none, 'rows': task_rows}))
save('task-nopct', base(1, 1, 0, 'idle', rd={'state': 'working', 'top': {'kind': 'task', 'name': 'Rebuild the search index', 'tool': 'indexer'},
                                            'agents': none, 'rows': [{'n': 'Rebuild the search index', 't': 'indexer', 's': 'working', 'a': 75}]}))
save('task-done', base(1, 0, 0, 'idle', rd={'state': 'done', 'top': {'kind': 'task', 'name': '导入商品目录', 'tool': '导入脚本', 'pct': 100, 'exact': True},
                                           'agents': none, 'rows': [{'n': '导入商品目录', 't': '导入脚本', 's': 'done', 'a': 4, 'p': 100}]}))
save('task-failed', base(1, 0, 0, 'idle', rd={'state': 'error', 'top': {'kind': 'task', 'name': '导入商品目录', 'tool': '导入脚本', 'pct': 30, 'exact': True},
                                             'agents': none, 'rows': [{'n': '导入商品目录', 't': '导入脚本', 's': 'error', 'a': 4, 'p': 30}]}))
save('task-list', base(4, 3, 0, 'render 62%', rd={'state': 'working', 'top': {'kind': 'render', 'name': 's040_explode', 'pct': 62, 'exact': True, 'eta': 1500},
                                                 'job': {'title': '产品片', 'done': 3, 'total': 8}, 'agents': {'error': 0, 'waiting': 0, 'working': 1, 'done': 0, 'idle': 2},
                                                 'rows': [{'n': '夜间备份', 't': 'backup', 's': 'error', 'a': 40, 'p': 30}, rows[0], task_rows[0],
                                                          {'n': 'Rebuild the search index', 't': 'indexer', 's': 'working', 'a': 75}, rows[1]]}))

# What the Claude desktop app sends: no "rd" block, ASCII only.
plain = base(3, 2, 0, 'running: refactor auth')
plain['entries'] = ['10:42 git push', '10:41 yarn test', '10:39 reading file...']
save('plain', plain)
plain_prompt = base(3, 1, 1, 'approve: Bash', prompt={'id': 'req_plain_0001', 'tool': 'Bash', 'hint': 'rm -rf /tmp/build-cache'})
plain_prompt['entries'] = ['10:42 git push']
save('plain-request', plain_prompt)

save('time', {'time': [1795428000 + 9 * 3600 + 41 * 60, 0]})

# ---- Pages (a computer that tells the two sides apart, and says how it is doing itself: firmware "rd" 3) ----

render_rows = [
    {'n': 's040_explode', 's': 'working', 'p': 62},
    {'n': 's045_explode_alt', 's': 'working', 'p': 18},
]
agent_rows = [
    {'n': 'billing-api', 't': 'Codex', 's': 'working', 'a': 913},
    {'n': 'landing-page', 't': 'Claude Code', 's': 'working', 'a': 15},
    {'n': 'docs', 't': 'Claude Code', 's': 'done', 'a': 120},
]


def render_side(state='working', top=None, rows=None, run=2, queue=4, qeta=21900, job=None):
    side = {'state': state, 'rows': render_rows if rows is None else rows, 'n': {'run': run, 'queue': queue}}
    if top is not None:
        side['top'] = top
    if qeta is not None:
        side['qeta'] = qeta
    if job is not None:
        side['job'] = job
    return side


def agent_side(state='working', top=None, rows=None):
    side = {'state': state, 'rows': agent_rows if rows is None else rows}
    if top is not None:
        side['top'] = top
    return side


job = {'title': '产品片', 'done': 3, 'total': 8}
render_top = {'name': 's040_explode', 'pct': 62, 'exact': True, 'eta': 1500}
agent_top = {'kind': 'agent', 'name': 'billing-api', 'tool': 'Codex', 'age': 913}
no_renders = render_side('idle', rows=[], run=0, queue=0, qeta=None)
no_agents = agent_side('idle', rows=[])
none_at_all = {'error': 0, 'waiting': 0, 'working': 0, 'done': 0, 'idle': 0}

# Both sides busy: a render with its queue on one page, two sessions at work on the other.
save('pages-both', base(6, 4, 0, 'render 62% | 2 working', rd={
    'state': 'working', 'top': dict(render_top, kind='render'), 'job': job, 'agents': agents,
    'r': render_side(top=render_top, job=job), 'a': agent_side(top=agent_top)}))

# A session needs the user while a render goes on: the agents' page takes the screen.
waiting_top = {'kind': 'agent', 'name': 'docs', 'tool': 'Claude Code', 'wait': 'permission', 'age': 42}
save('pages-agent-waiting', base(6, 3, 1, 'docs waiting', rd={
    'state': 'waiting', 'top': waiting_top, 'agents': {'error': 0, 'waiting': 1, 'working': 2, 'done': 0, 'idle': 2},
    'r': render_side(top=render_top, job=job),
    'a': agent_side('waiting', top=waiting_top, rows=[{'n': 'docs', 't': 'Claude Code', 's': 'waiting', 'a': 42}] + agent_rows[:2])}))

# A render that has stopped moving, with sessions still at work.
stuck_top = {'name': 's040_explode', 'pct': 62, 'exact': True}
save('pages-render-stuck', base(6, 2, 1, '1 waiting | 2 working', rd={
    'state': 'waiting', 'top': dict(stuck_top, kind='render'), 'job': job, 'agents': agents,
    'r': render_side('waiting', top=stuck_top, rows=[{'n': 's040_explode', 's': 'waiting', 'p': 62}], run=0, queue=4, qeta=None, job=job),
    'a': agent_side(top=agent_top)}))

# A render that does not say how far along it is.
save('pages-render-going', base(1, 1, 0, '1 rendering', rd={
    'state': 'working', 'top': {'kind': 'render', 'name': 'comp_final_v3'}, 'agents': none_at_all,
    'r': render_side(top={'name': 'comp_final_v3'}, rows=[{'n': 'comp_final_v3', 's': 'working'}], run=1, queue=0, qeta=None),
    'a': no_agents}))

# The queue is through; a session is still at work.
save('pages-render-done', base(3, 1, 0, '1 working | 1 done', rd={
    'state': 'working', 'top': agent_top, 'agents': {'error': 0, 'waiting': 0, 'working': 1, 'done': 0, 'idle': 2},
    'r': render_side('done', top={'name': 's080_end'}, rows=[], run=0, queue=0, qeta=None, job={'title': '产品片', 'done': 8, 'total': 8}),
    'a': agent_side(top=agent_top, rows=agent_rows[:1])}))

# A render failed.
save('pages-render-failed', base(2, 0, 1, '1 failed', rd={
    'state': 'error', 'top': {'kind': 'render', 'name': 's050_logo'}, 'agents': none_at_all,
    'r': render_side('error', top={'name': 's050_logo'}, rows=[], run=0, queue=0, qeta=None, job={'title': '产品片', 'done': 4, 'total': 8}),
    'a': no_agents}))

# Only sessions; nothing renders.
save('pages-agents-only', base(5, 2, 0, '2 working', rd={
    'state': 'working', 'top': agent_top, 'agents': agents, 'r': no_renders, 'a': agent_side(top=agent_top)}))

# Nothing anywhere.
save('pages-idle', base(0, 0, 0, 'idle', rd={'state': 'idle', 'agents': none_at_all, 'r': no_renders, 'a': no_agents}))

# The computer about itself. These go on lines of their own.
save('mac', {'mac': {'cpu': 37, 'cores': 10, 'gpu': 92, 'vram': 8.2, 'mem': [21.4, 32], 'mp': 1, 'swap': 1.2,
                     't': 71, 'tmax': 78, 'th': 0, 'disk': 212, 'ac': True, 'awake': True, 'w': 86, 'fan': 35}})
save('mac-hot', {'mac': {'cpu': 100, 'cores': 10, 'gpu': 100, 'vram': 14.6, 'mem': [30.9, 32], 'mp': 2, 'swap': 9.4,
                         't': 101, 'tmax': 108, 'th': 2, 'disk': 38, 'ac': False, 'bat': 64, 'awake': False, 'w': 151, 'fan': 100}})
# Working hard but not yet slowed down for heat: the fans say so before the system does.
save('mac-busy', {'mac': {'cpu': 88, 'cores': 10, 'gpu': 97, 'vram': 11.3, 'mem': [26.2, 32], 'mp': 1, 'swap': 2.0,
                          't': 88, 'tmax': 96, 'th': 0, 'disk': 212, 'ac': True, 'awake': True, 'w': 143, 'fan': 100}})
save('mac-bare', {'mac': {'cpu': 4, 'mem': [9.5, 16], 'mp': 1, 'awake': False}})
