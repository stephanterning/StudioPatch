import os,json,time,subprocess,pathlib,sys
root=pathlib.Path(sys.argv[2]).resolve();root.mkdir(exist_ok=True)
executable=sys.argv[1]
for f in ('fail','request','events','runtime-status.json','notifications.jsonl','disconnected'):
 (root/f).unlink(missing_ok=True)
preset={'inputCount':2,'outputCount':2,'sampleRate':96000,'bufferFrames':64,'delayFrames':256,'masterUID':'mock','devices':[{'uid':'mock','drift':False}],'inputs':[{'deviceUID':'mock','channel':1},None],'outputs':[]}
def save():
 tmp=root/'next.json';tmp.write_text(json.dumps(preset));tmp.replace(root/'last-session.json')
def wait(predicate,seconds=10):
 end=time.time()+seconds
 while time.time()<end:
  try:
   s=json.loads((root/'runtime-status.json').read_text())
   if predicate(s):return s
  except (FileNotFoundError,json.JSONDecodeError):pass
  time.sleep(.1)
 raise AssertionError((root/'runtime-status.json').read_text() if (root/'runtime-status.json').exists() else 'No status')
def notifications():
 path=root/'notifications.jsonl'
 return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
save();env=dict(os.environ,STUDIOPATCH_TEST_DIRECTORY=str(root))
p=subprocess.Popen([executable],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
try:
 wait(lambda s:s['running']);print('PASS: autonomous start without panel',flush=True)
 duplicate=subprocess.run([executable],env=env,timeout=5)
 assert duplicate.returncode==0 and p.poll() is None
 print('PASS: singleton prevents duplicate engine',flush=True)
 preset['inputs'][1]={'deviceUID':'mock','channel':2};save()
 time.sleep(2)
 assert (root/'events').read_text().count('start')==2
 assert notifications()==[], notifications()
 print('PASS: routing edits applied automatically without format notifications',flush=True)
 (root/'fail').write_text('fail');preset['outputCount']=3;save()
 wait(lambda s:not s['running'] and 'Simulated failure' in s['message'])
 time.sleep(1)
 events=(root/'events').read_text();assert events.count('start')==2
 assert [n['id'] for n in notifications()]==['format-failed'],notifications()
 assert '96000 Hz' in notifications()[0]['body'] and '3 From Computer' in notifications()[0]['body']
 print('PASS: failed format change notifies once despite immediate retries',flush=True)
 (root/'fail').unlink();wait(lambda s:s['running'],12)
 assert [n['id'] for n in notifications()]==['format-failed','format-changed'],notifications()
 print('PASS: automatic recovery announces successfully applied format',flush=True)
 (root/'request').write_text('48000')
 wait(lambda s:s['running'] and s['rate']==48000)
 assert float((root/'request').read_text())==0
 assert [n['id'] for n in notifications()]==['format-failed','format-changed','format-changed'],notifications()
 assert '48000 Hz' in notifications()[-1]['body']
 time.sleep(2)
 assert len(notifications())==3,notifications()
 print('PASS: client rate change notifies once after restart and acknowledgement',flush=True)
 preset['sampleRate']=44100;preset['followMaster']=True;save()
 wait(lambda s:s['running'] and s['rate']==44100)
 print('PASS: panel rate request overrides old master rate with Follow Master enabled',flush=True)
 preset['sampleRate']=88200;preset['followMaster']=False;save()
 wait(lambda s:s['running'] and s['rate']==88200)
 print('PASS: panel rate request works with Follow Master disabled',flush=True)
 # Hot unplug must publish the new inventory even while a failed restart is backing off.
 (root/'fail').write_text('fail');preset['outputCount']=4;save()
 wait(lambda s:not s['running'] and 'Simulated failure' in s['message'])
 (root/'disconnected').write_text('1')
 wait(lambda s:s['devices']==[] and not s['installed'],3)
 wait(lambda s:'Audio interfaces unavailable: mock' in s['message'],12)
 assert json.loads((root/'last-session.json').read_text())['devices']==preset['devices']
 print('PASS: hot unplug updates inventory during retries, preserves selection and reports missing hardware before driver failure',flush=True)
 (root/'disconnected').unlink();(root/'fail').unlink()
 wait(lambda s:s['running'] and len(s['devices'])==1,12)
 print('PASS: reconnect recovers automatically',flush=True)
finally:
 p.terminate();out,err=p.communicate(timeout=5)
 if err:print(err.decode())
