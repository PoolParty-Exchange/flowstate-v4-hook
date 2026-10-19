import json, subprocess, sys, copy, re
S="/private/tmp/claude-502/-Users-hamishludbrook-Documents-flowstate-workspace/9d13270c-f462-4ccb-a17f-636fe38b3ecc/scratchpad"
SOLC="/Users/hamishludbrook/Library/Application Support/svm/0.8.26/solc-0.8.26"
inp=json.load(open("/Users/hamishludbrook/Documents/flowstate-workspace/deployment-ledger/gen4_handoff_review_2026-10-13/hook_verification/FlowstateC1Hook.standard-input.json"))
inp["settings"]["outputSelection"]={"*":{"FlowstateC1Hook":["evm.deployedBytecode.object","evm.deployedBytecode.immutableReferences"]}}
HOOK=[k for k in inp["sources"] if k.endswith("src/FlowstateC1Hook.sol")][0]
live=open(f"{S}/hook_live_runtime.hex").read().strip()[2:]
CONSTS={"ATTEMPT":"GEN4_MIN_ATTEMPT_GAS = 800_000","RESERVE":"GEN4_FINALIZATION_GAS_RESERVE = 200_000","LEGBASE":"GEN4_POOL_LEG_BASE_GAS = 450_000","LISTMIN":"GEN4_LISTING_LEG_MIN_GAS = 800_000","RETURN":"GEN4_LEG_RETURN_GAS = 60_000"}
def compile(subs):
    d=copy.deepcopy(inp); src=d["sources"][HOOK]["content"]
    for k,v in subs.items():
        name,_=CONSTS[k].split(" = "); pat=re.escape(CONSTS[k])
        assert len(re.findall(pat,src))==1,(k)
        src=re.sub(pat,f"{name} = {v}",src)
    d["sources"][HOOK]["content"]=src
    r=subprocess.run([SOLC,"--standard-json"],input=json.dumps(d),capture_output=True,text=True)
    out=json.loads(r.stdout)
    errs=[e for e in out.get("errors",[]) if e["severity"]=="error"]
    assert not errs, errs[:2]
    c=out["contracts"][HOOK]["FlowstateC1Hook"]["evm"]["deployedBytecode"]
    return c["object"], c["immutableReferences"]
ref_code,ref_imm=compile({})
print("ref runtime bytes",len(ref_code)//2,"live",len(live)//2, "immutable ids",len(ref_imm))
# sanity: live vs ref differ only at immutables + metadata tail
diff=[i for i in range(0,min(len(ref_code),len(live)),2) if ref_code[i:i+2]!=live[i:i+2]]
imm_pos=set()
for _id,refs in ref_imm.items():
    for r in refs:
        for b in range(r["start"],r["start"]+r["length"]): imm_pos.add(b)
non_imm=[i//2 for i in diff if i//2 not in imm_pos]
print("diff bytes outside immutables:",len(non_imm),"first",non_imm[:3],"last",non_imm[-3:] if non_imm else None,"(metadata tail = last 53 bytes from",len(live)//2-53,")")
def fill(code,imm):
    code=bytearray.fromhex(code); liveb=bytes.fromhex(live)
    for _id,refs in imm.items():
        val=None
        for r in ref_imm[_id]:
            val=liveb[r["start"]:r["start"]+r["length"]]; break
        for r in refs:
            assert r["length"]==len(val)
            code[r["start"]:r["start"]+r["length"]]=val
    return code.hex()
variants={
 "W0_ref":{},
 "X_list800k":{"ATTEMPT":"300_000","LEGBASE":"250_000","RESERVE":"100_000","RETURN":"30_000","LISTMIN":"800_000"},
 "X_list600k":{"ATTEMPT":"300_000","LEGBASE":"250_000","RESERVE":"100_000","RETURN":"30_000","LISTMIN":"600_000"},
 "X_list500k":{"ATTEMPT":"300_000","LEGBASE":"250_000","RESERVE":"100_000","RETURN":"30_000","LISTMIN":"500_000"},
 "X_list400k":{"ATTEMPT":"300_000","LEGBASE":"250_000","RESERVE":"100_000","RETURN":"30_000","LISTMIN":"400_000"},
 "X_list350k":{"ATTEMPT":"300_000","LEGBASE":"250_000","RESERVE":"100_000","RETURN":"30_000","LISTMIN":"350_000"},
 "X_list300k":{"ATTEMPT":"300_000","LEGBASE":"250_000","RESERVE":"100_000","RETURN":"30_000","LISTMIN":"300_000"},
}
for name,subs in variants.items():
    code,imm=compile(subs)
    filled=fill(code,imm)
    open(f"{S}/variant_{name}.hex","w").write("0x"+filled)
    print(name,"bytes",len(filled)//2, "identical to live:", filled==live)
