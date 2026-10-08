#!/usr/bin/env python3
"""R6 installer v1.0.1: inspect real wake-result assignments; no fuzzy patching."""
from __future__ import annotations
import argparse, difflib, hashlib, json, re, sys
from pathlib import Path
HOME=Path(__file__).resolve().parent
class Refuse(RuntimeError): pass

def masked(s):
    rx=re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',re.S)
    return rx.sub(lambda m:''.join('\n' if c=='\n' else ' ' for c in m.group()),s)
def bounds(s,name):
    z=masked(s); ms=list(re.finditer(r'\b'+re.escape(name)+r'\s*\([^;{}]*\)\s*\{',z))
    if len(ms)!=1: raise Refuse(f'{name}: expected one function definition, got {len(ms)}')
    a=ms[0].end(); depth=1
    for b in range(a,len(z)):
        if z[b]=='{': depth+=1
        elif z[b]=='}':
            depth-=1
            if not depth:return a,b
    raise Refuse(name+': unbalanced braces')
def edit(s,name,fn):
    a,b=bounds(s,name);return s[:a]+fn(s[a:b])+s[b:]
def once(s,rx,repl,label):
    if len(re.findall(rx,s,re.M))!=1:raise Refuse(label+': missing/duplicate anchor')
    return re.sub(rx,repl,s,count=1,flags=re.M)
def add_include(s):
    if 'r6_notify.h' in s:raise Refuse('R6 already present; do not apply twice')
    m=re.search(r'^\s*#include[^\n]*\n',s,re.M)
    if not m:raise Refuse('no include block')
    return s[:m.start()]+'\n#include <linux/r6_notify.h>\n'+s[m.start():]
def smp(s):
    def q(b):
        if not re.search(r'llist_add\s*\(node,\s*&per_cpu\(call_single_queue,\s*cpu\)\)',b):raise Refuse('SMP publish expression differs')
        z=masked(b); returns=list(re.finditer(r'\breturn\b',z))
        if returns:
            cond=re.search(r'if\s*\(\s*type\s*==\s*CSD_TYPE_SYNC\s*\|\|\s*type\s*==\s*CSD_TYPE_ASYNC\s*\)\s*\{',z)
            if len(returns)!=1 or cond is None:raise Refuse('SMP unknown early return; inspect it rather than guess')
            depth=1; close=None
            for j in range(cond.end(),len(z)):
                if z[j]=='{':depth+=1
                elif z[j]=='}':
                    depth-=1
                    if not depth:close=j;break
            if close is None or not cond.end()<=returns[0].start()<close:raise Refuse('SMP return outside known non-TTWU debug branch')
        b='\n        struct r6_queue_token r6q = { .slot = -1 };\n'+b
        b=once(b,r'(^[ \t]*)ipio_note_enqueue\(cpu,\s*node,[^;]+;',lambda m:m.group(1)+'r6q = r6_ttwu_publish(cpu, node);\n'+m.group(),'SMP old enqueue hook')
        return b+'\n        r6_ttwu_publish_return(r6q);\n'
    s=edit(s,'__smp_call_single_queue',q)
    def irq(b):
        b=once(b,r'(^[ \t]*)ipio_irq_enter\(\);',lambda m:m.group(1)+'r6_call_irq_enter();\n'+m.group(),'old IRQ enter')
        return once(b,r'(^[ \t]*)ipio_irq_exit\(\);',lambda m:m.group(1)+'r6_call_irq_exit();\n'+m.group(),'old IRQ exit')
    s=edit(s,'generic_smp_call_function_single_interrupt',irq)
    def batch(b):
        r=re.search(r'entry\s*=\s*llist_reverse_order\(entry\);',b); h=re.search(r'ipio_note_batch\(entry\);',b)
        if not r or not h or r.end()>h.start():raise Refuse('old batch hook is not after list reversal')
        return once(b,r'(^[ \t]*)ipio_note_batch\(entry\);',lambda m:m.group(1)+'r6_call_batch(entry);\n'+m.group(),'old batch hook')
    return add_include(edit(s,'flush_smp_call_function_queue',batch))
