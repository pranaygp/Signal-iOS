# Provisioning for a new extension bundle id through the App Store Connect API,
# for when Xcode has no Apple ID signed in (see QIULING.md, Safari extension).
#   set -a; source Config/qiuling.env; set +a
#   BID=gp.pranay.q.x BNAME="Qiuling X" uv run --with pyjwt --with cryptography python3 Scripts/qiuling-asc.py create
#   BID=gp.pranay.q.x PNAME="Qiuling X" BUNDLE_RID=<id from create> uv run --with pyjwt --with cryptography python3 Scripts/qiuling-asc.py profile IOS_APP_DEVELOPMENT
import jwt, time, json, os, sys, urllib.request, urllib.parse
KEY_ID=os.environ['ASC_KEY_ID']; ISS=os.environ['ASC_ISSUER_ID']; KEY=open(os.environ['ASC_KEY_PATH']).read()
tok=jwt.encode({'iss':ISS,'iat':int(time.time()),'exp':int(time.time())+1200,'aud':'appstoreconnect-v1'}, KEY, algorithm='ES256', headers={'kid':KEY_ID})
def api(method, path, body=None):
    req=urllib.request.Request('https://api.appstoreconnect.apple.com/v1/'+path, method=method, data=json.dumps(body).encode() if body else None,
        headers={'Authorization':'Bearer '+tok,'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req) as r: return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        print(method, path, e.code, e.read().decode()[:600]); raise
cmd=sys.argv[1]
import os as _o
BID=_o.environ.get('BID','gp.pranay.q.safari'); BNAME=_o.environ.get('BNAME','Qiuling Safari'); PNAME=_o.environ.get('PNAME','Qiuling Safari'); BUNDLE_RID=_o.environ.get('BUNDLE_RID','XY6B8XT89B')
if cmd=='inspect':
    for b in api('GET','bundleIds?filter[identifier]=gp.pranay.q&limit=50')['data']: print('bundle', b['id'], b['attributes']['identifier'], b['attributes']['name'])
    for c in api('GET','certificates?limit=50')['data']: print('cert', c['id'], c['attributes']['certificateType'], c['attributes']['name'], c['attributes']['serialNumber'])
    for d in api('GET','devices?limit=50')['data']: print('device', d['id'], d['attributes']['name'], d['attributes']['status'], d['attributes']['platform'])
    for p in api('GET','profiles?limit=50')['data']: print('profile', p['id'], p['attributes']['name'], p['attributes']['profileType'], p['attributes']['profileState'])
if cmd=='groups':
    for g in api('GET','appGroups?limit=50' if False else 'bundleIds/X2GB2L9Y97/bundleIdCapabilities')['data']: print(json.dumps(g)[:600])
if cmd=='create':
    existing=[b for b in api('GET','bundleIds?filter[identifier]=gp.pranay.q.safari')['data'] if b['attributes']['identifier']==BID]
    bid = existing[0]['id'] if existing else api('POST','bundleIds',{'data':{'type':'bundleIds','attributes':{'identifier':BID,'name':BNAME,'platform':'IOS'}}})['data']['id']
    print('bundleId', bid)
    caps=[c['attributes']['capabilityType'] for c in api('GET',f'bundleIds/{bid}/bundleIdCapabilities')['data']]
    print('caps', caps)
    if 'APP_GROUPS' not in caps:
        r=api('POST','bundleIdCapabilities',{'data':{'type':'bundleIdCapabilities','attributes':{'capabilityType':'APP_GROUPS'},'relationships':{'bundleId':{'data':{'type':'bundleIds','id':bid}}}}})
        print('added APP_GROUPS', json.dumps(r['data']['attributes']))
    # try to see app groups relationship
    try:
        print(json.dumps(api('GET',f'bundleIds/{bid}?include=bundleIdCapabilities'))[:800])
    except Exception as e: print('inc', e)
if cmd=='profile':
    import base64, subprocess
    ptype=sys.argv[2]  # IOS_APP_DEVELOPMENT or IOS_APP_STORE
    name = PNAME + ' ' + ('Development' if ptype=='IOS_APP_DEVELOPMENT' else 'Store')
    for p in api('GET','profiles?filter[name]='+urllib.parse.quote(name))['data']:
        api('DELETE','profiles/'+p['id']); print('deleted old', p['id'])
    certs=[c for c in api('GET','certificates?limit=50')['data'] if c['attributes']['certificateType']==('DEVELOPMENT' if ptype=='IOS_APP_DEVELOPMENT' else 'DISTRIBUTION')]
    body={'data':{'type':'profiles','attributes':{'name':name,'profileType':ptype},'relationships':{
        'bundleId':{'data':{'type':'bundleIds','id':BUNDLE_RID}},
        'certificates':{'data':[{'type':'certificates','id':c['id']} for c in certs]}}}}
    if ptype=='IOS_APP_DEVELOPMENT':
        body['data']['relationships']['devices']={'data':[{'type':'devices','id':d['id']} for d in api('GET','devices?limit=50')['data']]}
    r=api('POST','profiles',body)['data']
    content=base64.b64decode(r['attributes']['profileContent'])
    dest=os.path.expanduser(f"~/Library/Developer/Xcode/UserData/Provisioning Profiles/{r['attributes']['uuid']}.mobileprovision")
    open(dest,'wb').write(content); print('wrote', dest, r['attributes']['name'])
    ents=subprocess.run(['sh','-c',f'security cms -D -i "{dest}" | plutil -extract Entitlements json -o - -'],capture_output=True,text=True).stdout
    print(ents[:700])
if cmd=='probe':
    for path in ['appGroups?limit=5','bundleIds/XY6B8XT89B/relationships/appGroups','bundleIdCapabilities/XY6B8XT89B_APP_GROUPS?include=appGroups']:
        try: print(path, json.dumps(api('GET',path))[:400])
        except Exception as e: pass
if cmd=='probe2':
    for path in ['appGroups?limit=5','bundleIds/XY6B8XT89B/relationships/appGroups']:
        try: print(path, json.dumps(api('GET',path))[:400])
        except Exception as e: print('ERR', path)
    # try PATCH capability with settings pointing at app groups
    try:
        r=api('PATCH','bundleIdCapabilities/XY6B8XT89B_APP_GROUPS',{'data':{'type':'bundleIdCapabilities','id':'XY6B8XT89B_APP_GROUPS','attributes':{'capabilityType':'APP_GROUPS'},'relationships':{'appGroups':{'data':[{'type':'appGroups','id':'group.gp.pranay.signal.group'}]}}}})
        print('patched', json.dumps(r)[:300])
    except Exception as e: print('patch ERR')
