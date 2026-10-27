import os,json,time,subprocess,pathlib,sys,shutil
root=pathlib.Path(sys.argv[2]).resolve();root.mkdir(exist_ok=True)
executable=sys.argv[1]
for f in ('fail','request','events','runtime-status.json','notifications.jsonl','visible-notifications.json','disconnected','bad-object','stale-hardware','secondary-present','start-fail','availability','clock-skew','names-fail','metadata-gap','inventory-bad-object','publish-fail','locked-refuses','master-refuses','secondary-rate','rate-error','inventory-rate','ack-fail','configure-fail','configure-unavailable','master-rate-unreadable','write-then-unreadable','configure-pending','configure-confirmation-fail','start-reject','restore-refuses','configure-delay','clock-not-ready','clock-delay'):
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
def all_notifications():
 path=root/'notifications.jsonl'
 return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
def visible_notifications():
 path=root/'visible-notifications.json'
 return list(json.loads(path.read_text()).values()) if path.exists() else []
def visible_problems():
 return [n for n in visible_notifications() if n['id']!='unrelated-note']
def notifications():
 return [n for n in all_notifications() if n['id'] not in ['device-available','device-unavailable']]
def availability_notifications():
 return [n for n in all_notifications() if n['id'] in ['device-available','device-unavailable']]
def available():
 return (root/'availability').exists() and (root/'availability').read_text()=='1'
# Delivered problems from an earlier service process must also disappear on green.
(root/'visible-notifications.json').write_text(json.dumps({
 'sync-mismatch':{'id':'sync-mismatch'},'rate-refused.previous-process':{'id':'rate-refused'},
 'unrelated-note':{'id':'unrelated-note'}}))
