import json
from run_lua import runtime, req

def dev(ui, cmds, states=(), url="io://1234-5678-9012/1", label="Shade"):
    return {"deviceURL": url, "label": label, "uiClass": ui, "available": True,
            "definition": {"uiClass": ui, "commands": [{"commandName": c} for c in cmds]},
            "states": [{"name": n, "value": v} for n, v in states]}

def load():
    lua = runtime()
    j = req(lua, "st.json"); m = req(lua, "tahoma_model")
    return lua, j, m

def L(j, obj): return j.decode(json.dumps(obj).encode())

def test_kinds_and_levels():
    lua, j, m = load()
    shutter = L(j, dev("RollerShutter", ["open", "close", "stop", "my", "setClosure"], [("core:ClosureState", 30)]))
    awning = L(j, dev("Awning", ["deploy", "undeploy", "stop", "my", "setDeployment"], [("core:DeploymentState", 80)]))
    rts = L(j, dev("RollerShutter", ["open", "close", "my", "stop"]))
    other = L(j, dev("Light", ["on", "off"]))
    assert m.kind(shutter) == b"closure" and m.kind(awning) == b"deployment" and m.kind(rts) == b"rts"
    assert m.kind(other) is None
    assert m.level(shutter, b"closure", False) == 70 and m.level(shutter, b"closure", True) == 30
    assert m.level(awning, b"deployment", False) == 20
    assert m.level(rts, b"rts", False) is None
    assert m.shade_state(100) == b"open" and m.shade_state(0) == b"closed" and m.shade_state(40) == b"partially open"

def cmd(c):
    return [(x[b"name"], list(x[b"parameters"].values()) if x[b"parameters"] else []) for x in c.values()]

def test_commands():
    lua, j, m = load()
    shutter = L(j, dev("RollerShutter", ["open", "close", "stop", "my", "setClosure"], [("core:ClosureState", 0)]))
    assert cmd(m.commands(shutter, b"closure", b"level", 25, False)) == [(b"setClosure", [75])]
    assert cmd(m.commands(shutter, b"closure", b"open", None, False)) == [(b"setClosure", [0])]
    assert cmd(m.commands(shutter, b"closure", b"close", None, True)) == [(b"setClosure", [0])]
    assert cmd(m.commands(shutter, b"closure", b"stop", None, False)) == [(b"stop", [])]
    awning = L(j, dev("Awning", ["deploy", "undeploy", "my", "setDeployment"]))
    assert cmd(m.commands(awning, b"deployment", b"close", None, False)) == [(b"setDeployment", [100])]
    rts = L(j, dev("ExteriorScreen", ["up", "down", "my"]))
    assert cmd(m.commands(rts, b"rts", b"open", None, False)) == [(b"up", [])]
    assert cmd(m.commands(rts, b"rts", b"level", 10, False)) == [(b"down", [])]
    assert cmd(m.commands(rts, b"rts", b"open", None, True)) == [(b"down", [])]
    assert cmd(m.commands(rts, b"rts", b"stop", None, False)) == [(b"my", [])]
    body = m.exec_body(b"io://x/1", m.commands(rts, b"rts", b"my", None, False))
    out = json.loads(j.encode(body))
    assert out == {"label": "SmartThings", "actions": [{"deviceURL": "io://x/1", "commands": [{"name": "my"}]}]}

def test_shades_filter():
    lua, j, m = load()
    devs = L(j, [dev("RollerShutter", ["setClosure"], [("core:ClosureState", 0)], url="io://a/1"),
                 dev("Pod", ["refresh"], url="internal://a/pod/0"),
                 dev("Awning", ["setDeployment"], url="io://a/2")])
    s = m.shades(devs)
    assert len(s) == 2
