import os,json,time,subprocess,pathlib,tempfile,sys
base=pathlib.Path(sys.argv[1]).resolve();exe=base/'runtime-test-service';results=[]
for case in ['broker-failure-before-change','rate-after-restore']:
 root=pathlib.Path(tempfile.mkdtemp(prefix=case+'-',dir=base))
 preset={'inputCount':2,'outputCount':2,'sampleRate':96000,'bufferFrames':64,'delayFrames':256,'masterUID':'mock','devices':[{'uid':'mock','drift':False}],'inputs':[{'deviceUID':'mock','channel':1},None],'outputs':[]}
 def save():
  p=root/'next.json';p.write_text(json.dumps(preset));p.replace(root/'last-session.json')
 def state():
  try:return json.loads((root/'runtime-status.json').read_text())
  except (FileNotFoundError,json.JSONDecodeError):return {}
 def wait(fn,timeout=10):
  end=time.monotonic()+timeout
  while time.monotonic()<end:
   s=state()
   if fn(s):return s
   time.sleep(.05)
  raise AssertionError((case,state(),(root/'events').read_text()))
 def counts():
  e=(root/'events').read_text().splitlines();return {k:e.count(k) for k in ['start','stop','rate','configure']}
 save();p=subprocess.Popen([str(exe)],env=dict(os.environ,STUDIOPATCH_TEST_DIRECTORY=str(root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  wait(lambda s:s.get('running'))
  if case=='broker-failure-before-change':
   (root/'configure-unavailable').write_text('1');preset['outputCount']=3;save()
   wait(lambda s:s.get('running') is False and 'broker unavailable' in s.get('message',''))
   time.sleep(2)
   assert state()['running'] is False and (root/'availability').read_text()=='1'
   result={'case':case,'counts':counts(),'available':(root/'availability').read_text(),'state':state()['message'],'applied_hardware_change':False}
  else:
   (root/'rate-error').write_text('1');preset['sampleRate']=48000;save()
   wait(lambda s:s.get('running') and 'previous configuration remains active' in s.get('message',''))
   time.sleep(2)
   assert state()['rate']==48000 and any(d['uid']=='mock' and d['sampleRate']==96000 for d in state()['devices'])
   result={'case':case,'reported_rate':state()['rate'],'actual_running_rate':96000,'counts':counts(),'state':state()['message']}
  results.append(result);print(json.dumps(result),flush=True)
 finally:p.terminate();p.communicate(timeout=5)
(base/'runtime-results.json').write_text(json.dumps(results,indent=2))
