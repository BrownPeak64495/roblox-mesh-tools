bl_info = {
    "name": "Roblox Mesh Tools - Send to Studio",
    "author": "BrownPeak64495",
    "version": (1, 5, 0),
    "blender": (3, 0, 0),
    "location": "3D View > Sidebar (N) > Roblox",
    "description": "Sends meshes (with bones) straight into Roblox Studio as local .mesh files (no upload) through Mesh Downloader",
    "category": "Import-Export",
}

# How it works
#   1. Your object is turned into a Roblox .mesh file right here in Blender.
#      - no armature: version 2.00 (shape + texture coords)
#      - with an armature: version 7.00 with the bones and weights (same layout
#        Roblox's own dynamic head uses)
#   2. It's sent to Mesh Downloader on this PC (http://localhost:47820), which saves it
#      and copies it into Studio's content folder.
#   3. The Mesh Tools plugin in Studio picks it up and makes a real MeshPart using
#      rbxasset://meshtools/<id>.mesh - in the same spot as in Blender - and builds
#      the Bones inside it.
#   Sending the same object again updates the part that's already in Studio.
#   Posing the armature with Live on moves the Bones in Studio (no resend needed).
#   Nothing is uploaded to Roblox.

import hashlib
import json
import os
import struct
import tempfile
import time
import urllib.error
import urllib.request

import bpy
import numpy as np
from bpy.app.handlers import persistent

KEY_PROP = "roblox_mesh_key"   # stored on each object you send, so resends update the same part
MAX_SUBSET_BONES = 26          # Roblox limit: bones per mesh section
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # never route localhost through a proxy

_state = {
    "status": "Not sent yet",
    "connected": None,
    "dirty": set(),          # objects whose mesh needs resending
    "pose_dirty": set(),     # objects whose pose needs resending
    "last_change": 0.0,
    "busy": False,
    "sent": {},              # object key -> info needed to send poses (bones, centre, scale ...)
}


# ------------------------------------------------------------------ talking to Mesh Downloader
def _url(props, path):
    return "http://localhost:%d%s" % (props.port, path)


def _post(props, path, meta, payload=b""):
    # body = [4-byte length][JSON][raw bytes]
    j = json.dumps(meta, separators=(",", ":")).encode("utf-8")
    body = struct.pack("<I", len(j)) + j + payload
    req = urllib.request.Request(_url(props, path), data=body, method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    try:
        with _opener.open(req, timeout=10) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read().decode("utf-8"))
        except Exception:
            data = {"ok": False, "error": "HTTP %d" % e.code}
    except Exception as e:
        _state["connected"] = False
        raise RuntimeError("Mesh Downloader isn't open (or the Studio link is off). " + str(getattr(e, "reason", e)))
    _state["connected"] = True
    return data


# ------------------------------------------------------------------ axes
def _axis_matrix(props):
    # Blender is Z-up, Roblox is Y-up, and Roblox's own character meshes face -Z.
    #   Face Roblox's front (default): (x, y, z) -> (-x, z, y)   Blender's front (-Y) -> -Z
    #   off (plain FBX export):         (x, y, z) -> (x, z, -y)
    # Both are rotations, so nothing gets mirrored.
    if props.turn_around:
        return np.array([[-1, 0, 0], [0, 0, 1], [0, 1, 0]], dtype=np.float64)
    return np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], dtype=np.float64)


def _corner_normals(me):
    n = len(me.loops)
    out = np.empty(n * 3, dtype=np.float32)
    if hasattr(me, "corner_normals"):           # Blender 4.1+
        me.corner_normals.foreach_get("vector", out)
    else:                                       # Blender 3.x - 4.0
        me.calc_normals_split()
        me.loops.foreach_get("normal", out)
    return out.reshape(n, 3)


def find_armature(obj):
    for mod in obj.modifiers:
        if mod.type == "ARMATURE" and mod.object is not None and mod.show_viewport:
            return mod.object
    if obj.parent is not None and obj.parent.type == "ARMATURE" and obj.parent_type == "ARMATURE":
        return obj.parent
    return None


def _bone_order(arm):
    # parents always before their children
    order = []
    def walk(b):
        order.append(b)
        for c in b.children:
            walk(c)
    for b in arm.data.bones:
        if b.parent is None:
            walk(b)
    return order


# ------------------------------------------------------------------ mesh data
def _read_mesh(obj, depsgraph, props, arm, want_tangents=False):
    """Corner-level data in Blender world space (+ per-corner bone weights when skinned,
    + tangents for normal maps)."""
    src = obj.evaluated_get(depsgraph) if props.apply_modifiers else obj
    me = src.to_mesh()
    try:
        me.calc_loop_triangles()
        nt = len(me.loop_triangles)
        if nt == 0:
            raise RuntimeError("'%s' has no faces" % obj.name)
        tri_loops = np.empty(nt * 3, dtype=np.int32)
        me.loop_triangles.foreach_get("loops", tri_loops)
        loop_verts = np.empty(len(me.loops), dtype=np.int32)
        me.loops.foreach_get("vertex_index", loop_verts)
        co = np.empty(len(me.vertices) * 3, dtype=np.float32)
        me.vertices.foreach_get("co", co)
        co = co.reshape(-1, 3)
        cn = _corner_normals(me)
        uv_layer = me.uv_layers.active
        if uv_layer is not None:
            uv = np.empty(len(me.loops) * 2, dtype=np.float32)
            uv_layer.data.foreach_get("uv", uv)
            uv = uv.reshape(-1, 2)
        else:
            uv = np.zeros((len(me.loops), 2), dtype=np.float32)

        tan = None
        if want_tangents and uv_layer is not None:
            try:
                me.calc_tangents(uvmap=uv_layer.name)
                t = np.empty(len(me.loops) * 3, dtype=np.float32)
                me.loops.foreach_get("tangent", t)
                sgn = np.empty(len(me.loops), dtype=np.float32)
                me.loops.foreach_get("bitangent_sign", sgn)
                tan = (t.reshape(-1, 3), sgn)
            except Exception:
                tan = None

        weights = None
        if arm is not None:
            group_names = [g.name for g in obj.vertex_groups]
            weights = [list() for _ in range(len(me.vertices))]
            for v in me.vertices:
                w = weights[v.index]
                for g in v.groups:
                    if g.weight > 0 and g.group < len(group_names):
                        w.append((group_names[g.group], g.weight))
    finally:
        src.to_mesh_clear()

    m = np.array(obj.matrix_world, dtype=np.float64)
    m3 = m[:3, :3]
    corner_v = loop_verts[tri_loops]
    pos = co[corner_v].astype(np.float64) @ m3.T + m[:3, 3]
    try:
        nm = np.linalg.inv(m3).T
    except np.linalg.LinAlgError:
        nm = m3
    nrm = cn[tri_loops].astype(np.float64) @ nm.T
    length = np.linalg.norm(nrm, axis=1, keepdims=True)
    length[length == 0] = 1
    nrm /= length
    tuv = uv[tri_loops].astype(np.float64)
    mirrored = np.linalg.det(m3) < 0
    # tangent (x, y, z) + sign: normal maps need them. Stored like Roblox does: (value + 1) * 127
    tng = np.zeros((len(tri_loops), 4), dtype=np.float64)
    if tan is not None:
        t = tan[0][tri_loops].astype(np.float64) @ m3.T
        ln = np.linalg.norm(t, axis=1, keepdims=True)
        ln[ln == 0] = 1
        tng[:, 0:3] = t / ln
        tng[:, 3] = tan[1][tri_loops] * (-1 if mirrored else 1)
    return pos, nrm, tuv, tng, corner_v, weights, mirrored


def _skin_table(weights, bone_index, fallback):
    """Per Blender vertex: 4 bone indices + 4 weights (0-255, adding up to 255), strongest first."""
    n = len(weights)
    idx = np.zeros((n, 4), dtype=np.int32)
    wts = np.zeros((n, 4), dtype=np.int32)
    over = 0
    for i, w in enumerate(weights):
        w = [(bone_index[name], val) for name, val in w if name in bone_index]
        if not w:
            idx[i, 0], wts[i, 0] = fallback, 255
            continue
        if len(w) > 4:
            over += 1
        w.sort(key=lambda t: -t[1])
        w = w[:4]                                  # Roblox: up to 4 bones per vertex
        total = sum(v for _, v in w)
        q = [int(round(v / total * 255)) for _, v in w]
        q[0] += 255 - sum(q)                       # exact total of 255
        for k, (b, _) in enumerate(w):
            idx[i, k], wts[i, k] = b, q[k]
    return idx, wts, over