def wake_result_statement(body):
    """Find one simple original wake-result assignment in the new-work branch.

    Match a masked copy, so comments/strings cannot be anchors. Offsets still
    refer to the original text. Do NOT add a missing assignment or rewrite a
    compound expression; an unfamiliar body is exported for inspection.
    """
    z = masked(body)
    calls = list(re.finditer(r'\bwake_up_process\s*\(', z))
    if len(calls) != 1:
        raise Refuse('original wake result: vhost_work_queue_tagged contains '
                     f'{len(calls)} real wake_up_process calls; expected exactly 1')
    call = calls[0]
    end_match = re.match(
        r'wake_up_process\s*\(\s*dev\s*->\s*worker\s*\)\s*;', z[call.start():])
    if end_match is None:
        raise Refuse('original wake result: wake_up_process is not a simple '
                     'statement RHS taking dev->worker; inspect the exported function')
    end = call.start() + end_match.end()
    # A preceding control statement without braces remains in the prefix and
    # fails the fullmatch below, rather than changing its scope by insertion.
    boundary = max(z.rfind(c, 0, call.start()) for c in ';{}') + 1
    statement = z[boundary:end]
    m = re.fullmatch(
        r'\s*(?:(?:int|bool|long|unsigned\s+int)\s+)?'
        r'(?P<var>[A-Za-z_]\w*)\s*=\s*'
        r'wake_up_process\s*\(\s*dev\s*->\s*worker\s*\)\s*;', statement)
    if m is None:
        raise Refuse('original wake result: no supported existing return-value '
                     'assignment; expected <variable> = wake_up_process(dev->worker); '
                     '(whitespace/comments may vary). No wake call was added or rewritten')
    branch = re.search(
        r'if\s*\(\s*!\s*test_and_set_bit\s*\(\s*VHOST_WORK_QUEUED\s*,\s*'
        r'&\s*work\s*->\s*flags\s*\)\s*\)\s*\{', z)
    if branch is None:
        raise Refuse('original wake result: expected braced new-work branch')
    depth = 1
    close = None
    for i in range(branch.end(), len(z)):
        if z[i] == '{': depth += 1
        elif z[i] == '}':
            depth -= 1
            if depth == 0:
                close = i
                break
    first_token = boundary + re.search(r'\S', statement).start()
    if close is None or not (branch.end() <= first_token < end <= close):
        raise Refuse('original wake result: assignment is outside the new-work branch')
    publish = list(re.finditer(
        r'\bllist_add\s*\(\s*&\s*work\s*->\s*node\s*,\s*'
        r'&\s*dev\s*->\s*work_list\s*\)\s*;', z))
    if len(publish) != 1 or not (branch.end() <= publish[0].start()
                                 < publish[0].end() <= first_token):
        raise Refuse('original wake result: expected one original work-list '
                     'publication before this wake assignment in the same branch')
    line_start = z.rfind('\n', 0, first_token) + 1
    leading = z[line_start:first_token]
    indent = leading if not leading.strip() else '        '
    return end, m.group('var'), indent

def instrument_wake_result(body):
    end, var, indent = wake_result_statement(body)
    # Insert after the actual statement, before any following source. The
    # original assignment, including its comments and formatting, is intact.
    return (body[:end] + '\n' + indent
            + 'r6_work_wake_return(r6q, ' + var + ');' + body[end:])

def write_vhost_diagnostic(root, out, reason='explicit read-only diagnostic'):
    """Export only the function needed to diagnose this anchor; never edit it."""
    path = root / 'drivers/vhost/vhost.c'
    source = path.read_text()
    a, b = bounds(source, 'vhost_work_queue_tagged')
    start = masked(source).rfind('vhost_work_queue_tagged', 0, a)
    start = source.rfind('\n', 0, start) + 1
    first_line = source.count('\n', 0, start) + 1
    body = source[a:b]
    calls = len(re.findall(r'\bwake_up_process\s*\(', masked(body)))
    exact = len(re.findall(
        r'(^[ \t]*)woke\s*=\s*wake_up_process\(dev->worker\);', body, re.M))
    try:
        _, var, _ = wake_result_statement(body)
        status = 'supported existing result variable: ' + var
    except Refuse as exc:
        status = str(exc)
    rows = [
        'R6 installer v1.0.1; read-only source diagnostic',
        'source=' + str(path),
        'reason=' + reason,
        'real_wake_calls=' + str(calls),
        'old_exact_anchor_matches=' + str(exact),
        'new_match=' + status,
        '--- vhost_work_queue_tagged (original, with source line numbers) ---',
    ]
    rows += [f'{i}: {line}' for i, line in enumerate(
        source[start:b+1].splitlines(), first_line)]
    out.mkdir(parents=True, exist_ok=True)
    dest = out / 'vhost_queue_diagnostic.txt'
    dest.write_text('\n'.join(rows) + '\n')
    return dest