save();env=dict(os.environ,STUDIOPATCH_TEST_DIRECTORY=str(root))
p=subprocess.Popen([executable],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
try:
 wait(lambda s:s['running'] and available());print('PASS: autonomous start without panel',flush=True)
 # System notifications report problems only, never a successful start.
 assert all_notifications()==[],all_notifications()
 assert visible_problems()==[] and [n['id'] for n in visible_notifications()]==['unrelated-note']
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
 # A failed change before any hardware change keeps the previous configuration.
 (root/'configure-fail').write_text('3');preset['outputCount']=3;save()
 wait(lambda s:s['running'] and 'Core Audio rejected' in s['message'] and 'previous configuration remains active' in s['message'])
 assert available()
 time.sleep(2)
 events=(root/'events').read_text();assert events.count('start')==1 and events.count('stop')==0,events
 assert [n['id'] for n in notifications()]==['format-failed'],notifications()
 assert [n['id'] for n in visible_problems()]==['format-failed']
 assert '96000 Hz' in notifications()[0]['body'] and '3 From Computer' in notifications()[0]['body'] and 'remains active' in notifications()[0]['body']
 (root/'configure-fail').unlink();time.sleep(2)
 assert (root/'events').read_text().count('start')==1
 print('PASS: a failed format change keeps the previous configuration, notifies once and does not retry in a loop',flush=True)
 # Changing the setting again retries it.
 preset['outputCount']=2;save()
 wait(lambda s:s['running'] and 'previous configuration remains active' not in s['message'])
 preset['outputCount']=3;save()
 wait(lambda s:s['running'] and (root/'events').read_text().count('start')==2,12)
 assert [n['id'] for n in notifications()]==['format-failed'],notifications()
 assert visible_problems()==[],visible_problems()
 print('PASS: changing the setting again clears the resolved failure without a success notification',flush=True)
 (root/'request').write_text('48000')
 wait(lambda s:s['running'] and s['rate']==48000)
 assert float((root/'request').read_text())==0
 time.sleep(2)
 assert [n['id'] for n in notifications()]==['format-failed'],notifications()
 print('PASS: a client rate change is applied and acknowledged without a success notification',flush=True)
 preset['sampleRate']=44100;preset['followMaster']=True;save()
 wait(lambda s:s['running'] and s['rate']==44100)
 print('PASS: panel rate request overrides old master rate with Follow Master enabled',flush=True)
 preset['sampleRate']=88200;preset['followMaster']=False;save()
 wait(lambda s:s['running'] and s['rate']==88200)
 print('PASS: panel rate request works with Follow Master disabled',flush=True)
 # Hot unplug is handled while a rejected change is pending.
 (root/'fail').write_text('fail');preset['outputCount']=4;preset['sampleRate']=44100;save()
 wait(lambda s:'Simulated failure' in s['message'])
 (root/'disconnected').write_text('1')
 wait(lambda s:s['devices']==[] and s['installed'],7)
 wait(lambda s:'Audio interfaces unavailable: mock' in s['message'],12)
 assert json.loads((root/'last-session.json').read_text())['devices']==preset['devices']
 assert not available()
 assert [n['id'] for n in availability_notifications()]==['device-unavailable']
 time.sleep(2)
 assert len(availability_notifications())==1
 print('PASS: hot unplug updates inventory during retries, preserves selection and reports missing hardware before driver failure',flush=True)
 (root/'disconnected').unlink();(root/'fail').unlink();preset['sampleRate']=88200;save()
 wait(lambda s:s['running'] and len(s['devices'])==1,12)
 assert not any(n['id']=='device-unavailable' for n in visible_problems())
 print('PASS: reconnect recovers automatically and clears the disconnection notification',flush=True)
 assert available() and [n['id'] for n in availability_notifications()]==['device-unavailable']
 # Every preset member is required, even a secondary with no routes.
 (root/'secondary-present').write_text('1')
 preset['devices'].append({'uid':'secondary','drift':False,'syncLocked':False});save()
 wait(lambda s:s['running'] and len(s['devices'])==2,12)
 # Timestamp diagnostics are never a stop/restart/withdrawal policy.
 before_events=(root/'events').read_text();before_notes=all_notifications()
 for skew in [-32.795953195134643,-188.34397473186255,20000,0]:
  (root/'clock-skew').write_text(str(skew))
  wait(lambda s:s['running'] and abs(json.loads(s.get('latencyDiagnostics') or '{}').get('devices',[{}])[0].get('clockSkewFrames',1e9)-skew)<1e-5)
  assert available() and (root/'events').read_text()==before_events and all_notifications()==before_notes
 # Even with an unlocked secondary at a different rate, route edits stay live.
 preset['inputs'][1]=None;save()
 wait(lambda s:(root/'events').read_text().count('route')==before_events.count('route')+1)
 assert (root/'events').read_text().count('start')==before_events.count('start')
 assert (root/'events').read_text().count('stop')==before_events.count('stop')
 (root/'clock-skew').unlink()
 print('PASS: large timestamp deviations and unlocked rate mismatch do not mute, restart or withdraw routing',flush=True)
 count=len(availability_notifications())
 (root/'secondary-present').unlink()
 wait(lambda s:not s['running'] and 'secondary' in s['message'],12)
 assert not available() and len(availability_notifications())==count+1
 # Switch identity while offline: neither the old nor new device may appear.
 preset['virtualDeviceUID']='se.studiopatch.preset.offline'
 preset['virtualDeviceName']='StudioPatch (Offline studio)';save()
 time.sleep(2)
 assert not available() and len(availability_notifications())==count+1
 (root/'start-fail').write_text('1');(root/'secondary-present').write_text('1')
 wait(lambda s:not s['running'] and 'Simulated start failure' in s['message'],12)
 assert not available() and len(availability_notifications())==count+1
 (root/'start-fail').unlink()
 wait(lambda s:s['running'] and available(),12)
 assert len(availability_notifications())==count+1
 preset['devices'].pop();save()
 wait(lambda s:s['running'] and json.loads((root/'names.json').read_text())['uid']==preset['virtualDeviceUID'])
 print('PASS: unrouted secondary required, offline preset switch and failed start stay absent, recovery is silent',flush=True)
 starts=(root/'events').read_text().count('start')
 (root/'stale-hardware').write_text('1')
 end=time.time()+10
 while (root/'events').read_text().count('start')==starts and time.time()<end:time.sleep(.1)
 wait(lambda s:s['running'])
 assert (root/'events').read_text().count('start')==starts+1
 print('PASS: hardware that differs from the running graph rebuilds one engine',flush=True)
 # Display-name changes are metadata only; identity changes recreate the device even at identical widths/rate.
 starts=(root/'events').read_text().count('start')
 routes=(root/'events').read_text().count('route')
 preset['virtualDeviceName']='StudioPatch (Renamed studio)';save()
 wait(lambda s:json.loads((root/'names.json').read_text()).get('deviceName')==preset['virtualDeviceName'])
 assert (root/'events').read_text().count('start')==starts
 assert (root/'events').read_text().count('route')==routes
 print('PASS: preset rename publishes metadata without audio restart or routing update',flush=True)
 for uid in ['se.studiopatch.preset.test-a','se.studiopatch.preset.test-b','se.studiopatch.preset.test-a']:
  old_notes=len(all_notifications());old_events=len((root/'events').read_text().splitlines())
  preset['virtualDeviceUID']=uid;save();starts+=1
  wait(lambda s:s['running'] and available() and json.loads((root/'names.json').read_text()).get('uid')==uid and 'available' in (root/'events').read_text().splitlines()[old_events:])
  assert (root/'events').read_text().count('start')==starts
  assert len(all_notifications())==old_notes # a successful switch is not a problem
  sequence=(root/'events').read_text().splitlines()[old_events:]
  assert sequence.index('unavailable')<sequence.index('stop')<sequence.index('start')<sequence.index('available'),sequence
 assert (root/'events').read_text().count('route')==routes
 print('PASS: distinct preset UIDs and return to an existing UID each rebuild the device',flush=True)
 # Non-audio failures are reported. None of them may stop running audio,
 # withdraw the device or replace the service process.
 def counts():
  e=(root/'events').read_text();return e.count('start'),e.count('stop'),e.count('image')
 before=counts()
 (root/'last-session.json').write_text('{not json')
 wait(lambda s:s['running'] and 'Settings could not be read' in s['message'])
 save()
 wait(lambda s:s['running'] and 'Settings could not be read' not in s['message'])
 (root/'names-fail').write_text('1');preset['virtualDeviceName']='StudioPatch (Label failure)';save()
 wait(lambda s:s['running'] and 'Channel names were not updated' in s['message'])
 (root/'names-fail').unlink()
 wait(lambda s:json.loads((root/'names.json').read_text()).get('deviceName')==preset['virtualDeviceName'])
 (root/'bad-object').write_text('1')
 wait(lambda s:s['running'] and 'Sample-rate status unavailable' in s['message'])
 (root/'bad-object').unlink()
 (root/'inventory-bad-object').write_text('1')
 wait(lambda s:s['running'] and 'StudioPatch driver is unavailable' in s['message'],8)
 (root/'inventory-bad-object').unlink()
 (root/'metadata-gap').write_text('1')
 wait(lambda s:s['running'] and not any(d['uid']=='mock' for d in s['devices']),8)
 time.sleep(1.5)
 assert available()
 (root/'metadata-gap').unlink()
 wait(lambda s:s['running'] and any(d['uid']=='mock' for d in s['devices']),8)
 assert counts()==before and available() and p.poll() is None,(before,counts())
 print('PASS: unreadable settings, label, rate-query, driver-lookup and inventory-metadata failures keep audio running',flush=True)
 (root/'publish-fail').write_text('1');preset['outputCount']=3;save()
 wait(lambda s:s['running'] and 'not yet published' in s['message'],12)
 time.sleep(2)
 after=counts()
 assert after[0]==before[0]+1 and after[1]==before[1]+1,(before,after)
 (root/'publish-fail').unlink()
 wait(lambda s:s['running'] and 'not yet published' not in s['message'])
 assert counts()==after
 print('PASS: a publication failure after start keeps the engine running and retries publication',flush=True)
 # A locked secondary that cannot follow is reported; the rest starts at the new rate.
 (root/'secondary-present').write_text('1');(root/'locked-refuses').write_text('1')
 preset['devices'].append({'uid':'secondary','drift':False,'syncLocked':True});preset['sampleRate']=48000;save()
 wait(lambda s:s['running'] and s['rate']==48000 and 'not in sync' in s['message'],12)
 assert notifications()[-1]['id']=='sync-mismatch' and 'Test secondary runs at 96000' in notifications()[-1]['body'],notifications()[-1]
 (root/'locked-refuses').unlink()
 # A rate the Sync Source refuses leaves the engine at the rate it actually reports.
 refused_before=counts()
 (root/'master-refuses').write_text('1');(root/'request').write_text('192000')
 wait(lambda s:s['running'] and s['rate']==48000 and 'Test master rejected' in s['message'],12)
 assert float((root/'request').read_text())==0 and counts()==refused_before
 assert notifications()[-1]['id']=='rate-refused' and '192000' in notifications()[-1]['body'],notifications()[-1]
 (root/'master-refuses').unlink()
 # A locked interface changed elsewhere is reported once and never set back
 # while audio runs.
 before=counts();rates=(root/'events').read_text().count('rate');notes_before=len(notifications())
 (root/'secondary-rate').write_text('44100')
 wait(lambda s:s['running'] and 'Test secondary runs at 44100' in s['message'] and 'not in sync' in s['message'],10)
 time.sleep(2)
 assert counts()==before and (root/'events').read_text().count('rate')==rates and available(),(before,counts())
 assert [n['id'] for n in notifications()[notes_before:]]==['sync-mismatch'],notifications()[notes_before:]
 (root/'secondary-rate').write_text('48000')
 wait(lambda s:s['running'] and 'not in sync' not in s['message'],10)
 preset['devices'].pop();save()
 wait(lambda s:s['running'] and len(s['devices'])==2)
 print('PASS: rate changes start with what the hardware accepts; a locked interface changed elsewhere is reported once, not set back',flush=True)
 # Missing rate information keeps the working rate, even with outdated inventory.
 before=counts()
 (root/'inventory-rate').write_text('96000');(root/'bad-object').write_text('1')
 wait(lambda s:any(d['uid']=='mock' and d['sampleRate']==96000 for d in s['devices']),8)
 time.sleep(2)
 s=json.loads((root/'runtime-status.json').read_text())
 assert s['running'] and s['rate']==48000 and counts()==before,(s['rate'],before,counts())
 (root/'bad-object').unlink();(root/'inventory-rate').unlink()
 print('PASS: a failed rate query keeps the working rate',flush=True)
 # An unacknowledged request is retried without applying the change again.
 (root/'ack-fail').write_text('1');(root/'request').write_text('44100')
 wait(lambda s:s['running'] and s['rate']==44100 and 'not acknowledged' in s['message'],12)
 after=counts();time.sleep(3)
 assert counts()==after,(after,counts())
 (root/'ack-fail').unlink()
 wait(lambda s:s['running'] and 'not acknowledged' not in s['message'])
 assert float((root/'request').read_text())==0 and counts()==after
 print('PASS: a failed acknowledgement is retried without rebuilding',flush=True)
 # A change the driver rejects keeps the previous configuration running, once.
 before=counts()
 (root/'configure-fail').write_text('5');preset['outputCount']=5;save()
 wait(lambda s:s['running'] and 'previous configuration remains active' in s['message'],12)
 time.sleep(3)
 after=counts()
 assert after==before and available(),(before,after)
 assert notifications()[-1]['id']=='format-failed' and 'remains active' in notifications()[-1]['body'],notifications()[-1]
 (root/'configure-fail').unlink();preset['outputCount']=3;save()
 wait(lambda s:s['running'] and 'previous configuration remains active' not in s['message'])
 assert counts()==after
 print('PASS: a rejected change keeps the previous configuration without retry loops',flush=True)
 def status():
  return json.loads((root/'runtime-status.json').read_text())
 # A control failure that is found before the change keeps the current engine.
 before=counts()
 (root/'configure-unavailable').write_text('1');preset['outputCount']=4;save()
 wait(lambda s:s['running'] and 'not yet applied' in s['message'] and 'broker unavailable' in s['message'],10)
 # Keep orange between retries too, while the failure message remains visible.
 for _ in range(10):
  time.sleep(.5);assert status()['health']=='warning',status()
 assert counts()==before and available() and status()['running'],(before,counts())
 (root/'configure-unavailable').unlink()
 wait(lambda s:s['running'] and counts()[0]==before[0]+1 and 'not yet applied' not in s['message'],15)
 print('PASS: an unavailable control connection defers the change without stopping audio',flush=True)
 # An unconfirmed Sync Source rate is never used. The previous configuration
 # is kept, and the status reports the rate that actually runs.
 before=counts();running_rate=status()['rate']
 (root/'master-rate-unreadable').write_text('1');preset['sampleRate']=96000;save()
 wait(lambda s:s['running'] and 'could not change to 96000' in s['message'],12)
 time.sleep(2)
 assert status()['rate']==running_rate!=96000,(status()['rate'],running_rate)
 assert counts()==before,(before,counts())
 assert notifications()[-1]['id']=='rate-refused' and 'could not be confirmed' in notifications()[-1]['body'],notifications()[-1]
 (root/'master-rate-unreadable').unlink();time.sleep(2)
 assert status()['rate']==running_rate and counts()==before
 print('PASS: an unreadable Sync Source rate leaves the current engine and rate intact and is reported',flush=True)
 # A write can reach the hardware even when all immediate readbacks fail.
 # Keep the old engine until a fresh read confirms the rate, then apply once.
 before=counts();running_rate=status()['rate'];preset['sampleRate']=48000
 (root/'write-then-unreadable').write_text('1');save()
 wait(lambda s:s['running'] and 'readback failed' in s['message'],12)
 assert counts()==before and status()['rate']==running_rate,(counts(),status())
 wait(lambda s:s['running'] and s['rate']==48000,15)
 assert counts()==(before[0]+1,before[1]+1,before[2])
 assert json.loads((root/'started.json').read_text())['sampleRate']==48000
 after=counts();time.sleep(3);assert counts()==after
 print('PASS: successful rate write followed by unreadable rate converges without guessed rollback or rebuild loop',flush=True)
 # HAL may keep a configuration request pending. Editing back to the old
 # preset must not abandon its eventual completion or its new generation.
 before=counts();(root/'configure-pending').write_text('1')
 preset['outputCount']=5;save()
 wait(lambda s:s['running'] and 'Waiting for Core Audio' in s['message'])
 time.sleep(2);assert counts()==before and available()
 (root/'configure-confirmation-fail').write_text('1')
 wait(lambda s:s['running'] and 'configuration readback failure' in s['message'] and 'not yet confirmed' in s['message'])
 preset['outputCount']=4;save();time.sleep(2)
 assert counts()==before and available()
 (root/'configure-pending').unlink();(root/'configure-confirmation-fail').unlink()
 wait(lambda s:s['running'] and counts()[0]==before[0]+2,15)
 assert json.loads((root/'started.json').read_text())['outputCount']==4
 after=counts();time.sleep(2);assert counts()==after
 print('PASS: pending configuration keeps audio and resolves before applying a newer preset',flush=True)
 # A disconnected interface is withdrawn even while a HAL request is pending.
 (root/'configure-pending').write_text('1');preset['outputCount']=5;save()
 wait(lambda s:s['running'] and 'Waiting for Core Audio' in s['message'])
 (root/'disconnected').write_text('1')
 wait(lambda s:not s['running'] and 'unavailable' in s['message'],10)
 assert not available()
 (root/'configure-pending').unlink();(root/'disconnected').unlink()
 wait(lambda s:s['running'] and available(),15)
 print('PASS: disconnection withdraws a device during pending configuration and reconnect starts it again',flush=True)
 # HAL can accept the format but the new hardware graph can fail to start.
 # Audio is then off with one notification and the device stays published.
 # Nothing is rolled back; the change is retried while audio is off.
 notes_before=len(notifications());(root/'start-reject').write_text('6');preset['outputCount']=6;save()
 wait(lambda s:not s['running'] and 'new graph start failure' in s['message'],15)
 assert available()
 configures=(root/'events').read_text().count('configure');time.sleep(6)
 assert (root/'events').read_text().count('configure')>configures and not status()['running']
 assert [n['id'] for n in notifications()[notes_before:]]==['runtime-failure'],notifications()[notes_before:]
 (root/'start-reject').unlink()
 wait(lambda s:s['running'] and json.loads((root/'started.json').read_text())['outputCount']==6,15)
 print('PASS: a failed start after HAL commit leaves audio off, notifies once, keeps the device published and recovers through retries',flush=True)
 # The new preset stays absent until the first clock is usable. A control
 # failure before commit must leave the old identity and its audio untouched.
 before=counts();old_notes=len(all_notifications())
 (root/'configure-unavailable').write_text('1')
 preset['virtualDeviceUID']='se.studiopatch.preset.clock-wait';preset['virtualDeviceName']='StudioPatch (Clock wait)';save()
 wait(lambda s:s['running'] and 'broker unavailable' in s['message'])
 assert counts()==before and available() and len(all_notifications())==old_notes
 (root/'clock-not-ready').write_text('1');(root/'configure-unavailable').unlink()
 wait(lambda s:s['running'] and 'Waiting for the hardware clock' in s['message'],15)
 assert not available()
 (root/'clock-not-ready').unlink()
 wait(lambda s:s['running'] and available())
 assert len(all_notifications())==old_notes
 print('PASS: preset switch withdraws at commit and waits for the new clock before publication, without notifications',flush=True)
 # Reproduce a HAL rejection after our own successful 96 -> 48 kHz write.
 # First use only the master: unrelated sync-lock attempts must not mask it.
 # Then repeat with a locked secondary and verify both actual hardware rates.
 for locked in [False,True]:
  preset['outputCount']=2;preset['sampleRate']=96000
  preset['devices']=[{'uid':'mock','drift':False}]+([{'uid':'secondary','drift':False,'syncLocked':True}] if locked else [])
  (root/'secondary-present').write_text('1');save()
  wait(lambda s:s['running'] and s['rate']==96000 and json.loads((root/'started.json').read_text())['outputCount']==2)
  time.sleep(1) # allow the membership edit to reach the active payload
  before=counts();(root/'configure-fail').write_text('2');preset['sampleRate']=48000;save()
  wait(lambda s:s['running'] and 'previous configuration remains active' in s['message'])
  assert status()['rate']==96000 and float((root/'hardware-rate').read_text())==96000 and counts()==before,(status(),(root/'hardware-rate').read_text())
  wait(lambda s:all(d['sampleRate']==96000 for d in s['devices'] if d['uid']=='mock' or locked))
  attempts=(root/'events').read_text().count('configure');time.sleep(3)
  assert counts()==before and (root/'events').read_text().count('configure')==attempts
  (root/'configure-fail').unlink();preset['sampleRate']=96000;save()
  wait(lambda s:s['running'] and 'previous configuration remains active' not in s['message'])
 print('PASS: HAL rejection after an owned rate write restores Sync Source and locked members without restarting or resubmitting',flush=True)
 # A refusal to undo is reported, with no mute or repeated configuration.
 (root/'restore-refuses').write_text('1');(root/'configure-fail').write_text('2');preset['sampleRate']=48000;save()
 wait(lambda s:s['running'] and 'hardware rate could not be restored to 96000' in s['message'])
 attempts=(root/'events').read_text().count('configure');time.sleep(3)
 assert counts()==before and float((root/'hardware-rate').read_text())==48000
 assert (root/'events').read_text().count('configure')==attempts
 (root/'restore-refuses').unlink();(root/'configure-fail').unlink();preset['sampleRate']=96000;save()
 wait(lambda s:s['running'] and 'could not be restored' not in s['message'])
 print('PASS: a refused rate undo stays visible and never mutes or starts a configuration retry loop',flush=True)
 # Our own Sync Source write survives a failed readback: when the next
 # attempt is rejected, it is still undone once.
 before=counts();(root/'write-then-unreadable').write_text('1');(root/'configure-fail').write_text('2')
 preset['sampleRate']=48000;save()
 wait(lambda s:s['running'] and 'Hardware restored to 96000' in s['message'],15)
 assert status()['rate']==96000 and float((root/'hardware-rate').read_text())==96000 and counts()==before,(status(),counts())
 (root/'configure-fail').unlink();preset['sampleRate']=96000;save()
 wait(lambda s:s['running'] and 'previous configuration remains active' not in s['message'])
 print('PASS: an own Sync Source write with failed readback is still undone once when the change is rejected',flush=True)
 # A locked interface changed elsewhere is not set back by an unrelated change.
 (root/'secondary-rate').write_text('44100')
 wait(lambda s:s['running'] and 'Test secondary runs at 44100' in s['message'],10)
 rates=(root/'events').read_text().count('rate');starts=counts()[0]
 preset['outputCount']=3;save()
 wait(lambda s:s['running'] and counts()[0]==starts+1 and json.loads((root/'started.json').read_text())['outputCount']==3,15)
 time.sleep(1.5)
 assert (root/'events').read_text().count('rate')==rates,'an unrelated change touched hardware rates'
 assert 'Test secondary runs at 44100' in status()['message'],status()['message']
 (root/'secondary-rate').write_text('96000');preset['outputCount']=2;save()
 wait(lambda s:s['running'] and 'not in sync' not in s['message'] and json.loads((root/'started.json').read_text())['outputCount']==2,15)
 print('PASS: an unrelated configuration change does not set back a locked interface changed elsewhere',flush=True)
 # Fan-out names follow the active preset's order, not inventory enumeration.
 preset['devices'].reverse()
 preset['outputs']=[{'virtualChannel':1,'deviceUID':'mock','channel':1},{'virtualChannel':1,'deviceUID':'secondary','channel':1}];save()
 wait(lambda s:json.loads((root/'names.json').read_text())['outputs'][0].startswith('Test secondary'))
 label=json.loads((root/'names.json').read_text())['outputs'][0]
 assert label.index('Test secondary')<label.index('Test master'),label
 print('PASS: fan-out channel names preserve active preset interface order',flush=True)
 # HAL completes after 100 ms; confirmation must not wait a one-second tick.
 (root/'configure-delay').write_text('1');preset['outputCount']=3;save()
 wait(lambda s:s['running'] and (root/'configure-elapsed').exists() and json.loads((root/'started.json').read_text())['outputCount']==3)
 assert float((root/'configure-elapsed').read_text())<.75
 print('PASS: a completed HAL request is followed promptly between regular status heartbeats',flush=True)
 # A never-ready HAL request gets a short fast burst, then normal polling.
 # Expiry must neither cancel the request nor stop the old audio.
 before=counts();(root/'configure-pending').write_text('1');preset['outputCount']=4;save()
 wait(lambda s:s['running'] and 'not yet confirmed' in s['message'])
 time.sleep(1.5)
 polls=(root/'events').read_text().splitlines().count('configure');time.sleep(4)
 later=(root/'events').read_text().splitlines().count('configure')-polls
 assert 2<=later<=6,('late pending polls over four seconds',later)
 assert counts()==before and available()
 (root/'configure-pending').unlink()
 wait(lambda s:s['running'] and counts()[0]==before[0]+1 and json.loads((root/'started.json').read_text())['outputCount']==4)
 print('PASS: a never-ready HAL transaction falls back to normal polling and can still complete later without an audio stop during the wait',flush=True)
 # The first clock block arrives after 100 ms: publish promptly, not at the
 # next one-second heartbeat, without reconfiguring or restarting the engine.
 before=counts();(root/'clock-delay').write_text('1')
 preset.update(virtualDeviceUID='se.studiopatch.preset.delayed-clock',virtualDeviceName='StudioPatch (Delayed clock)');save()
 wait(lambda s:s['running'] and available() and (root/'publication-elapsed').exists())
 assert float((root/'publication-elapsed').read_text())<.75
 assert counts()==(before[0]+1,before[1]+1,before[2])
 print('PASS: a newly started engine publishes promptly when its first clock arrives',flush=True)
 # Publication uses the same finite burst. A persistently missing clock does
 # not busy-poll, restart, or time out the already running engine.
 (root/'clock-not-ready').write_text('1')
 preset.update(virtualDeviceUID='se.studiopatch.preset.waiting-clock',virtualDeviceName='StudioPatch (Waiting clock)');save()
 wait(lambda s:s['running'] and not available() and 'Waiting for the hardware clock' in s['message'])
 before=counts();time.sleep(1.5)
 checks=(root/'events').read_text().splitlines().count('publish-check');time.sleep(4)
 later=(root/'events').read_text().splitlines().count('publish-check')-checks
 assert 2<=later<=6,('late publication checks over four seconds',later)
 assert counts()==before and not available()
 (root/'clock-not-ready').unlink();wait(lambda s:s['running'] and available())
 assert counts()==before
 print('PASS: an unavailable first clock returns to normal publication polling without stopping or restarting audio',flush=True)
 # Presentation tracks running, compensated paths rather than the checkbox.
 (root/'secondary-present').write_text('1');(root/'secondary-rate').write_text('96000')
 preset.update(virtualDeviceUID='se.studiopatch.preset.status',sampleRate=96000,inputCount=2,outputCount=2,
               inputs=[{'deviceUID':'mock','channel':1},None],outputs=[],
               devices=[{'uid':'mock','drift':False},{'uid':'secondary','drift':False,'syncLocked':False}]);save()
 wait(lambda s:s['running'] and s['health']=='healthy' and json.loads((root/'names.json').read_text())['uid']==preset['virtualDeviceUID'],15)
 before=counts();notes_before=len(notifications());(root/'secondary-rate').write_text('44100')
 wait(lambda s:s['health']=='warning' and 'not in sync' in s['message'],10)
 assert counts()==before and [n['id'] for n in notifications()[notes_before:]]==['sync-mismatch']
 print('PASS: uncompensated mismatch is orange even with sync lock off, without touching audio',flush=True)
 assert [n['id'] for n in visible_problems()]==['sync-mismatch']
 (root/'status-fail').write_text('1')
 wait(lambda s:'Engine status unavailable' in s['message'])
 assert [n['id'] for n in visible_problems()]==['sync-mismatch'] # unknown is not resolved
 (root/'status-fail').unlink()
 (root/'secondary-rate').write_text('96000');wait(lambda s:s['health']=='healthy',10)
 assert visible_problems()==[],visible_problems()
 recurrence=len(notifications());(root/'secondary-rate').write_text('44100')
 wait(lambda s:s['health']=='warning' and 'not in sync' in s['message'],10)
 assert len(notifications())==recurrence+1 and [n['id'] for n in visible_problems()]==['sync-mismatch']
 assert counts()==before
 print('PASS: resolved notifications disappear on green, remain on unknown status, and notify again on recurrence',flush=True)

 # Use a structural edit too: the fake routing operation intentionally accepts
 # all live updates; the real engine classifies drift changes as graph changes.
 preset['devices'][1]['drift']=True;preset['outputCount']=3;notes_before=len(notifications());save()
 wait(lambda s:s['running'] and s['health']=='healthy' and json.loads((root/'started.json').read_text())['outputCount']==3,15)
 assert 'not in sync' not in status()['message'] and len(notifications())==notes_before
 assert visible_problems()==[],visible_problems()
 before=counts();(root/'secondary-rate').write_text('48000');time.sleep(6)
 assert status()['health']=='healthy' and 'not in sync' not in status()['message'] and counts()==before and len(notifications())==notes_before
 # Even a refused rate-follow request is not a fault in a running compensated path.
 (root/'locked-refuses').write_text('1');preset['devices'][1]['syncLocked']=True;preset['sampleRate']=88200;save()
 wait(lambda s:s['running'] and s['rate']==88200 and s['health']=='healthy',15)
 assert 'does not support' not in status()['message'] and 'not in sync' not in status()['message'] and len(notifications())==notes_before
 print('PASS: active drift compensation suppresses mismatch text and notifications, including a refused secondary rate follow',flush=True)
 (root/'locked-refuses').unlink()
 # The checkbox must not hide a secondary that failed to start, even at the same rate.
 (root/'secondary-rate').write_text('88200');(root/'compensation-start-fail').write_text('1')
 preset['outputCount']=4;save()
 wait(lambda s:s['running'] and s['health']=='warning' and 'secondary was not started' in s['message'],15)
 before=counts();time.sleep(2);assert counts()==before and available()
 print('PASS: a requested but failed compensated path stays orange with a startup warning while the master runs',flush=True)
 (root/'compensation-start-fail').unlink();preset['outputCount']=3;save()
 wait(lambda s:s['running'] and s['health']=='healthy',15)
 before=counts();(root/'status-fail').write_text('1')
 wait(lambda s:s['health']=='warning' and 'Engine status unavailable' in s['message'])
 assert counts()==before
 (root/'status-fail').unlink();wait(lambda s:s['health']=='healthy')
 print('PASS: unreadable status is orange without stopping audio and clears when reads recover',flush=True)
 (root/'start-reject').write_text('4');preset['outputCount']=4;save()
 wait(lambda s:not s['running'] and s['health']=='error' and 'start failure' in s['message'],15)
 assert available()
 (root/'start-reject').unlink();wait(lambda s:s['running'] and s['health']=='healthy',15)
 assert visible_problems()==[],visible_problems()
 print('PASS: a failed applied configuration is red and its notification clears when the existing retry succeeds',flush=True)
 # Empty selection is intentional idle, not an audio error.
 configured=json.loads(json.dumps(preset));preset['devices']=[];save()
 wait(lambda s:not s['running'] and s['health']=='idle')
 preset=configured;save();wait(lambda s:s['running'] and s['health']=='healthy',15)
 assert [n['id'] for n in visible_notifications()]==['unrelated-note']
 print('PASS: no active configuration is gray; notification cleanup leaves unrelated identifiers alone',flush=True)
 # A new service starting with missing hardware never publishes a placeholder.
 offline=root/'offline-start';offline.mkdir()
 (offline/'last-session.json').write_text(json.dumps(preset));(offline/'disconnected').write_text('1')
 if any(d['uid']=='secondary' for d in preset['devices']):(offline/'secondary-present').write_text('1')
 offline_process=subprocess.Popen([executable],env=dict(env,STUDIOPATCH_TEST_DIRECTORY=str(offline)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  end=time.time()+10
  while not (offline/'availability').exists() and time.time()<end:time.sleep(.1)
  assert (offline/'availability').read_text()=='0'
  assert not (offline/'notifications.jsonl').exists()
  (offline/'disconnected').unlink()
  end=time.time()+12
  while (offline/'availability').read_text()!='1' and time.time()<end:time.sleep(.1)
  assert (offline/'availability').read_text()=='1'
  time.sleep(1)
  assert not (offline/'notifications.jsonl').exists() # neither start nor publication is a problem
  print('PASS: offline startup stays absent until hardware and engine are ready',flush=True)
 finally:
  offline_process.terminate();offline_process.communicate(timeout=5)
finally:
 p.terminate();out,err=p.communicate(timeout=5)
 if err:print(err.decode())