def build_mesh(obj, depsgraph, props, normal_map=False):
    """Returns (bytes, info). info: center, size, verts, tris, bones (or None), over4."""
    arm = find_armature(obj) if props.send_bones else None
    if arm is not None:
        # read the mesh in the armature's rest pose (bind pose)
        old = arm.data.pose_position
        arm.data.pose_position = "REST"
        bpy.context.view_layer.update()
        try:
            pos, nrm, tuv, tng, corner_v, weights, mirrored = _read_mesh(obj, bpy.context.evaluated_depsgraph_get(), props, arm, True)
        finally:
            arm.data.pose_position = old
            bpy.context.view_layer.update()
    else:
        pos, nrm, tuv, tng, corner_v, weights, mirrored = _read_mesh(obj, depsgraph, props, None, normal_map)

    ax = _axis_matrix(props)
    pos = (pos @ ax.T) * props.studs_per_meter
    nrm = nrm @ ax.T
    tng[:, 0:3] = tng[:, 0:3] @ ax.T
    if props.flip_v:
        tuv[:, 1] = 1.0 - tuv[:, 1]

    # columns: 0-2 position, 3-5 normal, 6-7 uv, 8-11 tangent, 12-15 bone ids, 16-19 weights
    cols = [np.round(pos, 5), np.round(nrm, 4), np.round(tuv, 5), np.round(tng, 3)]
    bones = None
    over = 0
    if arm is not None:
        order = _bone_order(arm)
        bone_index = {b.name: i for i, b in enumerate(order)}
        sidx, swts, over = _skin_table(weights, bone_index, 0)
        cols += [sidx[corner_v].astype(np.float64), swts[corner_v].astype(np.float64)]
    rows = np.ascontiguousarray(np.hstack(cols))
    keyed = rows.view(np.dtype((np.void, rows.dtype.itemsize * rows.shape[1]))).ravel()
    _, first, inverse = np.unique(keyed, return_index=True, return_inverse=True)
    verts = rows[first]
    faces = inverse.ravel().reshape(-1, 3).astype(np.int64)

    flip = props.flip_faces != bool(mirrored)       # negative scale turns faces inside out - undo that
    if flip:
        faces = faces[:, [0, 2, 1]]

    lo = verts[:, 0:3].min(axis=0)
    hi = verts[:, 0:3].max(axis=0)
    center = (lo + hi) / 2.0
    verts[:, 0:3] -= center
    info = {"center": [float(c) for c in center], "size": [float(s) for s in (hi - lo)], "over4": over}

    if arm is None and not normal_map:
        data = _write_v2(verts, faces)
    elif arm is None:
        data, _, _ = _write_v7(verts, faces, None)     # normal map: needs tangents, which 2.00 can't hold
    else:
        aw = np.array(arm.matrix_world, dtype=np.float64)
        bones = []
        for i, b in enumerate(order):
            head = aw[:3, :3] @ np.array(b.head_local) + aw[:3, 3]
            p = (ax @ head) * props.studs_per_meter - center
            parent = bone_index[b.parent.name] if b.parent else -1
            bones.append({"n": b.name, "p": parent, "x": float(p[0]), "y": float(p[1]), "z": float(p[2])})
        data, _, _ = _write_v7(verts, faces, bones)
        info["arm"] = arm.name
        info["bones"] = bones
        info["order"] = [b.name for b in order]
        info["ax"] = ax.tolist()
        info["scale"] = props.studs_per_meter
    info["verts"] = int(len(verts))
    info["tris"] = int(len(faces))
    return data, info


_VDT = np.dtype([("p", "<f4", 3), ("n", "<f4", 3), ("uv", "<f4", 2), ("t", "u1", 4), ("c", "u1", 4)])


def _write_v2(verts, faces):
    # version 2.00: header (12 bytes), vertices (40 bytes: pos, normal, uvw, colour), faces (3 x uint32)
    nv = len(verts)
    vdt = np.dtype([("p", "<f4", 3), ("n", "<f4", 3), ("uv", "<f4", 3), ("c", "u1", 4)])
    va = np.zeros(nv, dtype=vdt)
    va["p"] = verts[:, 0:3]
    va["n"] = verts[:, 3:6]
    va["uv"][:, 0:2] = verts[:, 6:8]
    va["c"] = 255
    header = b"version 2.00\n" + struct.pack("<HBBII", 12, 40, 12, nv, len(faces))
    return header + va.tobytes() + faces.astype("<u4").tobytes()


def _chunk(name, version, payload):
    return name.ljust(8, b"\0") + struct.pack("<II", version, len(payload)) + payload


def _tangent_bytes(t):
    return np.clip(np.round((t + 1.0) * 127.0), 0, 254).astype(np.uint8)


def _write_v7(verts, faces, bones):
    """version 7.00 with COREMESH (uncompressed), LODS and SKINNING (when bones) - tested in
    Studio with Roblox's own dynamic head rebuilt this way."""
    if not bones:
        nv, nf = len(verts), len(faces)
        va = np.zeros(nv, dtype=_VDT)
        va["p"] = verts[:, 0:3]
        va["n"] = verts[:, 3:6]
        va["uv"] = verts[:, 6:8]
        va["t"] = _tangent_bytes(verts[:, 8:12])
        va["c"] = 255
        core = struct.pack("<I", nv) + va.tobytes() + struct.pack("<I", nf) + faces.astype("<u4").tobytes()
        lods = struct.pack("<HBI", 0, 1, 2) + struct.pack("<II", 0, nf)
        return (b"version 7.00\n" + _chunk(b"COREMESH", 1, core) + _chunk(b"LODS", 1, lods)), nv, nf
    skin_idx = verts[:, 12:16].astype(np.int64)
    skin_w = verts[:, 16:20].astype(np.int64)

    # Roblox needs the mesh in sections of at most 26 bones each
    face_bones = []
    for f in faces:
        s = set()
        for v in f:
            for k in range(4):
                if skin_w[v, k] > 0:
                    s.add(int(skin_idx[v, k]))
        face_bones.append(s)
    dominant = np.array([skin_idx[f[0], 0] for f in faces])
    order = np.argsort(dominant, kind="stable")      # faces of the same bone stay together
    groups = []
    cur, cur_set = [], set()
    for fi in order:
        s = face_bones[fi]
        if cur and len(cur_set | s) > MAX_SUBSET_BONES:
            groups.append((cur, cur_set))
            cur, cur_set = [], set()
        cur.append(fi)
        cur_set |= s
    if cur:
        groups.append((cur, cur_set))

    out_v, out_f, out_s, subsets = [], [], [], []
    sub_global = []        # per output vertex: its section's bone list
    vbase = fbase = 0
    for flist, bset in groups:
        blist = sorted(bset)
        local = {b: i for i, b in enumerate(blist)}
        gf = faces[np.array(flist)]
        used, remap = np.unique(gf.ravel(), return_inverse=True)
        out_v.append(verts[used])
        out_f.append(remap.reshape(-1, 3) + vbase)
        si = np.zeros((len(used), 8), dtype=np.uint8)
        for r, v in enumerate(used):
            for k in range(4):
                if skin_w[v, k] > 0:
                    si[r, k] = local[int(skin_idx[v, k])]
                    si[r, 4 + k] = skin_w[v, k]
        out_s.append(si)
        sub_global.extend([blist] * len(used))
        subsets.append((fbase, len(gf), vbase, len(used), blist))
        vbase += len(used)
        fbase += len(gf)
    V = np.vstack(out_v)
    F = np.vstack(out_f).astype("<u4")
    S = np.vstack(out_s)

    nv, nf = len(V), len(F)
    va = np.zeros(nv, dtype=_VDT)
    va["p"] = V[:, 0:3]
    va["n"] = V[:, 3:6]
    va["uv"] = V[:, 6:8]
    va["t"] = _tangent_bytes(V[:, 8:12])
    va["c"] = 255
    core = struct.pack("<I", nv) + va.tobytes() + struct.pack("<I", nf) + F.tobytes()
    lods = struct.pack("<HBI", 0, 1, 2) + struct.pack("<II", 0, nf)

    # "culling" size per bone: Roblox's own files give every bone that moves vertices a
    # non-zero size (and 0 to bones that move nothing). Use a generous one: far enough from
    # the bone to cover every vertex it moves, plus the whole mesh's size.
    bone_verts = {}
    for v in range(nv):
        for k in range(4):
            if S[v, 4 + k] > 0:
                bone_verts.setdefault(int(sub_global[v][S[v, k]]), []).append(v)
    diag = float(np.linalg.norm(V[:, 0:3].max(axis=0) - V[:, 0:3].min(axis=0)))
    names = b""
    bone_bytes = b""
    for bi, b in enumerate(bones):
        off = len(names)
        names += b["n"].encode("utf-8") + b"\0"
        par = b["p"] if b["p"] >= 0 else 0xFFFF
        cull = 0.0
        if bi in bone_verts:
            here = np.array([b["x"], b["y"], b["z"]])
            cull = float(np.linalg.norm(V[bone_verts[bi], 0:3] - here, axis=1).max()) + diag
        bone_bytes += struct.pack("<IHHf9f3f", off, par, par, cull,
                                  1, 0, 0, 0, 1, 0, 0, 0, 1, b["x"], b["y"], b["z"])
    sub_bytes = b""
    for fb, fl, vb, vl, blist in subsets:
        ids = list(blist) + [0xFFFF] * (MAX_SUBSET_BONES - len(blist))
        sub_bytes += struct.pack("<5I26H", fb, fl, vb, vl, len(blist), *ids)
    skinning = (struct.pack("<I", nv) + S.tobytes() + struct.pack("<I", len(bones)) + bone_bytes
                + struct.pack("<I", len(names)) + names + struct.pack("<I", len(subsets)) + sub_bytes)

    data = (b"version 7.00\n" + _chunk(b"COREMESH", 1, core) + _chunk(b"LODS", 1, lods)
            + _chunk(b"SKINNING", 1, skinning))
    return data, nv, nf