def vhost(s):
    def q(b):
        if len(re.findall(r'\bwake_up_process\s*\(',masked(b)))!=1:raise Refuse('vhost queue must contain exactly ONE original wake_up_process')
        if not re.search(r'if\s*\(\s*!test_and_set_bit\(VHOST_WORK_QUEUED,\s*&work->flags\)\s*\)',b):raise Refuse('queued-bit branch differs')
        if re.search(r'\br6q\b', masked(b)):
            raise Refuse('vhost_work_queue_tagged: r6q already exists; inspect before applying')
        b=instrument_wake_result(b)
        b='\n        struct r6_work_token r6q = { .kind = -1 };\n'+b
        b=once(b,r'(^[ \t]*)llist_add\(&work->node,\s*&dev->work_list\);',lambda m:m.group(1)+'r6q = r6_work_publish(dev, work, dev->worker, (unsigned int)source);\n'+m.group(),'vhost publish')
        return once(b,r'(^[ \t]*)n5_note_queue\(dev,\s*work,\s*source,\s*2\);',lambda m:m.group(1)+'r6_work_merged(dev, work, dev->worker, (unsigned int)source);\n'+m.group(),'merged branch')
    s=edit(s,'vhost_work_queue_tagged',q)
    def worker(b):
        b=once(b,r'(^[ \t]*)clear_bit\(VHOST_WORK_QUEUED,\s*&work->flags\);',lambda m:m.group(1)+'r6_work_execute(dev, work, dev->worker);\n'+m.group(),'BEFORE bit clear')
        return once(b,r'(^[ \t]*)work->fn\(work\);',lambda m:m.group()+'\n'+m.group(1)+'r6_work_complete(dev, work, dev->worker);','AFTER work function')
    return add_include(edit(s,'vhost_worker',worker))
def net(s):
    a,b=bounds(s,'handle_tx_net')
    if not re.search(r'n4_handle_tx\(net,\s*2\)',s[a:b]):raise Refuse('fix N4 handle_tx_net origin to 2 / apply R5 first')
    def tx(b):
        b='\n        struct r6_tx_token r6t = { .kind = -1 };\n'+b
        b=once(b,r'(^[ \t]*)mutex_lock_nested\(&vq->mutex,\s*VHOST_NET_VQ_TX\);',lambda m:
               m.group(1)+'r6t = r6_tx_enter(&net->dev, &vq->poll.work,\n'+m.group(1)+'                   &net->poll[VHOST_NET_VQ_TX].work, net->dev.worker);\n'+m.group()+'\n'+m.group(1)+'r6_tx_locked(&r6t, vq->last_avail_idx,\n'+m.group(1)+'             vhost_has_feature(vq, VIRTIO_F_RING_PACKED),\n'+m.group(1)+'             vhost_has_feature(vq, VIRTIO_RING_F_EVENT_IDX),\n'+m.group(1)+'             vq->busyloop_timeout, vq->num);','TX mutex')
        return once(b,r'(^[ \t]*)vhost_n5_tx_end\(&net->n5_tx,\s*vq\);',lambda m:m.group(1)+'r6_tx_leave(&r6t, vq->last_avail_idx);\n'+m.group(),'TX leave')
    return add_include(edit(s,'handle_tx',tx))
def ccm(s):
    def handler(b):
        if 'ccm_ioeventfd_match' not in b:raise Refuse('not the supplied CCM handler')
        return once(b,r'(^[ \t]*)mutex_lock\(&client->vm->ioeventfds_lock\);',lambda m:m.group(1)+'r6_io_service(addr);\n'+m.group(),'CCM parsed WRITE, before mutex')
    return add_include(edit(s,'ioeventfd_handler',handler))
def switch_abi(s):
    m=re.search(r'TRACE_EVENT\(sched_switch,.*?TP_PROTO\((.*?)\)\s*,',s,re.S)
    if not m:raise Refuse('sched_switch TP_PROTO missing')
    v=re.sub(r'\s+','',m.group(1)); old='boolpreempt,structtask_struct*prev,structtask_struct*next'
    if v==old:return 0
    if v==old+',unsignedintprev_state':return 1
    raise Refuse('unknown sched_switch ABI: '+m.group(1))
def plan(root,cp):
    out={}
    for p,fn in [(root/'kernel/smp.c',smp),(root/'drivers/vhost/vhost.c',vhost),(root/'drivers/vhost/net.c',net),(cp,ccm)]:
        old=p.read_text()
        try: new=fn(old)
        except Refuse as e: raise Refuse(str(p)+": "+str(e)) from e
        for name in ['wake_up_process','test_and_set_bit','llist_add','eventfd_signal','work->fn']:
            rx=r'\b'+re.escape(name)+r'\s*\('
            if len(re.findall(rx,masked(old)))!=len(re.findall(rx,masked(new))):raise Refuse('original primitive count changed: '+name)
        out[p]=new.encode()
    m=root/'kernel/Makefile';out[m]=(m.read_text().rstrip()+'\n\n# R6 temporary diagnostic (built-in).\nobj-$(CONFIG_SMP) += r6_notify.o\n').encode()
    for rel,src in [('kernel/r6_notify.c','r6_notify.c'),('kernel/r6_math.h','r6_math.h'),('include/linux/r6_notify.h','r6_notify.h')]:
        p=root/rel
        if p.exists():raise Refuse(str(p)+' already exists')
        out[p]=(HOME/'src'/src).read_bytes()
    p=root/'kernel/r6_build_config.h'
    if p.exists():raise Refuse(str(p)+' already exists')
    out[p]=('#define R6_SWITCH_HAS_PREV_STATE '+str(switch_abi((root/'include/trace/events/sched.h').read_text()))+'\n').encode()
    return out
