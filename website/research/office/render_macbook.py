"""Renders the MacBook for the office composite in the office photo's own camera.

    /Applications/Blender.app/Contents/MacOS/Blender -b --python render_macbook.py -- <model.glb|--stand-in> <out.png> [samples]

Camera: the photo's fitted pinhole (prep_office.py): 3000×2000, f = 2000 px, principal point (1490, 690),
looking straight down the car. Car frame (x → passenger, y ↓, z → forward, metres) → Blender world
(X = x, Y = z, Z = -y). The render covers the crop (150, 560)–(2850, 2020) as a border render; prep_office.py
applies the screen's small correction homography (HC) and composites it.

Scene: the MacBook (the model, scaled to a 16" MacBook Pro's 35.57 cm width, its base on the board) on the
board's passenger end, a shadow-catcher plane for the board's top, soft daylight from the windshield and a
dim cabin fill. The display material is replaced with our Mac desktop (office-macbook display texture).
Cycles, modest samples, denoised, transparent film: RGBA with the contact shadow in alpha.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
MODEL = argv[0] if argv else '--stand-in'
OUT = argv[1] if len(argv) > 1 else '/tmp/macbook.png'
SAMPLES = int(argv[2]) if len(argv) > 2 else 96
HERE = os.path.dirname(os.path.abspath(__file__))
DISPLAY_TEX = os.path.join(HERE, 'macbook-display.png')

W, H, F, CX, CY = 3000, 2000, 2000.0, 1490.0, 690.0
CROP = (150, 560, 2850, 2020)
BOARD_Y = 0.335
MAC_W, MAC_D = 0.3557, 0.2481
MAC_X, MAC_Z = 0.366, 1.184  # footprint centre (car frame)


def car(x, y, z):
    return Vector((x, z, -y))


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True
    sc.cycles.device = 'CPU'
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = W, H
    sc.render.resolution_percentage = 100
    sc.render.use_border = True
    sc.render.use_crop_to_border = True
    sc.render.border_min_x = CROP[0] / W
    sc.render.border_max_x = CROP[2] / W
    sc.render.border_min_y = 1 - CROP[3] / H
    sc.render.border_max_y = 1 - CROP[1] / H
    sc.view_settings.view_transform = 'Standard'
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    return sc


def camera(sc):
    cam = bpy.data.cameras.new('photo')
    cam.sensor_fit = 'HORIZONTAL'
    cam.sensor_width = 36.0
    cam.lens = F / W * 36.0
    cam.shift_x = (W / 2 - CX) / W
    cam.shift_y = (CY - H / 2) / W
    cam.clip_start = 0.05
    ob = bpy.data.objects.new('photo', cam)
    ob.rotation_euler = (math.radians(90), 0, 0)
    sc.collection.objects.link(ob)
    sc.camera = ob


def lights(sc):
    world = bpy.data.worlds.new('cabin')
    world.use_nodes = True
    bg = world.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.13, 0.135, 0.145, 1)
    bg.inputs[1].default_value = 0.6
    sc.world = world
    # The windshield: a big soft area light ahead and above, cool daylight.
    L = bpy.data.lights.new('windshield', 'AREA')
    L.shape = 'RECTANGLE'
    L.size, L.size_y = 1.6, 0.6
    L.energy = 260
    L.color = (0.93, 0.96, 1.0)
    ob = bpy.data.objects.new('windshield', L)
    ob.location = car(0.1, -0.55, 2.1)
    ob.rotation_euler = (math.radians(-60), 0, 0)
    sc.collection.objects.link(ob)


def catcher(sc):
    bpy.ops.mesh.primitive_plane_add(size=1)
    p = bpy.context.active_object
    p.scale = (1.1, 0.31, 1)
    p.location = car(0.0, BOARD_Y, 1.155)
    p.is_shadow_catcher = True
    return p


def display_material():
    m = bpy.data.materials.new('dashcast-display')
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    em = nt.nodes.new('ShaderNodeEmission')
    em.inputs['Strength'].default_value = 1.0
    if os.path.exists(DISPLAY_TEX):
        tex = nt.nodes.new('ShaderNodeTexImage')
        tex.image = bpy.data.images.load(DISPLAY_TEX)
        nt.links.new(tex.outputs['Color'], em.inputs['Color'])
    nt.links.new(em.outputs['Emission'], out.inputs['Surface'])
    return m


def stand_in(sc):
    """A MacBook-sized block and a lid, for checking the registration without the model."""
    bpy.ops.mesh.primitive_cube_add(size=1)
    base = bpy.context.active_object
    base.scale = (MAC_W, MAC_D, 0.0155)
    base.location = car(MAC_X, BOARD_Y - 0.00775, MAC_Z)
    bpy.ops.mesh.primitive_cube_add(size=1)
    lid = bpy.context.active_object
    lid.scale = (MAC_W, 0.006, 0.23)
    hinge = car(MAC_X, BOARD_Y - 0.0155, MAC_Z + MAC_D / 2)
    lean = math.radians(20)
    lid.rotation_euler = (lean, 0, 0)
    lid.location = hinge + Vector((0, math.sin(lean) * 0.115, math.cos(lean) * 0.115))


def model(sc, path):
    """Imports the glTF, scales it to a 16" MacBook Pro and puts its base on the board, display toward us."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    obs = [o for o in bpy.data.objects if o not in before]
    root = bpy.data.objects.new('macbook', None)
    sc.collection.objects.link(root)
    for o in obs:
        if o.parent is None:
            o.parent = root
    bpy.context.view_layer.update()
    pts = [o.matrix_world @ Vector(c) for o in obs if o.type == 'MESH' for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    width = max(hi.x - lo.x, hi.y - lo.y)
    s = MAC_W / width
    root.scale = (s, s, s)
    centre = (lo + hi) / 2
    root.location = car(MAC_X, BOARD_Y, MAC_Z) - Vector((centre.x * s, centre.y * s, lo.z * s))
    # The display: any material named like a screen gets our desktop; Apple marks are darkened.
    dm = display_material()
    for o in obs:
        if o.type != 'MESH':
            continue
        for slot in o.material_slots:
            n = (slot.material.name if slot.material else '').lower()
            if any(k in n for k in ('screen', 'display', 'lcd', 'panel')):
                slot.material = dm
            elif 'logo' in n or 'apple' in n:
                slot.material.diffuse_color = (0.02, 0.02, 0.02, 1)
    return root


def main():
    sc = reset()
    camera(sc)
    lights(sc)
    catcher(sc)
    if MODEL == '--stand-in':
        stand_in(sc)
    else:
        model(sc, MODEL)
    sc.render.filepath = OUT
    bpy.ops.render.render(write_still=True)


main()