# ------------------------------------------------------------------ poses
def _ortho(r):
    u, _, vt = np.linalg.svd(r)
    q = u @ vt
    if np.linalg.det(q) < 0:
        u[:, -1] *= -1
        q = u @ vt
    return q


def pose_transforms(obj, info):
    """Bone.Transform for every bone (as CFrame numbers), so Studio's Bones match Blender's pose."""
    arm = bpy.data.objects.get(info["arm"])
    if arm is None or arm.type != "ARMATURE":
        return None
    ax = np.array(info["ax"])
    s = info["scale"]
    c = np.array(info["center"])
    A = np.eye(4)
    A[:3, :3] = ax * s
    A[:3, 3] = -c
    Ai = np.linalg.inv(A)
    aw = np.array(arm.matrix_world, dtype=np.float64)
    awi = np.linalg.inv(aw)
    bpos = {b["n"]: np.array([b["x"], b["y"], b["z"]]) for b in info["bones"]}
    parent = {b["n"]: (info["bones"][b["p"]]["n"] if b["p"] >= 0 else None) for b in info["bones"]}
    M = {}
    out = {}
    for name in info["order"]:
        pb = arm.pose.bones.get(name)
        if pb is None:
            continue
        rest = np.array(pb.bone.matrix_local, dtype=np.float64)
        mb = aw @ np.array(pb.matrix, dtype=np.float64) @ np.linalg.inv(rest) @ awi
        mr = A @ mb @ Ai                     # the same movement, in Studio's mesh space
        mr[:3, :3] = _ortho(mr[:3, :3])     # Roblox bones can't scale
        M[name] = mr
        par = parent.get(name)
        mp = M.get(par, np.eye(4)) if par else np.eye(4)
        B = np.eye(4)
        B[:3, 3] = bpos[name]
        t = np.linalg.inv(B) @ np.linalg.inv(mp) @ mr @ B
        r = _ortho(t[:3, :3])
        out[name] = [round(float(v), 5) for v in (t[0, 3], t[1, 3], t[2, 3],
                                                   r[0, 0], r[0, 1], r[0, 2],
                                                   r[1, 0], r[1, 1], r[1, 2],
                                                   r[2, 0], r[2, 1], r[2, 2])]
    return out


def send_pose(obj, props):
    key = obj.get(KEY_PROP)
    info = _state["sent"].get(key) if key else None
    if not info or not info.get("bones"):
        return False
    t = pose_transforms(obj, info)
    if t is None:
        return False
    res = _post(props, "/blender/pose", {"key": key, "t": t})
    return bool(res.get("ok"))


# ------------------------------------------------------------------ material
def _image_upstream(sock, depth=0):
    """The image feeding this input (through Mix / Hue / Gamma ... nodes too)."""
    if sock is None or not sock.is_linked or depth > 5:
        return None
    node = sock.links[0].from_node
    if node.type == "TEX_IMAGE":
        return node.image
    for inp in node.inputs:
        if inp.type in ("RGBA", "VALUE", "VECTOR"):
            img = _image_upstream(inp, depth + 1)
            if img is not None:
                return img
    return None


def _overlay_colour(base):
    """sRGB colour if Base Color is Mix(colour, picture, factor = picture alpha), else None."""
    if base is None or not base.is_linked:
        return None
    node = base.links[0].from_node
    if node.type not in ("MIX", "MIX_RGB"):
        return None
    socks = [i for i in node.inputs if i.enabled] if hasattr(node.inputs[0], "enabled") else list(node.inputs)
    fac = next((i for i in socks if i.type == "VALUE" or i.name in ("Fac", "Factor")), None)
    if fac is None or not fac.is_linked:
        return None
    src = fac.links[0]
    if src.from_node.type != "TEX_IMAGE" or src.from_socket.name != "Alpha":
        return None
    cols = [i for i in socks if i.type == "RGBA"]
    plain = next((i for i in cols if not i.is_linked), None)
    if plain is None:
        return None
    return [_to_srgb(c) for c in plain.default_value[:3]]


def _image_bytes(img):
    """(bytes, ext) of a Blender image as PNG/JPG."""
    if img is None:
        return None, None
    if img.packed_file is not None:
        data = bytes(img.packed_file.data)
        if data[:2] == b"\xff\xd8":
            return data, ".jpg"
        if data[:4] == b"\x89PNG":
            return data, ".png"
    path = bpy.path.abspath(img.filepath_raw or img.filepath)
    ext = os.path.splitext(path)[1].lower()
    if img.packed_file is None and ext in (".png", ".jpg", ".jpeg") and os.path.isfile(path):
        with open(path, "rb") as f:
            return f.read(), (".jpg" if ext == ".jpeg" else ext)
    # anything else (generated, painted, .tga, .exr ...) -> save a PNG copy
    if not img.has_data and img.size[0] == 0:
        return None, None
    tmp = os.path.join(tempfile.gettempdir(), "roblox_mesh_tools_tex_%s.png" % hashlib.sha1(img.name.encode()).hexdigest()[:8])
    scene = bpy.context.scene
    fmt = scene.render.image_settings.file_format
    try:
        scene.render.image_settings.file_format = "PNG"
        img.save_render(tmp, scene=scene)
    finally:
        scene.render.image_settings.file_format = fmt
    with open(tmp, "rb") as f:
        return f.read(), ".png"


def _to_srgb(c):
    c = max(0.0, min(1.0, float(c)))
    return c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055