def digest(b):return hashlib.sha256(b).hexdigest()
def main():
    a=argparse.ArgumentParser(description=__doc__);a.add_argument('--kernel',type=Path,required=True);a.add_argument('--ccm',type=Path);a.add_argument('--out',type=Path,default=Path('r6_install_output'))
    g=a.add_mutually_exclusive_group();g.add_argument('--apply',action='store_true');g.add_argument('--check',action='store_true');g.add_argument('--restore',action='store_true');g.add_argument('--diagnose-vhost',action='store_true',help='export the original queue function without applying any changes');x=a.parse_args()
    root=x.kernel.resolve(); backup=root/'.r6_notify_backup'
    try:
        if x.diagnose_vhost:
            dest=write_vhost_diagnostic(root,x.out)
            print('DIAGNOSTIC: '+str(dest)+'; no source changed.');return 0
        if x.restore:
            meta=json.loads((backup/'manifest.json').read_text())
            for e in meta:
                p=Path(e['path'])
                if not p.exists() or digest(p.read_bytes())!=e['after_sha256']:raise Refuse(str(p)+' changed after R6; preserve edits and restore manually')
            for e in meta:
                p=Path(e['path'])
                if e['backup'] is None:p.unlink()
                else:p.write_bytes((backup/e['backup']).read_bytes())
            (backup/'RESTORED').write_text('Restored. Archive this backup before reapplying.\n');print('RESTORED; rebuild/redeploy matched kernel and modules.');return 0
        if x.ccm is None:raise Refuse('--ccm must identify the actual CCM implementation')
        if x.apply and backup.exists():raise Refuse('backup already exists; not overwritten')
        changes=plan(root,x.ccm.resolve());x.out.mkdir(parents=True,exist_ok=True);meta=[];diff=[]
        for i,(p,new) in enumerate(changes.items()):
            old=p.read_bytes() if p.exists() else b''
            try:name=str(p.relative_to(root))
            except ValueError:name='CCM_EXTERNAL/'+p.name
            diff+=list(difflib.unified_diff(old.decode().splitlines(True),new.decode().splitlines(True),fromfile='a/'+name if p.exists() else '/dev/null',tofile='b/'+name))
            meta.append({'path':str(p),'before_sha256':digest(old) if p.exists() else None,'after_sha256':digest(new),'backup':f'{i}.original' if p.exists() else None})
        (x.out/'r6_changes.patch').write_text(''.join(diff));(x.out/'planned_changes.json').write_text(json.dumps(meta,indent=2)+'\n')
        if not x.apply:print(f'CHECK OK: {len(changes)} files; review {x.out}/r6_changes.patch. No source changed.');return 0
        backup.mkdir()
        for e in meta:
            if e['backup'] is not None:(backup/e['backup']).write_bytes(Path(e['path']).read_bytes())
        (backup/'manifest.json').write_text(json.dumps(meta,indent=2)+'\n')
        written=[]
        try:
            for p,b in changes.items():p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);written.append(p)
        except Exception:
            for e in meta:
                p=Path(e['path'])
                if p in written:
                    if e['backup'] is None:p.unlink(missing_ok=True)
                    else:p.write_bytes((backup/e['backup']).read_bytes())
            raise
        print(f'APPLIED. Backup={backup}; diff={x.out}/r6_changes.patch');return 0
    except (OSError,ValueError,Refuse) as e:
        print('REFUSED: '+str(e),file=sys.stderr)
        if 'original wake result' in str(e) or 'vhost queue must contain' in str(e):
            try:
                dest=write_vhost_diagnostic(root,x.out,str(e))
                print('DIAGNOSTIC: '+str(dest)+'; no source changed by this failed plan.',file=sys.stderr)
            except (OSError,ValueError,Refuse) as diagnostic_error:
                print('Diagnostic export failed: '+str(diagnostic_error),file=sys.stderr)
        return 2
if __name__=='__main__':raise SystemExit(main())
