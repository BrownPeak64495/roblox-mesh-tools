bl_info = {
    "name": "Roblox Mesh Tools - Send to Studio",
    "author": "BrownPeak64495",
    "version": (1, 1, 0),
    "blender": (3, 0, 0),
    "location": "3D View > Sidebar (N) > Roblox",
    "description": "Sends meshes straight into Roblox Studio as local .mesh files (no upload) through Mesh Downloader",
    "category": "Import-Export",
}

# How it works
#   1. Your object is turned into a Roblox .mesh file right here in Blender.
#   2. It's sent to Mesh Downloader on this PC (http://localhost:47820), which saves it
#      and copies it into Studio's content folder.
#   3. The Mesh Tools plugin in Studio picks it up and makes a real MeshPart using
#      rbxasset://meshtools/<id>.mesh - in the same spot as in Blender.
#   Sending the same object again updates the part that's already in Studio.
#   Nothing is uploaded to Roblox.

import base64
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
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # never route localhost through a proxy

_state = {
    "status": "Not sent yet",
    "connected": None,
    "dirty": set(),
    "last_change": 0.0,
    "busy": False,
}


# ------------------------------------------------------------------ talking to Mesh Downloader
def _url(props, path):
    return "http://localhost:%d%s" % (props.port, path)


def _post(props, path, body, meta):
    req = urllib.request.Request(_url(props, path), data=body, method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    req.add_header("X-Meta", base64.b64encode(json.dumps(meta).encode("utf-8")).decode("ascii"))
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


# ------------------------------------------------------------------ mesh conversion
def _to_roblox(v, props):
    # Blender is Z-up, Roblox is Y-up. Same mapping Blender's FBX exporter uses by default
    # (Forward -Z, Up Y): (x, y, z) -> (x, z, -y). It's a rotation, so nothing gets mirrored.
    x, y, z = v[:, 0], v[:, 1], v[:, 2]
    if props.turn_around:
        return np.stack([-x, z, y], axis=1)
    return np.stack([x, z, -y], axis=1)


def _corner_normals(me):
    n = len(me.loops)
    out = np.empty(n * 3, dtype=np.float32)
    if hasattr(me, "corner_normals"):           # Blender 4.1+
        me.corner_normals.foreach_get("vector", out)
    else:                                       # Blender 3.x - 4.0
        me.calc_normals_split()
        me.loops.foreach_get("normal", out)
    return out.reshape(n, 3)


def build_mesh(obj, depsgraph, props):
    """Returns (mesh_bytes, center[3], size[3], vertex_count, triangle_count) in Roblox studs."""
    if props.apply_modifiers:
        src = obj.evaluated_get(depsgraph)
    else:
        src = obj
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
    finally:
        src.to_mesh_clear()

    # bake the object's position / rotation / scale into the vertices
    m = np.array(obj.matrix_world, dtype=np.float64)
    m3 = m[:3, :3]
    pos = co[loop_verts[tri_loops]].astype(np.float64) @ m3.T + m[:3, 3]
    try:
        nm = np.linalg.inv(m3).T
    except np.linalg.LinAlgError:
        nm = m3
    nrm = cn[tri_loops].astype(np.float64) @ nm.T
    length = np.linalg.norm(nrm, axis=1, keepdims=True)
    length[length == 0] = 1
    nrm /= length

    pos = _to_roblox(pos, props) * props.studs_per_meter
    nrm = _to_roblox(nrm, props)
    tuv = uv[tri_loops].astype(np.float64)
    if props.flip_v:
        tuv[:, 1] = 1.0 - tuv[:, 1]

    # one vertex per unique (position, normal, uv) - same as Roblox's own meshes
    rows = np.hstack([np.round(pos, 5), np.round(nrm, 4), np.round(tuv, 5)])
    rows = np.ascontiguousarray(rows)
    keyed = rows.view(np.dtype((np.void, rows.dtype.itemsize * rows.shape[1]))).ravel()
    _, first, inverse = np.unique(keyed, return_index=True, return_inverse=True)
    inverse = inverse.ravel()
    verts = rows[first]
    faces = inverse.reshape(-1, 3).astype(np.uint32)

    flip = props.flip_faces
    if np.linalg.det(m3) < 0:      # negative scale turns faces inside out - undo that
        flip = not flip
    if flip:
        faces = faces[:, [0, 2, 1]]

    lo = verts[:, 0:3].min(axis=0)
    hi = verts[:, 0:3].max(axis=0)
    center = (lo + hi) / 2.0
    size = hi - lo
    verts[:, 0:3] -= center

    nv = len(verts)
    vdt = np.dtype([("p", "<f4", 3), ("n", "<f4", 3), ("uv", "<f4", 3), ("c", "u1", 4)])
    va = np.zeros(nv, dtype=vdt)
    va["p"] = verts[:, 0:3]
    va["n"] = verts[:, 3:6]
    va["uv"][:, 0:2] = verts[:, 6:8]
    va["c"] = 255

    # Roblox .mesh version 2.00: header (12 bytes), vertices (40 bytes each), faces (3 x uint32)
    header = b"version 2.00\n" + struct.pack("<HBBII", 12, 40, 12, nv, len(faces))
    data = header + va.tobytes() + faces.astype("<u4").tobytes()
    return data, [float(c) for c in center], [float(s) for s in size], nv, len(faces)


# ------------------------------------------------------------------ texture
def _find_image(obj):
    best = None
    for slot in obj.material_slots:
        mat = slot.material
        if not mat or not mat.use_nodes or not mat.node_tree:
            continue
        for node in mat.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                inp = node.inputs.get("Base Color")
                if inp and inp.is_linked:
                    src = inp.links[0].from_node
                    if src.type == "TEX_IMAGE" and src.image:
                        return src.image
        for node in mat.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image and best is None:
                best = node.image
    return best


def get_texture(obj):
    """Returns (bytes, ext) of the object's base colour image, or (None, None)."""
    img = _find_image(obj)
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
    tmp = os.path.join(tempfile.gettempdir(), "roblox_mesh_tools_tex.png")
    scene = bpy.context.scene
    fmt = scene.render.image_settings.file_format
    try:
        scene.render.image_settings.file_format = "PNG"
        img.save_render(tmp, scene=scene)
    finally:
        scene.render.image_settings.file_format = fmt
    with open(tmp, "rb") as f:
        return f.read(), ".png"


# ------------------------------------------------------------------ sending
def send_object(obj, props, depsgraph):
    data, center, size, nv, nt = build_mesh(obj, depsgraph, props)
    key = obj.get(KEY_PROP)
    if not key:
        key = hashlib.sha1(("%s|%f" % (obj.name, time.time())).encode()).hexdigest()[:16]
        obj[KEY_PROP] = key

    tex, ext, th = None, None, ""
    if props.send_texture:
        tex, ext = get_texture(obj)
        if tex:
            th = hashlib.sha1(tex).hexdigest()[:20]

    meta = {"key": key, "name": obj.name, "center": center, "size": size, "texHash": th, "texExt": ext or ""}
    res = _post(props, "/blender/mesh", data, meta)
    if res.get("needTexture") and tex:
        r2 = _post(props, "/blender/texture", tex, {"hash": th, "ext": ext})
        if not r2.get("ok"):
            raise RuntimeError("Texture: " + str(r2.get("error")))
        res = _post(props, "/blender/mesh", data, meta)
    if not res.get("ok"):
        raise RuntimeError(str(res.get("error") or "Mesh Downloader said no"))
    return nv, nt


def _send_many(objs, props, depsgraph):
    sent, errors = [], []
    for obj in objs:
        try:
            if obj.mode == "EDIT":
                obj.update_from_editmode()
            nv, nt = send_object(obj, props, depsgraph)
            sent.append("%s (%d tris)" % (obj.name, nt))
        except Exception as e:
            errors.append("%s: %s" % (obj.name, e))
    if sent:
        _state["status"] = "Sent " + ", ".join(sent) + time.strftime("  at %H:%M:%S")
    if errors:
        _state["status"] = "Problem - " + errors[0]
    return sent, errors


# ------------------------------------------------------------------ live mode
def _flush():
    scene = bpy.context.scene
    props = scene.roblox_mesh_tools
    if not props.live:
        _state["dirty"].clear()
        return None
    wait = props.live_delay - (time.time() - _state["last_change"])
    if wait > 0.02:
        return wait                      # still changing - wait until it settles
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
    if props is None or not props.live or _state["busy"]:
        return
    changed = False
    for u in depsgraph.updates:
        idb = u.id
        if isinstance(idb, bpy.types.Object):
            obj = idb.original
            if obj.type == "MESH" and obj.get(KEY_PROP) and (u.is_updated_geometry or u.is_updated_transform):
                _state["dirty"].add(obj.name)
                changed = True
        elif isinstance(idb, bpy.types.Mesh):
            me = idb.original
            for obj in scene.objects:
                if obj.type == "MESH" and obj.data == me and obj.get(KEY_PROP):
                    _state["dirty"].add(obj.name)
                    changed = True
    if changed:
        _state["last_change"] = time.time()
        if not bpy.app.timers.is_registered(_flush):
            bpy.app.timers.register(_flush, first_interval=max(0.1, props.live_delay))


def _redraw():
    try:
        for win in bpy.context.window_manager.windows:
            for area in win.screen.areas:
                if area.type == "VIEW_3D":
                    area.tag_redraw()
    except Exception:
        pass


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
        name="Send texture", default=True, description="Sends the image plugged into Base Color")
    live: bpy.props.BoolProperty(
        name="Live", default=False,
        description="Resend objects you've already sent whenever they change")
    live_delay: bpy.props.FloatProperty(
        name="Wait", default=1.0, min=0.2, max=10.0, subtype="TIME", unit="TIME",
        description="How long things have to stop changing before it resends")
    port: bpy.props.IntProperty(name="Port", default=47820, min=1, max=65535)