def get_material(obj):
    """What Roblox can show of the object's first material:
    maps (color / normal / roughness / metalness images), see-through, plain colour, both sides."""
    out = {"maps": {}, "alpha": False, "tint": None, "double": True}
    mat = None
    for slot in obj.material_slots:
        if slot.material is not None:
            mat = slot.material
            break
    if mat is None:
        return out
    out["double"] = not getattr(mat, "use_backface_culling", False)
    if not mat.use_nodes or not mat.node_tree:
        out["tint"] = [_to_srgb(c) for c in mat.diffuse_color[:3]]
        return out
    nodes = mat.node_tree.nodes
    bsdf = next((n for n in nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        img = next((n.image for n in nodes if n.type == "TEX_IMAGE" and n.image), None)
        if img is not None:
            out["maps"]["color"] = img
        return out
    base = bsdf.inputs.get("Base Color")
    img = _image_upstream(base)
    if img is not None:
        out["maps"]["color"] = img
        over = _overlay_colour(base)
        if over is not None:
            # picture over a plain colour through its see-through spots (a Roblox Overlay /
            # SpecialMesh look): Studio paints it over the part colour, so the colour stays editable
            out["look"] = "overlay"
            out["color"] = over
    elif base is not None and not base.is_linked:
        out["tint"] = [_to_srgb(c) for c in base.default_value[:3]]
    alpha = bsdf.inputs.get("Alpha")
    if alpha is not None and (alpha.is_linked or alpha.default_value < 0.999):
        out["alpha"] = True
    nrm = bsdf.inputs.get("Normal")
    if nrm is not None and nrm.is_linked:
        node = nrm.links[0].from_node
        if node.type == "NORMAL_MAP":
            nimg = _image_upstream(node.inputs.get("Color"))
            if nimg is not None:
                out["maps"]["normal"] = nimg
    for name, kind in (("Roughness", "roughness"), ("Metallic", "metalness")):
        sock = bsdf.inputs.get(name)
        if sock is not None and sock.is_linked and sock.links[0].from_node.type == "TEX_IMAGE":
            out["maps"][kind] = sock.links[0].from_node.image
    return out


# ------------------------------------------------------------------ sending
def send_object(obj, props, depsgraph):
    look = get_material(obj) if props.send_texture else {"maps": {}, "alpha": False, "tint": None, "double": True}
    data, info = build_mesh(obj, depsgraph, props, normal_map="normal" in look["maps"])
    key = obj.get(KEY_PROP)
    if not key:
        key = hashlib.sha1(("%s|%f" % (obj.name, time.time())).encode()).hexdigest()[:16]
        obj[KEY_PROP] = key

    # pictures: each one is only sent if Mesh Downloader doesn't have it yet
    maps, blobs = [], {}
    for kind, img in look["maps"].items():
        b, ext = _image_bytes(img)
        if b:
            h = hashlib.sha1(b).hexdigest()[:20]
            maps.append({"kind": kind, "hash": h, "ext": ext})
            blobs[h] = (b, ext)

    meta = {"key": key, "name": obj.name, "center": info["center"], "size": info["size"],
            "maps": maps, "alpha": look["alpha"], "double": look["double"]}
    if look["tint"] is not None:
        meta["tint"] = look["tint"]
    if look.get("look"):
        meta["look"] = look["look"]
        meta["color"] = look["color"]
    if info.get("bones"):
        meta["bones"] = info["bones"]
    res = _post(props, "/blender/mesh", meta, data)
    if res.get("needTextures"):
        for h in res["needTextures"]:
            if h in blobs:
                r2 = _post(props, "/blender/texture", {"hash": h, "ext": blobs[h][1]}, blobs[h][0])
                if not r2.get("ok"):
                    raise RuntimeError("Texture: " + str(r2.get("error")))
        res = _post(props, "/blender/mesh", meta, data)
    if not res.get("ok"):
        raise RuntimeError(str(res.get("error") or "Mesh Downloader said no"))
    if res.get("id"):
        target = _move_target(obj)
        obj["roblox_sent_id"] = str(res["id"])
        obj["roblox_sent_center"] = [float(c) for c in info["center"]]
        obj["roblox_sent_size"] = [float(c) for c in info["size"]]
        obj["roblox_sent_matrix"] = [float(x) for row in target.matrix_world for x in row]

    if info.get("bones"):
        _state["sent"][key] = info
        try:
            send_pose(obj, props)            # show the current pose right away
        except Exception:
            pass
    else:
        _state["sent"].pop(key, None)
    return info


def _send_many(objs, props, depsgraph):
    sent, errors, notes = [], [], []
    for obj in objs:
        try:
            if obj.mode == "EDIT":
                obj.update_from_editmode()
            info = send_object(obj, props, depsgraph)
            extra = ", %d bones" % len(info["bones"]) if info.get("bones") else ""
            sent.append("%s (%d tris%s)" % (obj.name, info["tris"], extra))
            if info.get("over4"):
                notes.append("%s: %d vertices had more than 4 bones - kept the strongest 4" % (obj.name, info["over4"]))
        except Exception as e:
            errors.append("%s: %s" % (obj.name, e))
    if sent:
        _state["status"] = "Sent " + ", ".join(sent) + time.strftime("  at %H:%M:%S")
    if notes:
        _state["status"] += "  |  " + notes[0]
    if errors:
        _state["status"] = "Problem - " + errors[0]
    return sent, errors


# ------------------------------------------------------------------ live mode
def _linked_objects():
    return [o for o in bpy.data.objects if o.type == "MESH" and o.get(KEY_PROP)]


def _flush():
    scene = bpy.context.scene
    props = scene.roblox_mesh_tools
    if not props.live:
        _state["dirty"].clear()
        _state["pose_dirty"].clear()
        return None
    # poses: small, so they go out quickly
    if _state["pose_dirty"]:
        names = list(_state["pose_dirty"])
        _state["pose_dirty"].clear()
        _state["busy"] = True
        try:
            for n in names:
                o = bpy.data.objects.get(n)
                if o is not None:
                    try:
                        send_pose(o, props)
                    except Exception as e:
                        _state["status"] = "Problem - %s" % e
        finally:
            _state["busy"] = False
    if not _state["dirty"]:
        return None
    wait = props.live_delay - (time.time() - _state["last_change"])
    if wait > 0.02:
        return min(wait, 0.1) if _state["pose_dirty"] else wait     # still changing - wait until it settles
    names = list(_state["dirty"])
    _state["dirty"].clear()
    objs = [bpy.data.objects.get(n) for n in names]
    objs = [o for o in objs if o is not None and o.type == "MESH" and o.get(KEY_PROP)]
    if objs:
        _state["busy"] = True
        try:
            _send_many(objs, props, bpy.context.evaluated_depsgraph_get())
        finally:
            _state["busy"] = False
        _redraw()
    return None


@persistent
def _on_depsgraph(scene, depsgraph):
    props = getattr(scene, "roblox_mesh_tools", None)
    if props is None or not props.live or _state["busy"] or time.time() < _state.get("quiet_until", 0):
        return
    mesh_changed = False
    pose_changed = False
    linked = None
    for u in depsgraph.updates:
        idb = u.id
        if isinstance(idb, bpy.types.Object):
            obj = idb.original
            if obj.type == "ARMATURE":
                if linked is None:
                    linked = _linked_objects()
                for o in linked:
                    key = o.get(KEY_PROP)
                    info = _state["sent"].get(key)
                    if info and info.get("arm") == obj.name:
                        _state["pose_dirty"].add(o.name)
                        pose_changed = True
            elif obj.type == "MESH" and obj.get(KEY_PROP):
                skinned = obj.get(KEY_PROP) in _state["sent"]
                # a skinned mesh's geometry "changes" every time its armature moves - poses
                # handle that, so only resend it when it's moved or really edited
                if u.is_updated_transform or (u.is_updated_geometry and not skinned):
                    _state["dirty"].add(obj.name)
                    mesh_changed = True
        elif isinstance(idb, bpy.types.Mesh):
            me = idb.original
            if linked is None:
                linked = _linked_objects()
            for obj in linked:
                if obj.data == me:
                    _state["dirty"].add(obj.name)
                    mesh_changed = True
    if mesh_changed:
        _state["last_change"] = time.time()
    if (mesh_changed or pose_changed) and not bpy.app.timers.is_registered(_flush):
        first = 0.05 if pose_changed else max(0.1, props.live_delay)
        bpy.app.timers.register(_flush, first_interval=first)


def _redraw():
    try:
        for win in bpy.context.window_manager.windows:
            for area in win.screen.areas:
                if area.type == "VIEW_3D":
                    area.tag_redraw()
    except Exception:
        pass


# ------------------------------------------------------------------ reading .mesh files (Studio -> Blender, Import)


class MeshError(Exception):
    pass


def _v1(data):
    text = data.decode("ascii", "replace").splitlines()
    ver = text[0].strip()
    nf = int(text[1].strip())
    nums = [float(x) for x in __import__("re").findall(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", " ".join(text[2:]))]
    # every vertex: [px,py,pz][nx,ny,nz][u,v,w]
    arr = np.array(nums[: nf * 3 * 9], dtype=np.float32).reshape(-1, 9)
    pos = arr[:, 0:3] * (0.5 if ver == "version 1.00" else 1.0)
    uv = arr[:, 6:8].copy()
    uv[:, 1] = 1.0 - uv[:, 1]          # 1.0x stores v the other way round
    faces = np.arange(len(arr), dtype=np.uint32).reshape(-1, 3)
    return {"pos": pos, "nrm": arr[:, 3:6], "uv": uv, "faces": faces, "bones": [], "skin_idx": None, "skin_w": None}


def _verts(data, off, nv, stride):
    raw = np.frombuffer(data, dtype=np.uint8, count=nv * stride, offset=off).reshape(nv, stride)
    f = raw[:, 0:36].copy().view("<f4").reshape(nv, 9)
    return f[:, 0:3], f[:, 3:6], f[:, 6:8]


def _bones_names_subsets(data, p, nb, names_size, nsub):
    bones = []
    raw = []
    for i in range(nb):
        ni, par, _lod, _cull = struct.unpack_from("<IHHf", data, p)
        r = np.array(struct.unpack_from("<9f", data, p + 12), dtype=np.float64).reshape(3, 3)
        t = np.array(struct.unpack_from("<3f", data, p + 48), dtype=np.float64)
        raw.append((ni, par, r, t))
        p += 60
    names = data[p:p + names_size]
    p += names_size
    for ni, par, r, t in raw:
        end = names.find(b"\0", ni)
        nm = names[ni:end if end >= 0 else None].decode("utf-8", "replace")
        bones.append({"n": nm, "p": -1 if par == 0xFFFF else par, "pos": t, "rot": r})
    subsets = []
    for i in range(nsub):
        fb, fl, vb, vl, nbi = struct.unpack_from("<5I", data, p)
        ids = struct.unpack_from("<26H", data, p + 20)[:nbi]
        subsets.append((fb, fl, vb, vl, ids))
        p += 72
    return bones, subsets, p


def _global_skin(local, nv, subsets):
    """Subset-local bone numbers -> bone list numbers."""
    idx = np.zeros((nv, 4), dtype=np.int32)
    w = local[:, 4:8].astype(np.float32) / 255.0
    for fb, fl, vb, vl, ids in subsets:
        table = np.array(list(ids) + [0], dtype=np.int32)
        li = local[vb:vb + vl, 0:4].astype(np.int32)
        li = np.where(li < len(ids), li, len(ids))
        idx[vb:vb + vl] = table[li]
    return idx, w


def _v2_to_v5(data, ver, off):
    if ver.startswith("version 2."):
        hs, vs, fs, nv, nf = struct.unpack_from("<HBBII", data, off)
        p = off + hs
        pos, nrm, uv = _verts(data, p, nv, vs)
        p += nv * vs
        faces = np.frombuffer(data, dtype="<u4", count=nf * 3, offset=p).reshape(nf, 3)
        return {"pos": pos, "nrm": nrm, "uv": uv, "faces": faces, "bones": [], "skin_idx": None, "skin_w": None}
    if ver.startswith("version 3."):
        hs, vs, fs, lodsz, nlod, nv, nf = struct.unpack_from("<HBBHHII", data, off)
        p = off + hs
        pos, nrm, uv = _verts(data, p, nv, vs)
        p += nv * vs
        faces = np.frombuffer(data, dtype="<u4", count=nf * 3, offset=p).reshape(nf, 3)
        p += nf * 12
        if nlod >= 2:
            lods = struct.unpack_from("<%dI" % nlod, data, p)
            faces = faces[lods[0]:lods[1]]
        return {"pos": pos, "nrm": nrm, "uv": uv, "faces": faces, "bones": [], "skin_idx": None, "skin_w": None}
    # 4.00 / 4.01 / 5.00
    hs, lodtype, nv, nf, nlod, nb, names_size, nsub, hq, _pad = struct.unpack_from("<HHIIHHIHBB", data, off)
    p = off + hs
    pos, nrm, uv = _verts(data, p, nv, 40)
    p += nv * 40
    local = None
    if nb > 0:
        local = np.frombuffer(data, dtype=np.uint8, count=nv * 8, offset=p).reshape(nv, 8)
        p += nv * 8
    faces = np.frombuffer(data, dtype="<u4", count=nf * 3, offset=p).reshape(nf, 3)
    p += nf * 12
    lods = struct.unpack_from("<%dI" % nlod, data, p) if nlod else ()
    p += nlod * 4
    if len(lods) >= 2:
        faces = faces[lods[0]:lods[1]]
    bones, subsets, p = _bones_names_subsets(data, p, nb, names_size, nsub)
    out = {"pos": pos, "nrm": nrm, "uv": uv, "faces": faces, "bones": bones, "skin_idx": None, "skin_w": None}
    if local is not None:
        out["skin_idx"], out["skin_w"] = _global_skin(local, nv, subsets)
    return out


def _draco(blob):
    """Decode Roblox's Draco-compressed COREMESH (version 2) with the Draco library that
    Blender's own glTF importer ships."""
    import ctypes
    import os
    try:
        import io_scene_gltf2
    except Exception:
        import addon_utils
        addon_utils.enable("io_scene_gltf2", default_set=False)
        import io_scene_gltf2
    folder = os.path.dirname(io_scene_gltf2.__file__)
    for name in ("extern_draco.dll", "libextern_draco.so", "libextern_draco.dylib"):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            break
    else:
        raise MeshError("this Blender has no Draco decoder (it comes with the glTF add-on)")
    dll = ctypes.cdll.LoadLibrary(path)
    dll.decoderCreate.restype = ctypes.c_void_p
    dll.decoderRelease.argtypes = [ctypes.c_void_p]
    dll.decoderDecode.restype = ctypes.c_bool
    dll.decoderDecode.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
    dll.decoderReadAttribute.restype = ctypes.c_bool
    dll.decoderReadAttribute.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_size_t, ctypes.c_char_p]
    dll.decoderGetVertexCount.restype = ctypes.c_uint32
    dll.decoderGetVertexCount.argtypes = [ctypes.c_void_p]
    dll.decoderGetIndexCount.restype = ctypes.c_uint32
    dll.decoderGetIndexCount.argtypes = [ctypes.c_void_p]
    dll.decoderGetAttributeByteLength.restype = ctypes.c_size_t
    dll.decoderGetAttributeByteLength.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    dll.decoderCopyAttribute.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
    dll.decoderReadIndices.restype = ctypes.c_bool
    dll.decoderReadIndices.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    dll.decoderGetIndicesByteLength.restype = ctypes.c_size_t
    dll.decoderGetIndicesByteLength.argtypes = [ctypes.c_void_p]
    dll.decoderCopyIndices.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    dec = dll.decoderCreate()
    try:
        buf = ctypes.create_string_buffer(bytes(blob), len(blob))
        if not dll.decoderDecode(dec, buf, len(blob)):
            raise MeshError("couldn't decode the compressed mesh")
        nv = dll.decoderGetVertexCount(dec)

        def attr(uid, comp, typ, dtype, width):
            if not dll.decoderReadAttribute(dec, uid, comp, typ):
                return None
            n = dll.decoderGetAttributeByteLength(dec, uid)
            out = ctypes.create_string_buffer(n)
            dll.decoderCopyAttribute(dec, uid, out)
            return np.frombuffer(out.raw, dtype=dtype).reshape(nv, width).copy()

        pos = attr(0, 5126, b"VEC3", "<f4", 3)
        nrm = attr(1, 5126, b"VEC3", "<f4", 3)
        uv = attr(2, 5126, b"VEC2", "<f4", 2)
        if not dll.decoderReadIndices(dec, 5125):
            raise MeshError("couldn't decode the mesh's triangles")
        n = dll.decoderGetIndicesByteLength(dec)
        out = ctypes.create_string_buffer(n)
        dll.decoderCopyIndices(dec, out)
        faces = np.frombuffer(out.raw, dtype="<u4").reshape(-1, 3).copy()
    finally:
        dll.decoderRelease(dec)
    if pos is None:
        raise MeshError("compressed mesh has no positions")
    if nrm is None:
        nrm = np.zeros_like(pos)
    if uv is None:
        uv = np.zeros((nv, 2), dtype=np.float32)
    return pos, nrm, uv, faces


def _chunked(data, off):
    chunks = {}
    p = off
    while p + 16 <= len(data):
        name = data[p:p + 8].rstrip(b"\0").decode("ascii", "replace")
        ver, size = struct.unpack_from("<II", data, p + 8)
        chunks[name] = (ver, data[p + 16:p + 16 + size])
        p += 16 + size
    if "COREMESH" not in chunks:
        raise MeshError("no COREMESH chunk")
    ver, core = chunks["COREMESH"]
    if ver == 1:
        nv, = struct.unpack_from("<I", core, 0)
        pos, nrm, uv = _verts(core, 4, nv, 40)
        nf, = struct.unpack_from("<I", core, 4 + nv * 40)
        faces = np.frombuffer(core, dtype="<u4", count=nf * 3, offset=8 + nv * 40).reshape(nf, 3)
    elif ver == 2:
        n, = struct.unpack_from("<I", core, 0)
        pos, nrm, uv, faces = _draco(core[4:4 + n])
    else:
        raise MeshError("unknown COREMESH version %d" % ver)
    if "LODS" in chunks:
        lv, lod = chunks["LODS"]
        try:
            _t, _hq, nl = struct.unpack_from("<HBI", lod, 0)
            offs = struct.unpack_from("<%dI" % nl, lod, 7)
            if nl >= 2 and offs[1] > offs[0]:
                faces = faces[offs[0]:offs[1]]
        except struct.error:
            pass
    out = {"pos": pos, "nrm": nrm, "uv": uv, "faces": faces, "bones": [], "skin_idx": None, "skin_w": None}
    if "SKINNING" in chunks:
        sk = chunks["SKINNING"][1]
        ns, = struct.unpack_from("<I", sk, 0)
        local = np.frombuffer(sk, dtype=np.uint8, count=ns * 8, offset=4).reshape(ns, 8)
        p = 4 + ns * 8
        nb, = struct.unpack_from("<I", sk, p)
        p += 4
        # bones, then the name table size, then names, then subsets
        q = p + nb * 60
        names_size, = struct.unpack_from("<I", sk, q)
        bone_part = sk[p:p + nb * 60] + sk[q + 4:q + 4 + names_size]
        nsub, = struct.unpack_from("<I", sk, q + 4 + names_size)
        tail = sk[q + 8 + names_size:]
        bones, subsets, _ = _bones_names_subsets(bone_part + tail, 0, nb, names_size, nsub)
        out["bones"] = bones
        if ns == len(pos):
            out["skin_idx"], out["skin_w"] = _global_skin(local, ns, subsets)
    return out


def read_mesh(data):
    data = bytes(data)
    nl = data.find(b"\n")
    if nl < 0 or nl > 32 or not data.startswith(b"version "):
        raise MeshError("not a Roblox .mesh file")
    ver = data[:nl].decode("ascii").strip()
    off = nl + 1
    if ver.startswith("version 1."):
        out = _v1(data)
    elif ver[8:9] in "2345":
        out = _v2_to_v5(data, ver, off)
    elif ver[8:9] in "67":
        out = _chunked(data, off)
    else:
        raise MeshError("unsupported " + ver)
    out["version"] = ver
    out["pos"] = np.asarray(out["pos"], dtype=np.float32)
    out["faces"] = np.asarray(out["faces"], dtype=np.uint32)
    # drop triangles that point past the vertex list (damaged files)
    ok = (out["faces"] < len(out["pos"])).all(axis=1)
    out["faces"] = out["faces"][ok]
    return out


def _srgb_to_linear(c):
    c = max(0.0, min(1.0, float(c)))
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _mix_node(nt):
    """A colour Mix node (newer Blender: ShaderNodeMix, older: ShaderNodeMixRGB) -> (node, fac, a, b, out)."""
    try:
        n = nt.nodes.new("ShaderNodeMix")
        n.data_type = "RGBA"
        a = next(i for i in n.inputs if i.name == "A" and i.type == "RGBA")
        b = next(i for i in n.inputs if i.name == "B" and i.type == "RGBA")
        out = next(o for o in n.outputs if o.name == "Result" and o.type == "RGBA")
        return n, n.inputs[0], a, b, out
    except Exception:
        n = nt.nodes.new("ShaderNodeMixRGB")
        return n, n.inputs[0], n.inputs[1], n.inputs[2], n.outputs[0]


def make_material(name, image, look, color, transparency):
    """Sets up a material the way Roblox draws the part:
    opaque  = TextureID on a MeshPart (see-through spots show the picture's hidden colour)
    overlay = SpecialMesh / SurfaceAppearance Overlay (see-through spots show the part colour)
    alpha   = SurfaceAppearance Transparency (see-through spots are see-through)"""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    col = [_srgb_to_linear(c) for c in (color or (1, 1, 1))] + [1.0]
    mat["roblox_look"] = look
    mat["roblox_color"] = list(color or (1, 1, 1))
    mat["roblox_transparency"] = float(transparency or 0)
    alpha_sock = None
    if image is None:
        bsdf.inputs["Base Color"].default_value = col
    else:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = image
        tex.location = (-600, 200)
        if look == "overlay":
            mix, fac, a, b, out = _mix_node(nt)
            mix.location = (-300, 250)
            a.default_value = col
            nt.links.new(tex.outputs["Alpha"], fac)
            nt.links.new(tex.outputs["Color"], b)
            nt.links.new(out, bsdf.inputs["Base Color"])
        else:
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            if look == "alpha":
                alpha_sock = tex.outputs["Alpha"]
    t = float(transparency or 0)
    if alpha_sock is not None and t > 0.001:
        mul = nt.nodes.new("ShaderNodeMath")
        mul.operation = "MULTIPLY"
        mul.inputs[1].default_value = 1.0 - t
        nt.links.new(alpha_sock, mul.inputs[0])
        nt.links.new(mul.outputs[0], bsdf.inputs["Alpha"])
    elif alpha_sock is not None:
        nt.links.new(alpha_sock, bsdf.inputs["Alpha"])
    elif t > 0.001:
        bsdf.inputs["Alpha"].default_value = 1.0 - t
    if alpha_sock is not None or t > 0.001:
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED"
        else:
            mat.blend_method = "HASHED"
    mat.use_backface_culling = False
    return mat


def _move_target(obj):
    """What to move when the part moves: the armature for rigged meshes, else the object."""
    return obj.parent if (obj.parent is not None and obj.parent.type == "ARMATURE") else obj


def _rbx_matrix(cf, scale=None):
    m = np.eye(4)
    m[:3, :3] = np.array(cf[3:12], dtype=np.float64).reshape(3, 3)
    if scale is not None:
        m[:3, :3] = m[:3, :3] @ np.diag(scale)
    m[:3, 3] = cf[0:3]
    return m


def _to_blender_space(m, props):
    """Roblox-space 4x4 (studs) -> Blender-space 4x4 (metres)."""
    ax = _axis_matrix(props)
    k = np.eye(4)
    k[:3, :3] = ax.T / props.studs_per_meter
    ki = np.eye(4)
    ki[:3, :3] = ax * props.studs_per_meter
    return k @ m @ ki


def _follow_studio(obj, ev, props):
    """The part shows the mesh this object last sent: move / turn / resize the object the same way."""
    import mathutils
    c0 = obj.get("roblox_sent_center")
    s0 = obj.get("roblox_sent_size")
    m0 = obj.get("roblox_sent_matrix")
    if c0 is None or s0 is None or m0 is None or not ev.get("cframe"):
        return
    size = ev.get("size") or list(s0)
    ratio = [float(a) / float(b) if abs(float(b)) > 1e-6 else 1.0 for a, b in zip(size, s0)]
    sent = np.eye(4)
    sent[:3, 3] = list(c0)
    now = _rbx_matrix(ev["cframe"], ratio)
    delta = _to_blender_space(now @ np.linalg.inv(sent), props)
    new = delta @ np.array(list(m0), dtype=np.float64).reshape(4, 4)
    _move_target(obj).matrix_world = mathutils.Matrix(new.tolist())


def _cframe_matrix(cf, props):
    """Roblox CFrame (x, y, z, R00..R22) -> Blender object matrix."""
    import mathutils
    ax = _axis_matrix(props)
    s = props.studs_per_meter
    r = np.array(cf[3:12], dtype=np.float64).reshape(3, 3)
    t = np.array(cf[0:3], dtype=np.float64)
    rb = ax.T @ r @ ax
    tb = ax.T @ t / s
    m = mathutils.Matrix.Identity(4)
    for i in range(3):
        for j in range(3):
            m[i][j] = rb[i, j]
        m[i][3] = tb[i]
    return m


def build_object(name, mesh, props, scale=(1, 1, 1), image=None, look="opaque", color=None, transparency=0.0, matrix=None):
    """Makes a Blender object (and an armature when the mesh has bones) from a read .mesh."""
    ax = _axis_matrix(props)
    s = props.studs_per_meter
    sc = np.array(scale, dtype=np.float64)
    pos = mesh["pos"].astype(np.float64) * sc
    nrm = mesh["nrm"].astype(np.float64) / np.where(sc == 0, 1, sc)
    ln = np.linalg.norm(nrm, axis=1, keepdims=True)
    ln[ln == 0] = 1
    nrm /= ln
    vb = pos @ ax / s                     # Roblox mesh space -> Blender object space
    nb = nrm @ ax
    faces = mesh["faces"].astype(np.int64)

    me = bpy.data.meshes.new(name)
    me.from_pydata(vb.tolist(), [], faces.tolist())
    me.update()
    uv = mesh["uv"].astype(np.float64).copy()
    if props.flip_v:
        uv[:, 1] = 1.0 - uv[:, 1]
    uvl = me.uv_layers.new(name="UVMap")
    lv = np.empty(len(me.loops), dtype=np.int32)
    me.loops.foreach_get("vertex_index", lv)
    uvl.data.foreach_set("uv", uv[lv].astype(np.float32).ravel())
    for poly in me.polygons:
        poly.use_smooth = True
    try:
        if hasattr(me, "use_auto_smooth"):
            me.use_auto_smooth = True
        me.normals_split_custom_set_from_vertices(nb.tolist())
    except Exception:
        pass
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    if matrix is not None:
        obj.matrix_world = matrix
    if look or image is not None or color is not None:
        me.materials.append(make_material(name, image, look, color, transparency))

    if mesh["bones"]:
        arm_data = bpy.data.armatures.new(name + "_Rig")
        rig = bpy.data.objects.new(name + "_Rig", arm_data)
        bpy.context.scene.collection.objects.link(rig)
        rig.matrix_world = obj.matrix_world.copy()
        prev = bpy.context.view_layer.objects.active
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode="EDIT")
        heads = [np.array(b["pos"]) * sc @ ax / s for b in mesh["bones"]]
        size = float(np.linalg.norm(vb.max(axis=0) - vb.min(axis=0))) or 1.0
        made = []
        for i, b in enumerate(mesh["bones"]):
            eb = arm_data.edit_bones.new(b["n"] or ("Bone%d" % i))
            eb.head = heads[i].tolist()
            kids = [j for j, c in enumerate(mesh["bones"]) if c["p"] == i and np.linalg.norm(heads[j] - heads[i]) > 1e-4]
            if kids:
                tail = heads[kids[0]]
            else:
                tail = heads[i] + np.array([0, 0, size * 0.05])
            if np.linalg.norm(tail - heads[i]) < 1e-4:
                tail = heads[i] + np.array([0, 0, size * 0.05])
            eb.tail = tail.tolist()
            made.append(eb)
        for i, b in enumerate(mesh["bones"]):
            if 0 <= b["p"] < len(made):
                made[i].parent = made[b["p"]]
        bpy.ops.object.mode_set(mode="OBJECT")
        bpy.context.view_layer.objects.active = prev
        names = [bn.name for bn in made] if False else [arm_data.bones[i].name for i in range(len(arm_data.bones))]
        groups = [obj.vertex_groups.new(name=b["n"] or ("Bone%d" % i)) for i, b in enumerate(mesh["bones"])]
        if mesh["skin_idx"] is not None:
            for v in range(len(pos)):
                for k in range(4):
                    w = float(mesh["skin_w"][v, k])
                    if w > 0:
                        groups[int(mesh["skin_idx"][v, k])].add([v], w, "ADD")
        mod = obj.modifiers.new("Armature", "ARMATURE")
        mod.object = rig
        obj.parent = rig
        obj.matrix_parent_inverse = rig.matrix_world.inverted()
    return obj


# ------------------------------------------------------------------ Studio -> Blender
def _get(props, path, timeout=2.0):
    with _opener.open(_url(props, path), timeout=timeout) as r:
        return r.read()


def _find_linked(key):
    for o in bpy.data.objects:
        if o.get(KEY_PROP) == key and o.type == "MESH":
            return o
    return None


def _remove_object(o):
    rig = o.parent if (o.parent is not None and o.parent.type == "ARMATURE") else None
    bpy.data.objects.remove(o, do_unlink=True)
    if rig is not None and not rig.children:
        bpy.data.objects.remove(rig, do_unlink=True)


def apply_studio_event(ev, props):
    """A part sent from Studio: make it (or update the linked object)."""
    key = str(ev.get("key") or "")
    mesh_id = str(ev.get("meshId") or "")
    if not key or not mesh_id:
        return
    matrix = _cframe_matrix(ev["cframe"], props) if ev.get("cframe") else None
    obj = _find_linked(key)
    if obj is not None and mesh_id == str(obj.get("roblox_sent_id") or ""):
        _follow_studio(obj, ev, props)            # Studio shows what this object sent
        _set_colour(obj, ev)
        return
    if obj is not None and obj.get("roblox_sent_id"):
        # Studio shows an older mesh (undo?) - never rebuild over work done in Blender
        _state["status"] = "Studio shows an older mesh for %s - kept yours (send it again to update Studio)" % obj.name
        return
    tex_name = str(ev.get("texture") or "")
    look = str(ev.get("look") or "opaque")
    color = ev.get("color") or [1, 1, 1]
    transparency = float(ev.get("transparency") or 0)
    scale_key = json.dumps([round(float(x), 4) for x in (ev.get("scale") or ev.get("size") or [])])
    same_mesh = obj is not None and obj.get("roblox_mesh_id") == mesh_id and obj.get("roblox_scale") == scale_key
    same_look = obj is not None and obj.get("roblox_look_key") == "%s|%s|%.3f" % (tex_name, look, transparency)
    if same_mesh:
        # only moved / recoloured: no need to rebuild
        target = obj.parent if (obj.parent is not None and obj.parent.type == "ARMATURE") else obj
        if matrix is not None:
            target.matrix_world = matrix
        if not same_look:
            old = [m for m in obj.data.materials if m is not None]
            obj.data.materials.clear()
            for m in old:
                if m.users == 0:
                    bpy.data.materials.remove(m)
            img = _studio_image(props, tex_name)
            obj.data.materials.append(make_material(obj.name, img, look, color, transparency))
        else:
            _set_colour(obj, ev)
            obj["roblox_look_key"] = "%s|%s|%.3f" % (tex_name, look, transparency)
        return
    mesh = read_mesh(_get(props, "/blender/file?kind=mesh&id=" + mesh_id, 10))
    if ev.get("centerMesh"):
        mid = (mesh["pos"].max(axis=0) + mesh["pos"].min(axis=0)) / 2.0
        mesh["pos"] = mesh["pos"] - mid
        for b in mesh["bones"]:
            b["pos"] = (np.array(b["pos"], dtype=np.float64) - mid).tolist()
    if ev.get("scale"):
        scale = [float(x) for x in ev["scale"]]
    elif ev.get("size"):
        ext = mesh["pos"].max(axis=0) - mesh["pos"].min(axis=0)
        scale = [float(sz) / float(e) if e > 1e-6 else 1.0 for sz, e in zip(ev["size"], ext)]
    else:
        scale = [1.0, 1.0, 1.0]
    name = str(ev.get("name") or "Roblox mesh")
    if obj is not None:
        name = obj.name
        _remove_object(obj)
    img = _studio_image(props, tex_name)
    new = build_object(name, mesh, props, scale, img, look, color, transparency, matrix)
    if new.parent is not None and matrix is not None:
        new.parent.matrix_world = matrix
        new.matrix_world = matrix
    new[KEY_PROP] = key
    new["roblox_mesh_id"] = mesh_id
    if not props.live:
        props.live = True                    # so edits here go back to the linked part
    new["roblox_scale"] = scale_key
    new["roblox_look_key"] = "%s|%s|%.3f" % (tex_name, look, transparency)
    _state["status"] = "From Studio: %s (%d tris%s)" % (name, len(mesh["faces"]),
                                                        ", %d bones" % len(mesh["bones"]) if mesh["bones"] else "")


def _set_colour(obj, ev):
    """Studio changed the colour of a part whose look is picture-over-colour: follow it."""
    if not ev.get("color"):
        return
    for slot in obj.material_slots:
        mat = slot.material
        if mat is None or not mat.use_nodes:
            continue
        bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        base = bsdf and bsdf.inputs.get("Base Color")
        if base is None:
            continue
        want = [_srgb_to_linear(c) for c in ev["color"]] + [1.0]
        if not base.is_linked and "roblox_look" in mat:
            # plain colour, no picture (only materials made from Studio parts)
            if any(abs(a - b) > 1e-4 for a, b in zip(base.default_value, want)):
                base.default_value = want
            return
        if _overlay_colour(base) is None:
            continue
        node = base.links[0].from_node
        socks = [i for i in node.inputs if i.enabled] if hasattr(node.inputs[0], "enabled") else list(node.inputs)
        plain = next(i for i in socks if i.type == "RGBA" and not i.is_linked)
        if any(abs(a - b) > 1e-4 for a, b in zip(plain.default_value, want)):
            plain.default_value = want
        return


def _studio_image(props, tex_name):
    if not tex_name:
        return None
    existing = bpy.data.images.get("Roblox " + tex_name)
    if existing is not None:
        return existing
    data = _get(props, "/blender/file?kind=tex&name=" + tex_name, 10)
    path = os.path.join(tempfile.gettempdir(), "roblox_mesh_tools_in_" + tex_name)
    with open(path, "wb") as f:
        f.write(data)
    img = bpy.data.images.load(path)
    img.name = "Roblox " + tex_name
    img.pack()
    return img


def _poll_studio():
    try:
        scene = bpy.context.scene
        props = scene.roblox_mesh_tools
    except Exception:
        return 2.0
    if not props.receive:
        return 2.0
    try:
        data = json.loads(_get(props, "/blender/incoming", 0.5).decode("utf-8"))
    except Exception:
        return 3.0                       # app closed: check less often
    events = data.get("events") or []
    if not events:
        # just had something (you're dragging in Studio): keep checking fast for a bit
        return 0.15 if time.time() - _state.get("last_in", 0) < 5 else 1.0
    _state["last_in"] = time.time()
    _state["busy"] = True
    _state["quiet_until"] = time.time() + 1.5   # our own changes aren't edits to send back
    try:
        for ev in events:
            try:
                apply_studio_event(ev, props)
            except Exception as e:
                _state["status"] = "Problem with %s from Studio - %s" % (ev.get("name"), e)
    finally:
        _state["busy"] = False
        _state["quiet_until"] = time.time() + 1.5
    _redraw()
    return 0.15


class RMT_OT_import(bpy.types.Operator):
    bl_idname = "roblox_mesh_tools.import_mesh"
    bl_label = "Roblox Mesh (.mesh)"
    bl_description = "Import a Roblox .mesh file (any version, with bones)"
    filter_glob: bpy.props.StringProperty(default="*.mesh", options={"HIDDEN"})
    filepath: bpy.props.StringProperty(subtype="FILE_PATH")
    files: bpy.props.CollectionProperty(type=bpy.types.OperatorFileListElement)
    directory: bpy.props.StringProperty(subtype="DIR_PATH")

    def invoke(self, context, event):
        context.window_manager.fileselect_add(self)
        return {"RUNNING_MODAL"}

    def execute(self, context):
        props = context.scene.roblox_mesh_tools
        paths = [os.path.join(self.directory, f.name) for f in self.files if f.name] or [self.filepath]
        n = 0
        for path in paths:
            try:
                with open(path, "rb") as f:
                    mesh = read_mesh(f.read())
                build_object(os.path.splitext(os.path.basename(path))[0], mesh, props, look=None)
                n += 1
            except Exception as e:
                self.report({"ERROR"}, "%s: %s" % (os.path.basename(path), e))
        self.report({"INFO"}, "Imported %d .mesh file(s)" % n)
        return {"FINISHED"}


def _menu_import(self, context):
    self.layout.operator(RMT_OT_import.bl_idname, text="Roblox Mesh (.mesh)")


# ------------------------------------------------------------------ UI
class RMT_Props(bpy.types.PropertyGroup):
    studs_per_meter: bpy.props.FloatProperty(
        name="Studs per metre", default=1.0, min=0.001, soft_max=10.0,
        description="1 = a 2 m cube becomes a 2-stud cube. Roblox's docs count 1 stud as 0.28 m, so use 3.57 for real-world size")
    flip_v: bpy.props.BoolProperty(
        name="Flip texture vertically", default=True,
        description="Roblox stores texture coordinates upside-down compared to Blender. Turn off if the texture shows upside-down")
    flip_faces: bpy.props.BoolProperty(
        name="Flip faces", default=False, description="Turn on if the mesh shows inside-out in Studio")
    turn_around: bpy.props.BoolProperty(
        name="Face Roblox's front", default=True,
        description="Blender's front (-Y) becomes Roblox's front (-Z), the way Roblox's own character meshes are stored. Off = same as a plain FBX export (front ends up facing backwards)")
    apply_modifiers: bpy.props.BoolProperty(name="Apply modifiers", default=True)
    send_texture: bpy.props.BoolProperty(
        name="Send material", default=True,
        description="Sends the Base Color picture (or colour), Normal / Roughness / Metallic pictures, see-through and both-sides settings")
    send_bones: bpy.props.BoolProperty(
        name="Send bones", default=True,
        description="Objects with an Armature get its bones and weights, so they bend in Studio")
    live: bpy.props.BoolProperty(
        name="Live", default=False,
        description="Resend objects you've already sent whenever they change, and move their bones when you pose")
    live_delay: bpy.props.FloatProperty(
        name="Wait", default=1.0, min=0.2, max=10.0, subtype="TIME", unit="TIME",
        description="How long the mesh has to stop changing before it resends (poses go right away)")
    port: bpy.props.IntProperty(name="Port", default=47820, min=1, max=65535)
    receive: bpy.props.BoolProperty(
        name="Receive from Studio", default=True,
        description="Parts sent with 'Send to Blender' in Studio show up here, and stay linked both ways")


class RMT_OT_send(bpy.types.Operator):
    bl_idname = "roblox_mesh_tools.send"
    bl_label = "Send to Studio"
    bl_description = "Send the selected mesh objects to Roblox Studio (local .mesh, no upload)"

    def execute(self, context):
        objs = [o for o in context.selected_objects if o.type == "MESH"]
        if not objs and context.active_object and context.active_object.type == "MESH":
            objs = [context.active_object]
        if not objs:
            # an armature is selected: send the meshes it moves
            arms = [o for o in context.selected_objects if o.type == "ARMATURE"]
            objs = [o for o in context.scene.objects if o.type == "MESH" and find_armature(o) in arms]
        if not objs:
            self.report({"WARNING"}, "Select a mesh object first")
            return {"CANCELLED"}
        props = context.scene.roblox_mesh_tools
        _state["busy"] = True
        try:
            sent, errors = _send_many(objs, props, context.evaluated_depsgraph_get())
        finally:
            _state["busy"] = False
        if errors:
            self.report({"ERROR"}, errors[0])
            return {"CANCELLED"} if not sent else {"FINISHED"}
        self.report({"INFO"}, "Sent %d object(s) to Studio" % len(sent))
        return {"FINISHED"}


class RMT_OT_pose(bpy.types.Operator):
    bl_idname = "roblox_mesh_tools.pose"
    bl_label = "Send pose"
    bl_description = "Move the Bones in Studio to match the current pose (for objects already sent)"

    def execute(self, context):
        props = context.scene.roblox_mesh_tools
        n = 0
        for o in _linked_objects():
            try:
                if send_pose(o, props):
                    n += 1
            except Exception as e:
                self.report({"ERROR"}, str(e))
                return {"CANCELLED"}
        if n == 0:
            self.report({"WARNING"}, "Send a mesh with an armature first")
            return {"CANCELLED"}
        self.report({"INFO"}, "Sent the pose of %d object(s)" % n)
        return {"FINISHED"}


class RMT_OT_unlink(bpy.types.Operator):
    bl_idname = "roblox_mesh_tools.unlink"
    bl_label = "Unlink"
    bl_description = "Forget which Studio part these objects update. The next send makes a new part"

    def execute(self, context):
        n = 0
        for o in context.selected_objects:
            if KEY_PROP in o:
                _state["sent"].pop(o[KEY_PROP], None)
                del o[KEY_PROP]
                n += 1
        self.report({"INFO"}, "Unlinked %d object(s)" % n)
        return {"FINISHED"}


class RMT_PT_panel(bpy.types.Panel):
    bl_label = "Send to Studio"
    bl_idname = "RMT_PT_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Roblox"

    def draw(self, context):
        props = context.scene.roblox_mesh_tools
        col = self.layout.column()
        col.scale_y = 1.4
        col.operator("roblox_mesh_tools.send", icon="EXPORT")

        row = self.layout.row(align=True)
        row.prop(props, "live", toggle=True, icon="REC" if props.live else "PLAY")
        row.prop(props, "live_delay")
        if any(_state["sent"].values()):
            self.layout.operator("roblox_mesh_tools.pose", icon="ARMATURE_DATA")
        if props.live:
            self.layout.label(text="Live updates objects you've sent once", icon="INFO")

        self.layout.prop(props, "receive", icon="IMPORT")
        box = self.layout.box()
        box.label(text=_state["status"])
        if _state["connected"] is False:
            box.label(text="Open Mesh Downloader (Studio link on)", icon="ERROR")

        obj = context.active_object
        if obj and obj.type == "MESH" and find_armature(obj) is not None and props.send_bones:
            self.layout.label(text="Armature: %s (bones will be sent)" % find_armature(obj).name, icon="BONE_DATA")
        if obj and obj.get(KEY_PROP):
            r = self.layout.row()
            r.label(text="Linked to a Studio part", icon="LINKED")
            r.operator("roblox_mesh_tools.unlink", text="", icon="UNLINKED")


class RMT_PT_options(bpy.types.Panel):
    bl_label = "Options"
    bl_idname = "RMT_PT_options"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Roblox"
    bl_parent_id = "RMT_PT_panel"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        props = context.scene.roblox_mesh_tools
        col = self.layout.column()
        col.prop(props, "studs_per_meter")
        col.prop(props, "apply_modifiers")
        col.prop(props, "send_texture")
        col.prop(props, "send_bones")
        col.prop(props, "flip_v")
        col.prop(props, "flip_faces")
        col.prop(props, "turn_around")
        col.prop(props, "port")


CLASSES = (RMT_Props, RMT_OT_send, RMT_OT_pose, RMT_OT_unlink, RMT_OT_import, RMT_PT_panel, RMT_PT_options)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.Scene.roblox_mesh_tools = bpy.props.PointerProperty(type=RMT_Props)
    if _on_depsgraph not in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.append(_on_depsgraph)
    if _on_frame not in bpy.app.handlers.frame_change_post:
        bpy.app.handlers.frame_change_post.append(_on_frame)
    bpy.types.TOPBAR_MT_file_import.append(_menu_import)
    if not bpy.app.timers.is_registered(_poll_studio):
        bpy.app.timers.register(_poll_studio, first_interval=2.0, persistent=True)


@persistent
def _on_frame(scene, depsgraph=None):
    # playing an animation: stream the pose
    props = getattr(scene, "roblox_mesh_tools", None)
    if props is None or not props.live or _state["busy"]:
        return
    for o in _linked_objects():
        if o.get(KEY_PROP) in _state["sent"]:
            _state["pose_dirty"].add(o.name)
    if _state["pose_dirty"] and not bpy.app.timers.is_registered(_flush):
        bpy.app.timers.register(_flush, first_interval=0.05)


def unregister():
    if _on_depsgraph in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.remove(_on_depsgraph)
    if _on_frame in bpy.app.handlers.frame_change_post:
        bpy.app.handlers.frame_change_post.remove(_on_frame)
    if bpy.app.timers.is_registered(_flush):
        bpy.app.timers.unregister(_flush)
    if bpy.app.timers.is_registered(_poll_studio):
        bpy.app.timers.unregister(_poll_studio)
    try:
        bpy.types.TOPBAR_MT_file_import.remove(_menu_import)
    except Exception:
        pass
    del bpy.types.Scene.roblox_mesh_tools
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    register()
