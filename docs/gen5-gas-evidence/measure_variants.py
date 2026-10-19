import json, urllib.request, glob, os
S="/private/tmp/claude-502/-Users-hamishludbrook-Documents-flowstate-workspace/9d13270c-f462-4ccb-a17f-636fe38b3ecc/scratchpad"
URL="http://127.0.0.1:8547"; HOOK="0x3f7C2bEA8cA39E7fd1E07B63294544369ef268cC"; UR="0x8876789976decbfcbbbe364623c63652db8c0904"; W="0xb221Ee086882D295B0EC67ffA2c66f2a69f52ca8"
DATA=open(f"{S}/canary2_input.hex").read().strip()
_id=0
def rpc(m,p=[]):
    global _id; _id+=1
    r=urllib.request.Request(URL,data=json.dumps({"jsonrpc":"2.0","id":_id,"method":m,"params":p}).encode(),headers={"content-type":"application/json"})
    o=json.loads(urllib.request.urlopen(r,timeout=600).read())
    if "error" in o: return {"error":o["error"]}
    return o["result"]
rpc("anvil_setCode",["0x0000000000000000000000000000000000000064","0x4360005260206000f3"])
rpc("anvil_setBalance",[W,hex(10**18)])
rpc("anvil_impersonateAccount",[W])
rpc("anvil_setBlockTimestampInterval",[1])
tx={"from":W,"to":UR,"data":DATA,"value":"0x0"}
def passes(gas):
    r=rpc("eth_call",[dict(tx,gas=hex(gas)),"latest"])
    return not isinstance(r,dict)
def min_limit(lo,hi):
    while hi-lo>1000:
        mid=(lo+hi)//2
        if passes(mid): hi=mid
        else: lo=mid
    return hi
rows=[]
for path in sorted(glob.glob(f"{S}/variant_*.hex")):
    name=os.path.basename(path)[8:-4]
    snap=rpc("evm_snapshot")
    code=open(path).read().strip()
    if name!="V0_ref": rpc("anvil_setCode",[HOOK,code])
    est=rpc("eth_estimateGas",[tx])
    if isinstance(est,dict): rows.append((name,"estimate failed: "+json.dumps(est)[:400])); rpc("evm_revert",[snap]); continue
    est=int(est,16)
    ml=min_limit(300_000,est+50_000)
    h=rpc("eth_sendTransaction",[dict(tx,gas=hex(est+20_000))])
    if isinstance(h,dict): rows.append((name,"send failed: "+str(h)[:200])); rpc("evm_revert",[snap]); continue
    rpc("evm_mine"); rc=rpc("eth_getTransactionReceipt",[h])
    if rc is None: rows.append((name,"no receipt for "+str(h))); rpc("evm_revert",[snap]); continue
    used=int(rc["gasUsed"],16); ok=rc["status"]=="0x1"
    rows.append((name,est,ml,used,ok,round(ml/used,3)))
    rpc("evm_revert",[snap])
print(f"{'variant':28} {'estimateGas':>12} {'min limit':>10} {'gas used':>9} ok  limit/used")
for r in rows:
    if len(r)==2: print(f"{r[0]:28} {r[1]}"); continue
    print(f"{r[0]:28} {r[1]:>12,} {r[2]:>10,} {r[3]:>9,} {str(r[4]):4} {r[5]}")
json.dump(rows,open(f"{S}/variant_results.json","w"))
