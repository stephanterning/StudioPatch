import os,json,time,subprocess,pathlib,sys,shutil
root=pathlib.Path(sys.argv[2]).resolve();root.mkdir(exist_ok=True)
executable=sys.argv[1]
for f in ('fail','request','events','runtime-status.json','notifications.jsonl','disconnected','bad-object','hang-control','recovery-attempt.json','invalid-clock'):
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
 assert (root/'events').read_text().count('start')==1
 assert (root/'events').read_text().count('route')==1
 assert (root/'events').read_text().count('stop')==0
 assert notifications()==[], notifications()
 print('PASS: routing edits applied automatically without format notifications',flush=True)
 (root/'fail').write_text('fail');preset['outputCount']=3;save()
 failed=wait(lambda s:not s['running'] and 'Simulated failure' in s['message'])
 assert failed.get('latencyDiagnostics') is None
 time.sleep(1)
 events=(root/'events').read_text();assert events.count('start')==1
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
 failed=wait(lambda s:not s['running'] and 'Simulated failure' in s['message'])
 assert failed.get('latencyDiagnostics') is None
 (root/'disconnected').write_text('1')
 wait(lambda s:s['devices']==[] and not s['installed'],7)
 wait(lambda s:'Audio interfaces unavailable: mock' in s['message'],12)
 assert json.loads((root/'last-session.json').read_text())['devices']==preset['devices']
 print('PASS: hot unplug updates inventory during retries, preserves selection and reports missing hardware before driver failure',flush=True)
 (root/'disconnected').unlink();(root/'fail').unlink()
 wait(lambda s:s['running'] and len(s['devices'])==1,12)
 print('PASS: reconnect recovers automatically',flush=True)
 starts=(root/'events').read_text().count('start')
 (root/'invalid-clock').write_text('1')
 end=time.time()+10
 while (root/'events').read_text().count('start')==starts and time.time()<end:time.sleep(.1)
 wait(lambda s:s['running'])
 assert (root/'events').read_text().count('start')==starts+1
 print('PASS: invalidated clock after a simulated interruption rebuilds one engine',flush=True)
 # Display-name changes are metadata only; identity changes recreate the device even at identical widths/rate.
 starts=(root/'events').read_text().count('start')
 routes=(root/'events').read_text().count('route')
 preset['virtualDeviceName']='StudioPatch (Renamed studio)';save()
 wait(lambda s:json.loads((root/'names.json').read_text()).get('deviceName')==preset['virtualDeviceName'])
 assert (root/'events').read_text().count('start')==starts
 assert (root/'events').read_text().count('route')==routes
 print('PASS: preset rename publishes metadata without audio restart or routing update',flush=True)
 for uid in ['se.studiopatch.preset.test-a','se.studiopatch.preset.test-b','se.studiopatch.preset.test-a']:
  preset['virtualDeviceUID']=uid;save();starts+=1
  wait(lambda s:s['running'] and json.loads((root/'names.json').read_text()).get('uid')==uid)
  assert (root/'events').read_text().count('start')==starts
 assert (root/'events').read_text().count('route')==routes
 print('PASS: distinct preset UIDs and return to an existing UID each rebuild the device',flush=True)
 # A persistent HAL failure gets one fresh process; the budget survives exec.
 images=(root/'events').read_text().count('image')
 (root/'bad-object').write_text('1')
 wait(lambda s:not s['running'] and 'Stale HAL object' in s['message'])
 end=time.time()+20
 while not (root/'recovery-attempt.json').exists() and time.time()<end:time.sleep(.1)
 assert (root/'recovery-attempt.json').exists()
 (root/'bad-object').unlink()
 wait(lambda s:s['running'] and (root/'events').read_text().count('image')==images+1,12)
 assert (root/'events').read_text().count('image')==images+1
 print('PASS: persistent HAL error replaces only the service and recovers',flush=True)
 (root/'bad-object').write_text('1')
 stopped=wait(lambda s:'Automatic recovery stopped' in s['message'],20)
 assert stopped.get('recoveryStopped') is True and stopped.get('latencyDiagnostics') is None
 assert p.wait(timeout=5)==0
 assert json.loads((root/'last-session.json').read_text())==preset
 print('PASS: persistent cross-process budget stops restart loops and preserves settings',flush=True)
 # New isolated fixture budget: a blocked control worker must not block its watchdog.
 (root/'bad-object').unlink();(root/'recovery-attempt.json').unlink()
 (root/'runtime-status.json').unlink()
 p=subprocess.Popen([executable],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 wait(lambda s:s['running'])
 images=(root/'events').read_text().count('image')
 (root/'hang-control').write_text('1')
 end=time.time()+38
 while not (root/'recovery-attempt.json').exists() and time.time()<end:time.sleep(.1)
 assert (root/'recovery-attempt.json').exists()
 (root/'hang-control').unlink(missing_ok=True)
 wait(lambda s:s['running'] and (root/'events').read_text().count('image')==images+1,12)
 assert (root/'events').read_text().count('image')==images+1
 print('PASS: blocked control worker gets bounded process recovery',flush=True)
 # Corrupt budget and failed exec exercise the real service's fail-closed exits.
 p.terminate();p.communicate(timeout=5)
 for case in ['corrupt-budget','missing-executable','inventory-error']:
  case_root=root/case;case_root.mkdir()
  (case_root/'last-session.json').write_text(json.dumps(preset))
  (case_root/('inventory-bad-object' if case=='inventory-error' else 'bad-object')).write_text('1')
  expected='Automatic recovery stopped'
  launch=executable
  if case!='missing-executable':(case_root/'recovery-attempt.json').write_text('not json')
  else:
   launch=str(case_root/'temporary-service');shutil.copy2(executable,launch)
   expected='could not restart the executable'
  p=subprocess.Popen([launch],env=dict(env,STUDIOPATCH_TEST_DIRECTORY=str(case_root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  end=time.time()+5
  while not (case_root/'runtime-status.json').exists() and time.time()<end:time.sleep(.1)
  assert (case_root/'runtime-status.json').exists()
  if case=='missing-executable':pathlib.Path(launch).unlink()
  assert p.wait(timeout=20)==0
  stopped=json.loads((case_root/'runtime-status.json').read_text())
  assert expected in stopped['message'] and stopped['recoveryStopped'] and not stopped['running']
  assert (case_root/'events').read_text().count('image')==1
  if case=='inventory-error':assert len(stopped['devices'])==1 and not stopped['installed']
  assert json.loads((case_root/'last-session.json').read_text())==preset
  print('PASS: '+case+' stops safely without another process image',flush=True)
finally:
 p.terminate();out,err=p.communicate(timeout=5)
 if err:print(err.decode())
