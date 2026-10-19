import json, urllib.request, glob, os, sys
S="/private/tmp/claude-502/-Users-hamishludbrook-Documents-flowstate-workspace/9d13270c-f462-4ccb-a17f-636fe38b3ecc/scratchpad"
URL="http://127.0.0.1:8547"; HOOK="0x3f7C2bEA8cA39E7fd1E07B63294544369ef268cC"
label,frm,to,data,value=sys.argv[1:6]
_id=0
def rpc(m,p=[]):
    global _id; _id+=1
    r=urllib.request.Request(URL,data=json.dumps({"jsonrpc":"2.0","id":_id,"method":m,"params":p}).encode(),headers={"content-type":"application/json"})
    o=json.loads(urllib.request.urlopen(r,timeout=600).read())
    return {"error":o["error"]} if "error" in o else o["result"]
rpc("anvil_setCode",["0x0000000000000000000000000000000000000064","0x4360005260206000f3"])
rpc("anvil_setBalance",[frm,hex(10**18)]); rpc("anvil_impersonateAccount",[frm])
tx={"from":frm,"to":to,"data":data,"value":hex(int(value))}
def passes(gas):
    r=rpc("eth_call",[dict(tx,gas=hex(gas)),"latest"]); return not isinstance(r,dict)
def min_limit(lo,hi):
    while hi-lo>1000:
        mid=(lo+hi)//2
        if passes(mid): hi=mid
        else: lo=mid
    return hi
SELLER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; TOKEN="0x020bfc650a365f8bb26819deaabf3e21291018b4"
def bal(a):
    r=rpc("eth_call",[{"to":TOKEN,"data":"0x70a08231"+a[2:].lower().rjust(64,"0")},"latest"]); return int(r,16)
rows=[]  # SELLER_CHECK
for path in sorted(sorted(glob.glob(f"{S}/variant_W0_ref.hex")+glob.glob(f"{S}/variant_X_*.hex"))):
    name=os.path.basename(path)[8:-4]; snap=rpc("evm_snapshot")
    if name!="W0_ref": rpc("anvil_setCode",[HOOK,open(path).read().strip()])
    b0=bal(SELLER); est=rpc("eth_estimateGas",[tx])
    if isinstance(est,dict): rows.append((name,"estimate failed: "+json.dumps(est)[:300])); rpc("evm_revert",[snap]); continue
    est=int(est,16); ml=min_limit(300_000,est+50_000)
    h=rpc("eth_sendTransaction",[dict(tx,gas=hex(est+20_000))])
    if isinstance(h,dict): rows.append((name,"send failed")); rpc("evm_revert",[snap]); continue
    rpc("evm_mine"); rc=rpc("eth_getTransactionReceipt",[h])
    used=int(rc["gasUsed"],16); sold=(b0-bal(SELLER))/1e18; rows.append((name,est,ml,used,rc["status"]=="0x1",round(ml/used,3),sold)); rpc("evm_revert",[snap])
print(f"== {label}"); print(f"{'variant':34} {'estimateGas':>12} {'min limit':>10} {'gas used':>9} ok  limit/used")
for r in rows:
    print(f"{r[0]:34} {r[1]:>12,} {r[2]:>10,} {r[3]:>9,} {str(r[4]):4} {r[5]}  seller sold {r[6]:.4f} CASHCAT" if len(r)>2 else f"{r[0]:34} {r[1]}")
json.dump(rows,open(f"{S}/variant_results_{label}.json","w"))