class RMT_OT_send(bpy.types.Operator):
    bl_idname = "roblox_mesh_tools.send"
    bl_label = "Send to Studio"
    bl_description = "Send the selected mesh objects to Roblox Studio (local .mesh, no upload)"

    def execute(self, context):
        objs = [o for o in context.selected_objects if o.type == "MESH"]
        if not objs and context.active_object and context.active_object.type == "MESH":
            objs = [context.active_object]
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


class RMT_OT_unlink(bpy.types.Operator):
    bl_idname = "roblox_mesh_tools.unlink"
    bl_label = "Unlink"
    bl_description = "Forget which Studio part these objects update. The next send makes a new part"

    def execute(self, context):
        n = 0
        for o in context.selected_objects:
            if KEY_PROP in o:
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
        if props.live:
            self.layout.label(text="Live updates objects you've sent once", icon="INFO")

        box = self.layout.box()
        box.label(text=_state["status"])
        if _state["connected"] is False:
            box.label(text="Open Mesh Downloader (Studio link on)", icon="ERROR")

        obj = context.active_object
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
        col.prop(props, "flip_v")
        col.prop(props, "flip_faces")
        col.prop(props, "turn_around")
        col.prop(props, "port")


CLASSES = (RMT_Props, RMT_OT_send, RMT_OT_unlink, RMT_PT_panel, RMT_PT_options)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.Scene.roblox_mesh_tools = bpy.props.PointerProperty(type=RMT_Props)
    if _on_depsgraph not in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.append(_on_depsgraph)


def unregister():
    if _on_depsgraph in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.remove(_on_depsgraph)
    if bpy.app.timers.is_registered(_flush):
        bpy.app.timers.unregister(_flush)
    del bpy.types.Scene.roblox_mesh_tools
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    register()
